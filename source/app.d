import vibe.d, std.algorithm, std.process, std.range, std.regex;

string githubAuth, hookSecret;

shared static this()
{
    auto settings = new HTTPServerSettings;
    settings.port = 8080;
    settings.bindAddresses = ["0.0.0.0"];
    settings.options = HTTPServerOption.defaults & ~HTTPServerOption.parseJsonBody;
    readOption("port|p", &settings.port, "Sets the port used for serving.");

    auto router = new URLRouter;
    router
        .get("/", (req, res) => res.redirect("https://github.com/dlang-bot?tab=activity"))
        .post("/github_hook", &githubHook)
        ;
    listenHTTP(settings, router);

    githubAuth = "token "~environment["GH_TOKEN"];
    hookSecret = environment["GH_HOOK_SECRET"];
    // workaround for stupid openssl.conf on Heroku
    HTTPClient.setTLSSetupCallback((ctx) {
        ctx.useTrustedCertificateFile("/etc/ssl/certs/ca-certificates.crt");
    });
    HTTPClient.setUserAgentString("dlang-bot vibe.d/"~vibeVersionString);
}

Json verifyRequest(string signature, string data)
{
    import std.digest.digest, std.digest.hmac, std.digest.sha;

    auto hmac = HMAC!SHA1(hookSecret.representation);
    hmac.put(data.representation);
    enforce(hmac.finish.toHexString!(LetterCase.lower) == signature.chompPrefix("sha1="),
            "Hook signature mismatch");
    return parseJsonString(data);
}

void githubHook(HTTPServerRequest req, HTTPServerResponse res)
{
    auto json = verifyRequest(req.headers["X-Hub-Signature"], req.bodyReader.readAllUTF8);
    if (req.headers["X-Github-Event"] == "ping")
        return res.writeBody("pong");
    if (req.headers["X-GitHub-Event"] != "pull_request")
        return res.writeVoidBody();

    auto action = json["action"].get!string;
    logDebug("#%s %s", json["number"], action);
    switch (action)
    {
    case "opened", "closed", "synchronize":
        auto commitsURL = json["pull_request"]["commits_url"].get!string;
        auto commentsURL = json["pull_request"]["comments_url"].get!string;
        runTask(toDelegate(&handlePR), action, commitsURL, commentsURL);
        return res.writeBody("handled");
    default:
        return res.writeBody("ignored");
    }
}

struct IssueRef { int id; bool fixed; }
// get all issues mentioned in a commit
IssueRef[] getIssueRefs(string commitsURL)
{
    // see https://github.com/github/github-services/blob/2e886f407696261bd5adfc99b16d36d5e7b50241/lib/services/bugzilla.rb#L155
    enum issueRE = ctRegex!(`((close|fix|address)e?(s|d)? )?(ticket|bug|tracker item|issue)s?:? *([\d ,\+&#and]+)`, "i");
    static auto matchToRefs(M)(M m)
    {
        auto closed = !m.captures[1].empty;
        return m.captures[5].splitter(ctRegex!`[^\d]+`)
            .map!(id => IssueRef(id.to!int, closed));
    }

    return requestHTTP(commitsURL, (scope req) { req.headers["Authorization"] = githubAuth; })
        .readJson[]
        .map!(c => c["commit"]["message"].get!string.matchAll(issueRE).map!matchToRefs.joiner)
        .joiner
        .array
        .sort!((a, b) => a.id < b.id)
        .release;
}

struct Issue { int id; string desc; }
// get pairs of (issue number, short descriptions) from bugzilla
Issue[] getDescriptions(R)(R issueRefs)
{
    import std.csv;

    return "https://issues.dlang.org/buglist.cgi?bug_id=%(%d,%)&ctype=csv&columnlist=short_desc"
        .format(issueRefs.map!(r => r.id))
        .requestHTTP
        .bodyReader.readAllUTF8
        .csvReader!Issue(null)
        .array
        .sort!((a, b) => a.id < b.id)
        .release;
}

string formatComment(R1, R2)(R1 refs, R2 descs)
{
    import std.format : formattedWrite;

    auto combined = zip(refs.map!(r => r.id), refs.map!(r => r.fixed), descs.map!(d => d.desc));
    auto app = appender!string();
    app.put("Fix | Bugzilla | Description\n");
    app.put("--- | --- | ---\n");
    foreach (num, closed, desc; combined)
    {
        app.formattedWrite(
            "%1$s | [%2$s](https://issues.dlang.org/show_bug.cgi?id=%2$s) | %3$s\n",
            closed ? "✓" : "✗", num, desc);
    }
    return app.data;
}

struct Comment { string url, body_; }

Comment getBotComment(string commentsURL)
{
    auto res = requestHTTP(commentsURL, (scope req) { req.headers["Authorization"] = githubAuth; })
        .readJson[]
        .find!(c => c["user"]["login"] == "dlang-bot");
    if (res.length)
        return deserializeJson!Comment(res[0]);
    return Comment();
}

void sendRequest(T...)(HTTPMethod method, string url, T arg)
    if (T.length <= 1)
{
    requestHTTP(url, (scope req) {
        req.headers["Authorization"] = githubAuth;
        req.method = method;
        static if (T.length)
            req.writeJsonBody(arg);
    }, (scope res) {
        if (res.statusCode / 100 == 2)
            logInfo("%s %s, %s\n", method, url, res.bodyReader.empty ?
                    res.statusPhrase : res.readJson["html_url"].get!string);
        else
            logWarn("%s %s failed;  %s %s.\n%s", method, url,
                res.statusPhrase, res.statusCode, res.bodyReader.readAllUTF8);
    });
}

void deleteBotComment(string commentURL)
{
    sendRequest(HTTPMethod.DELETE, commentURL);
}

void updateBotComment(string commentsURL, string commentURL, string msg)
{
    if (commentURL.length)
        sendRequest(HTTPMethod.PATCH, commentURL, ["body" : msg]);
    else
        sendRequest(HTTPMethod.POST, commentsURL, ["body" : msg]);
}

void handlePR(string action, string commitsURL, string commentsURL)
{
    auto comment = getBotComment(commentsURL);
    auto refs = getIssueRefs(commitsURL);
    logDebug("%s", refs);
    if (refs.empty)
    {
        if (comment.url.length) // delete any existing comment
            deleteBotComment(comment.url);
        return;
    }
    auto descs = getDescriptions(refs);
    logDebug("%s", descs);
    assert(refs.map!(r => r.id).equal(descs.map!(d => d.id)));

    auto msg = formatComment(refs, descs);
    logDebug("%s", msg);

    if (msg != comment.body_)
        updateBotComment(commentsURL, comment.url, msg);
}

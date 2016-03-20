import vibe.d, std.algorithm, std.process, std.range, std.regex;

string githubAuth, trelloAuth, hookSecret;

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
    trelloAuth = "key="~environment["TRELLO_KEY"]~"&token="~environment["TRELLO_TOKEN"];
    hookSecret = environment["GH_HOOK_SECRET"];
    // workaround for stupid openssl.conf on Heroku
    HTTPClient.setTLSSetupCallback((ctx) {
        ctx.useTrustedCertificateFile("/etc/ssl/certs/ca-certificates.crt");
    });
    HTTPClient.setUserAgentString("dlang-bot vibe.d/"~vibeVersionString);
}

//==============================================================================
// Gitlab hook
//==============================================================================

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
    case "closed":
        if (json["pull_request"]["merged"].get!bool)
            action = "merged";
        goto case;
    case "opened", "reopened", "synchronize":
        auto pullRequestURL = json["pull_request"]["html_url"].get!string;
        auto commitsURL = json["pull_request"]["commits_url"].get!string;
        auto commentsURL = json["pull_request"]["comments_url"].get!string;
        runTask(toDelegate(&handlePR), action, pullRequestURL, commitsURL, commentsURL);
        return res.writeBody("handled");
    default:
        return res.writeBody("ignored");
    }
}

//==============================================================================
// Bugzilla
//==============================================================================

struct IssueRef { int id; bool fixed; }
// get all issues mentioned in a commit
IssueRef[] getIssueRefs(string commitsURL)
{
    // see https://github.com/github/github-services/blob/2e886f407696261bd5adfc99b16d36d5e7b50241/lib/services/bugzilla.rb#L155
    enum issueRE = ctRegex!(`((close|fix|address)e?(s|d)? )?(ticket|bug|tracker item|issue)s?:? *([\d ,\+&#and]+)`, "i");
    static auto matchToRefs(M)(M m)
    {
        auto closed = !m.captures[1].empty;
        return m.captures[5].stripRight.splitter(ctRegex!`[^\d]+`)
            .map!(id => IssueRef(id.to!int, closed));
    }

    auto issues = requestHTTP(commitsURL, (scope req) { req.headers["Authorization"] = githubAuth; })
        .readJson[]
        .map!(c => c["commit"]["message"].get!string.matchAll(issueRE).map!matchToRefs.joiner)
        .joiner
        .array;
    issues.multiSort!((a, b) => a.id < b.id, (a, b) => a.fixed > b.fixed);
    issues.length -= issues.uniq!((a, b) => a.id == b.id).copy(issues).length;
    return issues;
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

//==============================================================================
// Github comments
//==============================================================================

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

void ghSendRequest(T...)(HTTPMethod method, string url, T arg)
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

void updateGithubComment(string action, IssueRef[] refs, Issue[] descs, string commentsURL)
{
    auto comment = getBotComment(commentsURL);
    logDebug("%s", refs);
    if (refs.empty)
    {
        if (comment.url.length) // delete any existing comment
            ghSendRequest(HTTPMethod.DELETE, comment.url);
        return;
    }
    logDebug("%s", descs);
    assert(refs.map!(r => r.id).equal(descs.map!(d => d.id)));

    auto msg = formatComment(refs, descs);
    logDebug("%s", msg);

    if (msg != comment.body_)
    {
        if (comment.url.length)
            ghSendRequest(HTTPMethod.PATCH, comment.url, ["body" : msg]);
        else if (action != "closed" && action != "merged")
            ghSendRequest(HTTPMethod.POST, commentsURL, ["body" : msg]);
    }
}

//==============================================================================
// Trello cards
//==============================================================================

void trelloSendRequest(T...)(HTTPMethod method, string url, T arg)
    if (T.length <= 1)
{
    requestHTTP(url, (scope req) {
        req.method = method;
        static if (T.length)
            req.writeJsonBody(arg);
    }, (scope res) {
        if (res.statusCode / 100 == 2)
            logInfo("%s %s: %s\n", method, url.replace(trelloAuth, "key=[hidden]&token=[hidden]")
                    , res.statusPhrase);
        else
            logWarn("%s %s: %s %s.\n%s", method, url.replace(trelloAuth, "key=[hidden]&token=[hidden]"),
                res.statusPhrase, res.statusCode, res.bodyReader.readAllUTF8);
    });
}

struct TrelloCard { string id; int issueID; }

string trelloAPI(Args...)(string fmt, Args args)
{
    import std.uri : encode;
    return encode("https://api.trello.com"~fmt.format(args)~(fmt.canFind("?") ? "&" : "?")~trelloAuth);
}

string formatTrelloComment(R)(string existingComment, string pullRequestURL, R issues)
{
    import std.format : formattedWrite;

    auto app = appender!string();
    auto parts = existingComment
        .lineSplitter!(KeepTerminator.yes)
        .findSplitBefore!((line, pr) => line.startsWith("- ") && line.canFind(pr))(only(pullRequestURL));
    parts[0].each!(ln => app.put(ln));
    if (app.data.length && app.data[$-1] != '\n')
        app.put('\n');
    app.formattedWrite("- %s\n", pullRequestURL);
    foreach (issue; issues)
        app.formattedWrite("  - [%s](https://issues.dlang.org/%d)\n", issue.desc, issue.id);
    parts[1].drop(1).find!(line => line.startsWith("- ")).each!(ln => app.put(ln));
    return app.data;
}

auto findTrelloCards(int issueID)
{
    return trelloAPI("/1/search?query=name:'Issue %d'", issueID)
        .requestHTTP
        .readJson["cards"][]
        .map!(c => TrelloCard(c["id"].get!string, issueID));
}

Comment getTrelloBotComment(string cardID)
{
    auto res = trelloAPI("/1/cards/%s/actions?filter=commentCard", cardID)
        .requestHTTP
        .readJson[]
        .find!(c => c["memberCreator"]["username"] == "dlangbot");
    if (res.length)
        return Comment(
            trelloAPI("/1/cards/%s/actions/%s/comments", cardID, res[0]["id"].get!string),
            res[0]["data"]["text"].get!string);
    return Comment();
}

void moveCardToList(string cardID, string listName)
{
    logInfo("moveCardToDone %s", cardID);
    auto card = trelloAPI("/1/cards/%s", cardID)
        .requestHTTP
        .readJson;
    auto listID = trelloAPI("/1/board/%s/lists", card["idBoard"].get!string)
        .requestHTTP
        .readJson[]
        .find!(c => c["name"].get!string.startsWith(listName))
        .front["id"].get!string;
    if (card["idList"] == listID)
        return;
    trelloSendRequest(HTTPMethod.PUT, trelloAPI("/1/cards/%s/idList?value=%s", cardID, listID));
}

void updateTrelloCard(string action, string pullRequestURL, IssueRef[] refs, Issue[] descs)
{
    foreach (grp; descs.map!(d => findTrelloCards(d.id)).joiner.chunkBy!((a, b) => a.id == b.id))
    {
        auto cardID = grp.front.id;
        auto comment = getTrelloBotComment(cardID);
        auto issues = descs.filter!(d => grp.canFind!((tc, issueID) => tc.issueID == issueID)(d.id));
        logDebug("%s %s", cardID, issues);
        if (issues.empty)
        {
            if (comment.url.length)
                trelloSendRequest(HTTPMethod.DELETE, comment.url);
            return;
        }

        auto msg = formatTrelloComment(comment.body_, pullRequestURL, issues);
        logDebug("%s", msg);

        if (msg != comment.body_)
        {
            if (comment.url.length)
                trelloSendRequest(HTTPMethod.PUT, comment.url, ["text": msg]);
            else if (action != "closed")
                trelloSendRequest(HTTPMethod.POST, trelloAPI("/1/cards/%s/actions/comments", cardID), ["text": msg]);
        }

        if ((action == "opened" || action == "merged") &&
            grp.all!(tc => refs.find!(r => r.id == tc.issueID).front.fixed))
            moveCardToList(cardID, action == "opened" ? "Testing" : "Done");
    }
}

//==============================================================================

void handlePR(string action, string pullRequestURL, string commitsURL, string commentsURL)
{
    auto refs = getIssueRefs(commitsURL);
    auto descs = getDescriptions(refs);
    updateGithubComment(action, refs, descs, commentsURL);
    updateTrelloCard(action, pullRequestURL, refs, descs);
}

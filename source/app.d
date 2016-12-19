module app;

import vibe.d, std.algorithm, std.process, std.range, std.regex;
import std.datetime, std.typecons;

string githubAuth, trelloSecret, trelloAuth, hookSecret, travisAuth;

string githubAPIURL = "https://api.github.com";
string travisAPIURL = "https://api.travis-ci.org";
string trelloAPIURL = "https://api.trello.com";
string bugzillaURL = "https://issues.dlang.org";
bool runAsync = true;
bool runTrello = true;

SysTime lastFullPRCheck = SysTime.min;
Duration timeBetweenFullPRChecks = 5.minutes;

version(unittest){} else
shared static this()
{
    auto settings = new HTTPServerSettings;
    settings.port = 8080;
    readOption("port|p", &settings.port, "Sets the port used for serving.");

    githubAuth = "token "~environment["GH_TOKEN"];
    trelloSecret = environment["TRELLO_SECRET"];
    trelloAuth = "key="~environment["TRELLO_KEY"]~"&token="~environment["TRELLO_TOKEN"];
    hookSecret = environment["GH_HOOK_SECRET"];
    travisAuth = "token " ~ environment["TRAVIS_TOKEN"];

    // workaround for stupid openssl.conf on Heroku
    if (environment.get("DYNO") !is null)
    {
        HTTPClient.setTLSSetupCallback((ctx) {
            ctx.useTrustedCertificateFile("/etc/ssl/certs/ca-certificates.crt");
        });
    }
}

void startServer(HTTPServerSettings settings)
{
    settings.bindAddresses = ["0.0.0.0"];
    settings.options = HTTPServerOption.defaults & ~HTTPServerOption.parseJsonBody;

    auto router = new URLRouter;
    router
        .get("/", (req, res) => res.render!"index.dt")
        .get("*", serveStaticFiles("public"))
        .post("/github_hook", &githubHook)
        .match(HTTPMethod.HEAD, "/trello_hook", (req, res) => res.writeVoidBody)
        .post("/trello_hook", &trelloHook)
        ;

    HTTPClient.setUserAgentString("dlang-bot vibe.d/"~vibeVersionString);

    listenHTTP(settings, router);
}

//==============================================================================
// Github hook
//==============================================================================

auto getSignature(string data)
{
    import std.digest.digest, std.digest.hmac, std.digest.sha;
    import std.string : representation;

    auto hmac = HMAC!SHA1(hookSecret.representation);
    hmac.put(data.representation);
    return hmac.finish.toHexString!(LetterCase.lower);
}

Json verifyRequest(string signature, string data)
{
    import std.exception : enforce;
    import std.string : chompPrefix;

    enforce(getSignature(data) == signature.chompPrefix("sha1="),
            "Hook signature mismatch");
    return parseJsonString(data);
}

void githubHook(HTTPServerRequest req, HTTPServerResponse res)
{
    auto json = verifyRequest(req.headers["X-Hub-Signature"], req.bodyReader.readAllUTF8);
    switch (req.headers["X-GitHub-Event"])
    {
    case "ping":
        return res.writeBody("pong");
    case "status":
        string repoSlug = json["name"].get!string;
        string state = json["state"].get!string;
        // no need to trigger the checker for failure/pending
        if (state == "success")
        {
            if (lastFullPRCheck + timeBetweenFullPRChecks < Clock.currTime)
            {
                searchForAutoMergePrs(repoSlug);
                lastFullPRCheck = Clock.currTime();
            }
        }
        return res.writeBody("handled");
    case "pull_request":

        auto action = json["action"].get!string;
        logDebug("#%s %s", json["number"], action);

        switch (action)
        {
        case "unlabeled":
            // for now unlabel events are ignored
            return res.writeBody("ignored");
        case "closed":
            if (json["pull_request"]["merged"].get!bool)
                action = "merged";
            goto case;
        case "opened", "reopened", "synchronize", "labeled":

            PullRequestParams prParams = {
                repoSlug : json["pull_request"]["base"]["repo"]["full_name"].get!string,
                pullRequestURL : json["pull_request"]["html_url"].get!string,
                pullRequestNumber : json["pull_request"]["number"].get!uint,
                commitsURL : json["pull_request"]["commits_url"].get!string,
                commentsURL : json["pull_request"]["comments_url"].get!string,
                isOpen : json["pull_request"]["state"].get!string == "open",
            };
            runTaskHelper(toDelegate(&handlePR), action, prParams);
            return res.writeBody("handled");
        default:
            return res.writeBody("ignored");
        }
    default:
        return res.writeVoidBody();
    }
}

auto runTaskHelper(Fun, Args...)(Fun fun, Args args)
{
    if (runAsync)
        runTask(fun, args);
    else
        return fun(args);
}

//==============================================================================
// Bugzilla
//==============================================================================

auto matchIssueRefs(string message)
{
    static auto matchToRefs(M)(M m)
    {
        enum splitRE = regex(`[^\d]+`); // ctRegex throws a weird error in unittest compilation
        auto closed = !m.captures[1].empty;
        return m.captures[5].stripRight.splitter(splitRE)
            .filter!(id => !id.empty) // see #6
            .map!(id => IssueRef(id.to!int, closed));
    }

    // see https://github.com/github/github-services/blob/2e886f407696261bd5adfc99b16d36d5e7b50241/lib/services/bugzilla.rb#L155
    enum issueRE = ctRegex!(`((close|fix|address)e?(s|d)? )?(ticket|bug|tracker item|issue)s?:? *([\d ,\+&#and]+)`, "i");
    return message.matchAll(issueRE).map!matchToRefs.joiner;
}

unittest
{
    assert(equal(matchIssueRefs("fix issue 16319 and fix std.traits.isInnerClass"), [IssueRef(16319, true)]));
}

struct IssueRef { int id; bool fixed; }
// get all issues mentioned in a commit
IssueRef[] getIssueRefs(Json[] commits)
{
    auto issues = commits
        .map!(c => c["commit"]["message"].get!string.matchIssueRefs)
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

    if (issueRefs.empty)
        return null;
    return "%s/buglist.cgi?bug_id=%(%d,%)&ctype=csv&columnlist=short_desc"
        .format(bugzillaURL, issueRefs.map!(r => r.id))
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
            "%1$s | [%2$s](%4$s/show_bug.cgi?id=%2$s) | %3$s\n",
            closed ? "✓" : "✗", num, desc, bugzillaURL);
    }
    return app.data;
}

struct Comment { string url, body_; }

Comment getBotComment(string commentsURL)
{
    // the bot may post multiple comments (mention-bot & bugzilla links)
    auto res = ghGetRequest(commentsURL)
        .readJson[]
        .find!(c => c["user"]["login"] == "dlang-bot" && c["body"].get!string.canFind("Bugzilla"));
    if (res.length)
        return deserializeJson!Comment(res[0]);
    return Comment();
}

auto ghGetRequest(string url)
{
    return requestHTTP(url, (scope req) {
        req.headers["Authorization"] = githubAuth;
    });
}


void ghSendRequest(scope void delegate(scope HTTPClientRequest req) userReq, string url)
{
    HTTPMethod method;
    requestHTTP(url, (scope req) {
        req.headers["Authorization"] = githubAuth;
        userReq(req);
        method = req.method;
    }, (scope res) {
        if (res.statusCode / 100 == 2)
        {
            logInfo("%s %s, %s\n", method, url, res.statusPhrase);
            res.bodyReader.readAllUTF8;
        }
        else
            logWarn("%s %s failed;  %s %s.\n%s", method, url,
                res.statusPhrase, res.statusCode, res.bodyReader.readAllUTF8);
    });
}

auto ghSendRequest(T...)(HTTPMethod method, string url, T arg)
    if (T.length <= 1)
{
    return ghSendRequest((scope req) {
        req.method = method;
        static if (T.length)
            req.writeJsonBody(arg);
    }, url);
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
// Github Auto-merge
//==============================================================================

struct PullRequestParams
{
    string repoSlug;
    uint pullRequestNumber;
    bool isOpen;
    string commitsURL;
    string commentsURL;
    string pullRequestURL;
}

alias LabelsAndCommits = Tuple!(Json[], "labels", Json[], "commits");
alias LabelInfo = Tuple!(bool, "hasAutoMerge", bool, "hasAutoMergeSquash");

auto analyseLabels(Json[] labels)
{
    auto labelNames = labels.map!(l => l["name"].get!string).array;
    bool hasAutoMerge = labelNames.any!(l => l == "auto-merge");
    bool hasAutoMergeSquash = labelNames.any!(l => l == "auto-merge-squash");
    return LabelInfo(hasAutoMerge, hasAutoMergeSquash);
}

auto handleGithubLabel(in ref PullRequestParams pr)
{
    auto url = "%s/repos/%s/issues/%d/labels".format(githubAPIURL, pr.repoSlug, pr.pullRequestNumber);
    auto res = ghGetRequest(url);

    auto labels = res.readJson[];
    auto labelInfo = analyseLabels(labels);
    Json[] commits;

    if (labelInfo.hasAutoMerge || labelInfo.hasAutoMergeSquash)
        commits = pr.tryMerge(labelInfo);

    return LabelsAndCommits(labels, commits);
}

Json[] tryMerge(in ref PullRequestParams pr, LabelInfo labelInfo)
{
    auto commits = ghGetRequest(pr.commitsURL).readJson[];

    if (!pr.isOpen)
    {
        logWarn("Can't auto-merge PR %s/%d - it is already closed", pr.repoSlug, pr.pullRequestNumber);
        return commits;
    }

    if (commits.length == 0)
    {
        logWarn("Can't auto-merge PR %s/%d has no commits attached", pr.repoSlug, pr.pullRequestNumber);
        return commits;
    }

    string lastCommitSha = commits[$ - 1]["sha"].get!string;
    string[string] reqInput = ["sha": lastCommitSha];

    // lazy implementation -> try merge
    if (labelInfo.hasAutoMerge)
        reqInput["merge_method"] = "merge";

    if (labelInfo.hasAutoMergeSquash)
        reqInput["merge_method"] = "squash";

    auto prUrl = "%s/repos/%s/pulls/%d/merge".format(githubAPIURL, pr.repoSlug, pr.pullRequestNumber);
    ghSendRequest((scope req){
        req.method = HTTPMethod.PUT;
        // custom media type is required during preview period:
        // https://developer.github.com/changes/2016-09-26-pull-request-merge-api-update/
        req.headers["Accept"] = "application/vnd.github.polaris-preview+json";
        req.writeJsonBody(reqInput);
    }, prUrl);

    return commits;
}

void checkAndRemoveMergeLabels(Json[] labels, in ref PullRequestParams pr)
{
    auto labelInfo = analyseLabels(labels);
    if (labelInfo.hasAutoMerge || labelInfo.hasAutoMergeSquash)
    {
        auto labelUrl = "%s/repos/%s/issues/%d/labels/".format(githubAPIURL, pr.repoSlug, pr.pullRequestNumber);
        if (labelInfo.hasAutoMerge)
            labelUrl ~= "auto-merge";
        if (labelInfo.hasAutoMergeSquash)
            labelUrl ~= "auto-merge-squash";
        ghSendRequest(HTTPMethod.DELETE, labelUrl);
    }
}

Json[] getIssuesForLabel(string repoSlug, string label)
{
    return ghGetRequest("%s/repos/%s/issues?state=open&labels=%s"
                .format(githubAPIURL, repoSlug, label)).readJson[];
}

void searchForAutoMergePrs(string repoSlug)
{
    // the GitHub API doesn't allow a logical OR
    auto issues = getIssuesForLabel(repoSlug, "auto-merge").chain(getIssuesForLabel(repoSlug, "auto-merge-squash"));
    issues.sort!((a, b) => a["number"] < b["number"]);
    foreach (issue; issues.uniq)
    {
        auto prNumber = issue["number"].get!uint;
        if ("pull_request" !in issue)
            continue;

        PullRequestParams prParams = {
            repoSlug: repoSlug,
            pullRequestNumber: prNumber,
            commitsURL: "%s/repos/%s/pulls/%d/commits".format(githubAPIURL, repoSlug, prNumber),
            isOpen: true
        };
        auto labelInfo = analyseLabels(issue["labels"][]);
        tryMerge(prParams, labelInfo);
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
    return encode(trelloAPIURL ~fmt.format(args)~(fmt.canFind("?") ? "&" : "?")~trelloAuth);
}

string formatTrelloComment(string existingComment, Issue[] issues)
{
    import std.format : formattedWrite;

    auto app = appender!string();
    foreach (issue; issues)
        app.formattedWrite("- [Issue %1$d - %2$s](https://issues.dlang.org/show_bug.cgi?id=%1$d)\n", issue.id, issue.desc);

    existingComment
        .lineSplitter!(KeepTerminator.yes)
        .filter!(line => !line.canFind("issues.dlang.org"))
        .each!(ln => app.put(ln));
    return app.data;
}

string formatTrelloComment(string existingComment, string pullRequestURL)
{
    import std.format : formattedWrite;

    auto app = appender!string();

    auto lines = existingComment
        .lineSplitter!(KeepTerminator.yes);
    lines.each!(ln => app.put(ln));
    if (!lines.canFind!(line => line.canFind(pullRequestURL)))
        app.formattedWrite("- %s\n", pullRequestURL);
    return app.data;
}

auto findTrelloCards(int issueID)
{
    return trelloAPI("/1/search?query=name:\"Issue %d\"", issueID)
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
    auto card = trelloAPI("/1/cards/%s", cardID)
        .requestHTTP
        .readJson;
    auto lists = trelloAPI("/1/board/%s/lists", card["idBoard"].get!string)
        .requestHTTP
        .readJson[];

    immutable curListName = lists.find!(c => c["id"].get!string == card["idList"].get!string)
        .front["name"].get!string;
    // don't move cards in done, see #9
    if (curListName.startsWith("Done", listName))
    {
        logInfo("moveCardToList(%s, %s) card already in %s", cardID, listName, curListName);
        return;
    }

    logInfo("moveCardToList(%s, %s)", cardID, listName);
    immutable listID = lists.find!(c => c["name"].get!string.startsWith(listName))
        .front["id"].get!string;
    trelloSendRequest(HTTPMethod.PUT, trelloAPI("/1/cards/%s/idList?value=%s", cardID, listID));
    trelloSendRequest(HTTPMethod.PUT, trelloAPI("/1/cards/%s/pos?value=bottom", cardID));
}

void updateTrelloCard(string action, string pullRequestURL, IssueRef[] refs, Issue[] descs)
{
    foreach (grp; descs.map!(d => findTrelloCards(d.id)).joiner.array.chunkBy!((a, b) => a.id == b.id))
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

        auto msg = formatTrelloComment(comment.body_, pullRequestURL);
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

void updateTrelloCard(string cardID, IssueRef[] refs, Issue[] descs)
{
    auto comment = getTrelloBotComment(cardID);
    auto issues = descs;
    logDebug("%s %s", cardID, issues);
    if (issues.empty)
    {
        if (comment.url.length)
            trelloSendRequest(HTTPMethod.DELETE, comment.url);
        return;
    }

    auto msg = formatTrelloComment(comment.body_, issues);
    logDebug("%s", msg);

    if (msg != comment.body_)
    {
        if (comment.url.length)
            trelloSendRequest(HTTPMethod.PUT, comment.url, ["text": msg]);
        else
            trelloSendRequest(HTTPMethod.POST, trelloAPI("/1/cards/%s/actions/comments", cardID), ["text": msg]);
    }
}

//==============================================================================
// Trello hook
//==============================================================================

Json verifyTrelloRequest(string signature, string body_, string url)
{
    import std.digest.digest, std.digest.hmac, std.digest.sha;

    static ubyte[28] base64Digest(Range)(Range range)
    {
        import std.base64;

        auto hmac = HMAC!SHA1(trelloSecret.representation);
        foreach (c; range)
            hmac.put(c);
        ubyte[28] buf = void;
        Base64.encode(hmac.finish, buf[]);
        return buf;
    }

    import std.utf : byUTF;
    enforce(
        base64Digest(base64Digest(body_.byUTF!dchar.map!(c => cast(immutable ubyte) c).chain(url.representation))) ==
        base64Digest(signature.representation), "Hook signature mismatch");
    return parseJsonString(body_);
}

void trelloHook(HTTPServerRequest req, HTTPServerResponse res)
{
    auto url = "https://dlang-bot.herokuapp.com/trello_hook";
    auto json = verifyTrelloRequest(req.headers["X-Trello-Webhook"], req.bodyReader.readAllUTF8, url);
    logDebug("trelloHook %s", json);
    auto action = json["action"]["type"].get!string;
    switch (action)
    {
    case "createCard", "updateCard":
        auto refs = matchIssueRefs(json["action"]["data"]["card"]["name"].get!string).array;
        auto descs = getDescriptions(refs);
        updateTrelloCard(json["action"]["data"]["card"]["id"].get!string, refs, descs);
        break;
    default:
        return res.writeBody("ignored");
    }

    res.writeVoidBody;
}

//==============================================================================
// Dedup Travis-CI builds
//==============================================================================

void cancelBuild(size_t buildId)
{
    auto url = "%s/builds/%s/cancel".format(trelloAPIURL, buildId);
    requestHTTP(url, (scope req) {
        req.headers["Authorization"] = travisAuth;
        req.method = HTTPMethod.POST;
    }, (scope res) {
        if (res.statusCode / 100 == 2)
            logInfo("Canceled Build %s\n", buildId);
        else
            logWarn("POST %s failed;  %s %s.\n%s", url, res.statusPhrase,
                res.statusCode, res.bodyReader.readAllUTF8);
    });
}

void dedupTravisBuilds(string action, string repoSlug, uint pullRequestNumber)
{
    if (action != "synchronize" && action != "merged")
        return;

    static bool activeState(string state)
    {
        switch (state)
        {
        case "created", "queued", "started": return true;
        default: return false;
        }
    }

    auto url = "%s/repos/%s/builds?event_type=pull_request".format(trelloAPIURL, repoSlug);
    auto activeBuildsForPR = requestHTTP(url, (scope req) {
            req.headers["Authorization"] = travisAuth;
            req.headers["Accept"] = "application/vnd.travis-ci.2+json";
        })
        .readJson["builds"][]
        .filter!(b => activeState(b["state"].get!string))
        .filter!(b => b["pull_request_number"].get!uint == pullRequestNumber);

    // Keep only the most recent build for this PR.  Kill all builds
    // when it got merged as it'll be retested after the merge anyhow.
    foreach (b; activeBuildsForPR.drop(action == "merged" ? 0 : 1))
        cancelBuild(b["id"].get!size_t);
}

//==============================================================================

void handlePR(string action, PullRequestParams pr)
{
    Json[] commits;

    if (action == "labeled" || action == "synchronize")
    {
        auto labelsAndCommits = handleGithubLabel(pr);
        if (action == "labeled")
            return;
        if (action == "synchronize")
        {
            checkAndRemoveMergeLabels(labelsAndCommits.labels, pr);
            if (labelsAndCommits.commits !is null)
                commits = labelsAndCommits.commits;
        }
    }

    // we only query the commits once
    if (commits is null)
        commits = ghGetRequest(pr.commitsURL).readJson[];

    auto refs = getIssueRefs(commits);

    auto descs = getDescriptions(refs);
    updateGithubComment(action, refs, descs, pr.commentsURL);

    if (runTrello)
        updateTrelloCard(action, pr.pullRequestURL, refs, descs);

    // wait until builds for the current push are created
    setTimer(30.seconds, { dedupTravisBuilds(action, pr.repoSlug, pr.pullRequestNumber); });
}

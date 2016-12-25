module dlangbot.app;

import dlangbot.bugzilla, dlangbot.github, dlangbot.travis, dlangbot.trello,
       dlangbot.utils;

public import dlangbot.bugzilla : bugzillaURL;
public import dlangbot.github   : githubAPIURL, githubAuth, hookSecret;
public import dlangbot.travis   : travisAPIURL;
public import dlangbot.trello   : trelloAPIURL, trelloAuth, trelloSecret;

import std.datetime : Clock, Duration, minutes, seconds, SysTime;

import vibe.core.log;
import vibe.data.json;
import vibe.http.client : HTTPClient;
import vibe.http.common : HTTPMethod;
import vibe.http.router : URLRouter;
import vibe.http.server : HTTPServerRequest, HTTPServerResponse, HTTPServerSettings;
import vibe.stream.operations : readAllUTF8;

bool runAsync = true;
bool runTrello = true;

Duration timeBetweenFullPRChecks = 5.minutes; // this should never be larger 30 mins on heroku
Throttler!(typeof(&searchForAutoMergePrs)) prThrottler;

enum trelloHookURL = "https://dlang-bot.herokuapp.com/trello_hook";

version(unittest){} else
shared static this()
{
    import std.process : environment;
    import vibe.core.args : readOption;

    auto settings = new HTTPServerSettings;
    settings.port = 8080;
    readOption("port|p", &settings.port, "Sets the port used for serving.");
    startServer(settings);

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
    import vibe.core.core : vibeVersionString;
    import vibe.http.fileserver : serveStaticFiles;
    import vibe.http.server : HTTPServerOption, listenHTTP, render;

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

    prThrottler = typeof(prThrottler)(&searchForAutoMergePrs, timeBetweenFullPRChecks);

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

void trelloHook(HTTPServerRequest req, HTTPServerResponse res)
{
    import std.array : array;
    import dlangbot.trello : verifyRequest;

    auto json = verifyRequest(req.headers["X-Trello-Webhook"], req.bodyReader.readAllUTF8, trelloHookURL);
    logDebug("trelloHook %s", json);
    auto action = json["action"]["type"].get!string;
    switch (action)
    {
    case "createCard", "updateCard":
        auto refs = matchIssueRefs(json["action"]["data"]["card"]["name"].get!string).array;
        auto descs = getDescriptions(refs);
        updateTrelloCard(json["action"]["data"]["card"]["id"].get!string, refs, descs);
        return res.writeBody("handled");
    default:
        return res.writeBody("ignored");
    }
}

void githubHook(HTTPServerRequest req, HTTPServerResponse res)
{
    import std.functional : toDelegate;

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
            prThrottler(repoSlug);

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

            auto pullRequest = json["pull_request"].deserializeJson!PullRequest;
            runTaskHelper(toDelegate(&handlePR), action, pullRequest);
            return res.writeBody("handled");
        default:
            return res.writeBody("ignored");
        }
    default:
        return res.writeVoidBody();
    }
}

//==============================================================================

void handlePR(string action, PullRequest pr)
{
    import vibe.core.core : setTimer;

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
    auto comment = pr.getBotComment;

    pr.updateGithubComment(comment, action, refs, descs);

    if (runTrello)
        updateTrelloCard(action, pr.htmlURL, refs, descs);

    // wait until builds for the current push are created
    setTimer(30.seconds, { dedupTravisBuilds(action, pr.repoSlug, pr.number); });
}

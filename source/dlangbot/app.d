module dlangbot.app;

import dlangbot.bugzilla, dlangbot.github, dlangbot.travis, dlangbot.trello,
       dlangbot.utils;

public import dlangbot.bugzilla : bugzillaURL;
public import dlangbot.github   : githubAPIURL, githubAuth, hookSecret;
public import dlangbot.travis   : travisAPIURL;
public import dlangbot.trello   : trelloAPIURL, trelloAuth, trelloSecret;

string cronDailySecret;

import std.datetime : Clock, days, Duration, minutes, seconds, SysTime;

import vibe.core.log;
import vibe.data.json;
import vibe.http.client : HTTPClient;
import vibe.http.common : enforceBadRequest, enforceHTTP, HTTPMethod, HTTPStatus;
import vibe.http.router : URLRouter;
import vibe.http.server : HTTPServerRequest, HTTPServerResponse, HTTPServerSettings;
import vibe.stream.operations : readAllUTF8;

bool runAsync = true;
bool runTrello = true;

Duration timeBetweenFullPRChecks = 1.minutes; // this should never be larger 30 mins on heroku
Throttler!(typeof(&searchForAutoMergePrs)) prThrottler;

Duration prInactivityDur = 90.days; // PRs with no activity within X days will get flagged

enum trelloHookURL = "https://dlang-bot.herokuapp.com/trello_hook";

version(unittest){} else
shared static this()
{
    import std.process : environment;
    import vibe.core.args : readOption;

    auto settings = new HTTPServerSettings;
    settings.port = 8080;
    readOption("port|p", &settings.port, "Sets the port used for serving.");

    githubAuth = "token "~environment["GH_TOKEN"];
    trelloSecret = environment["TRELLO_SECRET"];
    trelloAuth = "key="~environment["TRELLO_KEY"]~"&token="~environment["TRELLO_TOKEN"];
    hookSecret = environment["GH_HOOK_SECRET"];
    travisAuth = "token " ~ environment["TRAVIS_TOKEN"];
    cronDailySecret = environment["CRON_DAILY_SECRET"];

    // workaround for stupid openssl.conf on Heroku
    if (environment.get("DYNO") !is null)
    {
        HTTPClient.setTLSSetupCallback((ctx) {
            ctx.useTrustedCertificateFile("/etc/ssl/certs/ca-certificates.crt");
        });
        setLogLevel(LogLevel.debug_);
    }

    startServer(settings);
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
        .get("/cron_daily", &cronDaily)
        ;

    HTTPClient.setUserAgentString("dlang-bot vibe.d/"~vibeVersionString);

    prThrottler = typeof(prThrottler)(&searchForAutoMergePrs, timeBetweenFullPRChecks);

    listenHTTP(settings, router);
}

//==============================================================================
// Github hook
//==============================================================================

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
    import dlangbot.github : verifyRequest;

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
        case "opened", "reopened", "synchronize", "labeled", "edited":

            auto pullRequest = json["pull_request"].deserializeJson!PullRequest;
            runTaskHelper(&handlePR, action, &pullRequest);
            return res.writeBody("handled");
        default:
            return res.writeBody("ignored");
        }
    default:
        return res.writeVoidBody();
    }
}

//==============================================================================

void cronDaily(HTTPServerRequest req, HTTPServerResponse res)
{
    enforceBadRequest(req.query.length > 0, "No repo slugs provided");
    enforceHTTP(req.query.get("secret") == cronDailySecret,
                HTTPStatus.unauthorized, "Invalid or no secret provided");

    foreach (ref slug; req.query.getAll("repo"))
    {
        logInfo("running cron.daily for: %s", slug);
        runTaskHelper(&searchForInactivePrs, slug, prInactivityDur);
    }

    return res.writeBody("OK");
}

//==============================================================================

void handlePR(string action, PullRequest* _pr)
{
    import std.algorithm : any;
    import vibe.core.core : setTimer;

    const PullRequest pr = *_pr;

    Json[] commits;

    if (action == "labeled" || action == "synchronize")
    {
        auto labelsAndCommits = handleGithubLabel(pr);
        if (action == "labeled")
            return;
        if (action == "synchronize")
        {
            enum toRemoveLabels = ["auto-merge", "auto-merge-squash",
                                   "needs rebase", "needs work"];
            checkAndRemoveLabels(labelsAndCommits.labels, pr, toRemoveLabels);
            if (labelsAndCommits.commits !is null)
                commits = labelsAndCommits.commits;
        }
    }

    if (action == "opened" || action == "edited")
        checkTitleForLabels(pr);

    // we only query the commits once
    if (commits is null)
        commits = ghGetRequest(pr.commitsURL).readJson[];

    auto refs = getIssueRefs(commits);

    auto descs = getDescriptions(refs);
    auto comment = pr.getBotComment;

    pr.updateGithubComment(comment, action, refs, descs);

    if (refs.any!(r => r.fixed) && comment.body_.length == 0)
        pr.addLabels(["Bug fix"]);

    if (runTrello)
        updateTrelloCard(action, pr.htmlURL, refs, descs);

    // wait until builds for the current push are created
    setTimer(30.seconds, { dedupTravisBuilds(action, pr.repoSlug, pr.number); });
}

module dlangbot.app;

import dlangbot.bugzilla;
import dlangbot.cron;
import dlangbot.github;
import dlangbot.trello;
import dlangbot.utils;

public import dlangbot.bugzilla : bugzillaLogin, bugzillaPassword, bugzillaURL;
public import dlangbot.github_api   : githubAPIURL, githubAuth, githubHookSecret;
public import dlangbot.trello   : trelloAPIURL, trelloAuth, trelloSecret;
public import dlangbot.twitter : oAuth, tweet, twitterURL, twitterEnabled;
public import dlangbot.buildkite : buildkiteAPIURL, buildkiteAuth, buildkiteHookSecret, dlangbotAgentAuth;
public import dlangbot.scaleway_api : scalewayAPIURL, scalewayAuth, scalewayOrg;
public import dlangbot.hcloud_api : hcloudAPIURL, hcloudAuth;

import std.datetime : Clock, days, Duration, minutes, seconds, SysTime;

import vibe.core.args;
import vibe.core.core;
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

enum trelloHookURL = "https://dlang-bot.herokuapp.com/trello_hook";

void startServer(HTTPServerSettings settings)
{
    import vibe.core.core : vibeVersionString;
    import vibe.http.fileserver : serveStaticFiles;
    import vibe.http.server : HTTPServerOption, listenHTTP, render;

    settings.bindAddresses = ["0.0.0.0"];

    auto router = new URLRouter;
    router
        .get("/", (req, res) => res.render!"index.dt")
        .get("*", serveStaticFiles("public"))
        .post("/github_hook", &githubHook)
        .match(HTTPMethod.HEAD, "/trello_hook", (HTTPServerRequest req, HTTPServerResponse res) => res.writeBody(""))
        .post("/trello_hook", &trelloHook)
        .post("/codecov_hook", &codecovHook)
        .post("/buildkite_hook", &buildkiteHook)
        .post("/agent_shutdown_check", &agentShutdownCheck)
        ;

    HTTPClient.setUserAgentString("dlang-bot vibe.d/"~vibeVersionString);

    prThrottler = typeof(prThrottler)(&searchForAutoMergePrs, timeBetweenFullPRChecks);

    listenHTTP(settings, router);
}

void startCrons()
{
    import core.time : hours, seconds;
    import std.random : uniform;

    import dlangbot.buildkite : cronReapDeadServers;

    static void arm(Duration interval, void delegate() nothrow @safe callback)
    {
        enum periodic = true;
        setTimer(uniform(0, interval.total!"seconds").seconds,
            { setTimer(interval, callback, periodic); callback(); },
            !periodic
        );
    }
    arm(1.hours, { cronReapDeadServers(); });
}

//==============================================================================
// Trello hook
//==============================================================================

void trelloHook(HTTPServerRequest req, HTTPServerResponse res)
{
    import std.array : array;
    import dlangbot.trello : verifyRequest;

    auto json = verifyRequest(req.headers.get("X-Trello-Webhook"), req.bodyReader.readAllUTF8, trelloHookURL);
    logDebug("trelloHook: %s", json);
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

//==============================================================================
// Github hook
//==============================================================================

void githubHook(HTTPServerRequest req, HTTPServerResponse res)
{
    import std.functional : toDelegate;
    import dlangbot.github : verifyRequest;

    auto json = verifyRequest(req.headers.get("X-Hub-Signature"), req.bodyReader.readAllUTF8);
    logDebug("githubHook: %s", json);
    switch (req.headers.get("X-GitHub-Event"))
    {
    case "ping":
        return res.writeBody("handled");

    case "status":
        auto state = json["state"].get!string;
        auto repoSlug = json["name"].get!string;
        logDebug("[github/pull_request](%s): state=%s, sha=%s, url=%s", repoSlug, state, json["sha"], json["target_url"]);
        // no need to trigger the checker for failure/pending
        if (state == "success")
            prThrottler(repoSlug);

        return res.writeBody("handled");

    case "pull_request":
        auto action = json["action"].get!string;
        auto repoSlug = json["repository"]["full_name"].get!string;
        auto pullRequest = json["pull_request"].deserializeJson!PullRequest;
        logInfo("[github/pull_request](%s#%s): action=%s", repoSlug, pullRequest.number, action);

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

            runTaskHelper(&handlePR, action, &pullRequest);
            return res.writeBody("handled");
        default:
            return res.writeBody("ignored");
        }

    case "pull_request_review":
        auto state = json["review"]["state"].get!string;
        auto repoSlug = json["repository"]["full_name"].get!string;
        auto pullRequest = json["pull_request"].deserializeJson!PullRequest;
        logInfo("[github/pull_request_review](%s#%s): state=%s", repoSlug, pullRequest.number, state);

        runTaskHelper(&handleReview, state, &pullRequest);
        return res.writeBody("handled");

    default:
        return res.writeBody("");
    }
}

//==============================================================================

void cronDaily(string[] repositories, CronConfig config)
{
    auto actions = [
        &detectStalledPR,
        &detectInactiveStablePR,
        &detectPRWithMergeConflicts,
        &detectPRWithPersistentCIFailures,
    ];

    foreach (repo; repositories)
    {
        logInfo("[cron-daily/%s]: starting", repo);
        walkPRs(repo, actions, config);
    }
}

//==============================================================================

void handlePR(string action, PullRequest* _pr)
{
    import std.algorithm : among, any;
    import vibe.core.core : setTimer;
    import dlangbot.warnings : checkForWarnings, UserMessage;
    import std.format : format;

    const PullRequest pr = *_pr;

    Json[] commits;

    // Twitter
    try {
        if (action == "merged")
        {
            if (twitterEnabled && pr.base.user.login == "dlang")
            {
                tweet(`%s: PR #%d "%s" by %s has been merged %s`.format(
                    pr.baseRepoSlug, pr.number, pr.title, pr.head.user.login, pr.htmlURL));
            }
        }
    } catch (Exception e) {
        logInfo("The Twitter module failed: %s", e);
    }
    // End: Twitter

    if (action == "labeled" || action == "synchronize")
    {
        auto labels = pr.labels;
        logDebug("[github/handlePR](%s): labels", labels);
        if (action == "labeled")
        {
            if (auto method = labels.autoMergeMethod)
                commits = pr.tryMerge(method);
            return;
        }
        if (action == "synchronize")
        {
            logDebug("[github/handlePR](%s): checkAndRemoveLabels", _pr.pid);
            enum toRemoveLabels = ["auto-merge", "auto-merge-squash",
                                   "needs rebase", "needs work", "stalled", "stable-stalled"];
            checkAndRemoveLabels(labels, pr, toRemoveLabels);
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

    UserMessage[] msgs;
    if (action == "opened" || action == "synchronize")
    {
        msgs = pr.checkForWarnings(descs, refs);
    }

    if (pr.base.repo.owner.login.among("dlang", "dlang-bots"))
        pr.updateGithubComment(comment, action, refs, descs, msgs);

    if (refs.any!(r => r.fixed))
    {
        import std.algorithm : canFind, filter, map, sort, uniq;
        import std.array : array;
        // references are already sorted by id
        auto bugzillaIds = refs.map!(r => r.id).uniq;
        auto bugzillSeverities = descs
            .filter!(d => bugzillaIds.canFind(d.id))
            .map!(i => i.severity);
        logDebug("[github/handlePR](%s): trying to add bug fix label", _pr.pid);
        string[] labels;
        if (bugzillSeverities.canFind("enhancement"))
            labels ~= "Enhancement";
        else
            labels ~= "Bug Fix";

        pr.addLabels(labels);
    }

    if (runTrello)
    {
        logDebug("[github/handlePR](%s): updating trello card", _pr.pid);
        updateTrelloCard(action, pr.htmlURL, refs, descs);
    }

    // When a PR is opened or updated mentioning some Bugzilla issues,
    // post a link to the PR as an issue comment.
    if (action == "opened" || action == "synchronize")
    {
        import std.algorithm.iteration : filter, map;
        import std.algorithm.searching : canFind;
        import std.array : array, join, replace;

        auto oldComments = getBugComments(refs.map!(r => r.id).array);

        foreach (r; refs)
        {
            // Make sure to only update open issues.
            // Otherwise, a mistake in creating the PR (e.g. wrong target branch)
            // may include previously-merged commits with mentions to bugs long fixed.
            auto statuses = descs.filter!(d => d.id == r.id);
            auto status = statuses.empty ? null : statuses.front.status;
            if (!status.among("NEW", "ASSIGNED", "REOPENED"))
                continue;

            // Only mention a PR at most once in an issue's comments.
            // This check also allows us to safely include new issue
            // references when new commits are pushed.
            auto ourComments = oldComments[r.id]
                // Look at only our comments
                .filter!(comment => comment["creator"].get!string == bugzillaLogin)
                // Get comment body
                .map!(comment => comment["text"].get!string ~ "\n")
                // Concatenate all of our comments' bodies
                .join;
            // Check for PR mention (see format string below)
            if (ourComments.canFind("\n" ~ pr.htmlURL ~ "\n"))
                continue;

            auto issueComment = "@%s %s %s pull request #%d \"%s\" %s this issue:\n\n%-(%s\n\n%)\n\n%s".format(
                pr.user.login, action == "opened" ? "created" : "updated", pr.baseRepoSlug,
                pr.number, pr.title, r.fixed ? "fixing" : "mentioning",
                r.commits.map!(c => "- " ~ c["commit"]["message"].get!string.replace("\n", "\n  ")),
                pr.htmlURL,
            );

            updateBugs([r.id], issueComment, false, r.fixed ? ["pull"] : null);
        }
    }

    // When a PR is merged, update Bugzilla issues
    // (leave a comment with a link to the PR, and close them appropriately).
    if (action == "merged")
    {
        import std.algorithm.iteration : filter, map;
        import std.algorithm.searching : canFind, all;
        import std.array : array, assocArray, join, replace;
        import std.regex : regex, matchAll;

        auto oldComments = getBugComments(refs.map!(r => r.id).array);

        foreach (r; refs)
        {
            static commitRe = regex(`\n- ([0-9a-f]{40}) by `);
            auto previouslyMentionedCommits = oldComments[r.id]
                // Look at only our comments
                .filter!(comment => comment["creator"].get!string == bugzillaLogin)
                // Get comment body
                .map!(comment => comment["text"].get!string)
                // Concatenate all of our comments' bodies
                .join
                // Extract mentioned commit hashes (see format string below)
                .matchAll(commitRe)
                // Extract matches and convert to hashset
                .map!(m => tuple(m[1], (void[0]).init))
                .assocArray;

            if (r.commits.map!(c => c["sha"].get!string).all!(c => c in previouslyMentionedCommits))
                continue; // We've previously already mentioned all commits in this PR in this issue thread.

            auto issueComment = "%s pull request #%d \"%s\" was merged into %s:\n\n%-(%s\n\n%)\n\n%s".format(
                pr.baseRepoSlug, pr.number, pr.title, pr.base.ref_,
                r.commits.map!(c =>
                    "- %s by %s:\n  %s".format(
                        c["sha"].get!string,
                        c["commit"]["author"]["name"].get!string,
                        c["commit"]["message"].get!string.replace("\n", "\n  "),
                    )
                ),
                pr.htmlURL,
            );

            updateBugs([r.id], issueComment, r.fixed);
        }
    }
}

void handleReview(string action, PullRequest* _pr)
{
    import std.algorithm : among, filter;

    const PullRequest pr = *_pr;

    auto labels = ghGetRequest(pr.labelsURL)
        .readJson
        .deserializeJson!(GHLabel[]);
    if (auto method = autoMergeMethod(labels))
        pr.tryMerge(method);
}

void setBotTimer(C)(Duration dur, C callback)
{
    if (runAsync)
        setTimer(dur, callback);
    else
        callback();
}

//==============================================================================

void codecovHook(HTTPServerRequest req, HTTPServerResponse res)
{
    logDebug("codecovHook: %s", req.bodyReader.readAllUTF8);
    return res.writeBody("OK");
}

//==============================================================================

void buildkiteHook(HTTPServerRequest req, HTTPServerResponse res)
{
    import dlangbot.buildkite : Build, handleBuild, Pipeline, verifyRequest;

    auto json = verifyRequest(req.headers.get("X-Buildkite-Token"), req.bodyReader.readAllUTF8);
    logDebug("buildkiteHook: %s", json);
    switch (req.headers.get("X-Buildkite-Event"))
    {
    case "ping":
        return res.writeBody("handled");

    case "build.scheduled":
        auto pipeline = json["pipeline"]["name"].get!string;
        runTaskHelper(&handleBuild, pipeline);
        break;

    default:
        return res.writeBody("");
    }
    return res.writeBody("handled");
}

//==============================================================================

void agentShutdownCheck(HTTPServerRequest req, HTTPServerResponse res)
{
    import dlangbot.buildkite : agentShutdownCheck, verifyAgentRequest;
    import std.algorithm.searching : startsWith;

    verifyAgentRequest(req.headers.get("Authentication"));
    string hostname = req.form.get("hostname");
    logInfo("agentShutdownCheck hostname:%s", hostname);
    runTaskHelper(&agentShutdownCheck, hostname);
    res.writeBody("");
}

//==============================================================================

shared static this()
{
    import std.process : environment;
    version (linux)
    {
        // register memory error handler on heroku
        if ("DYNO" in environment)
        {
            import etc.linux.memoryerror : registerMemoryErrorHandler;
            registerMemoryErrorHandler();
        }
    }

}

version (unittest) {}
else void main(string[] args)
{
    import std.array : array;
    import std.algorithm.iteration : map;
    import std.process : environment;
    import vibe.core.args : readOption;

    githubAuth = "token "~environment["GH_TOKEN"];
    githubHookSecret = environment["GH_HOOK_SECRET"];
    trelloSecret = environment["TRELLO_SECRET"];
    trelloAuth = "key="~environment["TRELLO_KEY"]~"&token="~environment["TRELLO_TOKEN"];
    buildkiteAuth = "Bearer "~environment["BK_TOKEN"];
    buildkiteHookSecret = environment["BK_HOOK_SECRET"];
    scalewayAuth = environment["SCW_TOKEN"];
    scalewayOrg = environment["SCW_ORG"];
    hcloudAuth = "Bearer "~environment["HCLOUD_TOKEN"];
    dlangbotAgentAuth = "Bearer "~environment["DB_AGENT_TOKEN"];
    oAuth.config.consumerKey = environment["TWITTER_CONSUMER_KEY"];
    oAuth.config.consumerKeySecret = environment["TWITTER_CONSUMER_KEY_SECRET"];
    oAuth.config.accessToken = environment["TWITTER_ACCESS_TOKEN"];
    oAuth.config.accessTokenSecret = environment["TWITTER_ACCESS_TOKEN_SECRET"];
    bugzillaLogin = environment["BUGZILLA_LOGIN"];
    bugzillaPassword = environment["BUGZILLA_PASSWORD"];
    twitterEnabled = true;

    // workaround for stupid openssl.conf on Heroku
    if (environment.get("DYNO") !is null)
    {
        HTTPClient.setTLSSetupCallback((ctx) {
            ctx.useTrustedCertificateFile("/etc/ssl/certs/ca-certificates.crt");
        });
    }

    bool runDailyCron, runDailyCronSimulation;
    auto settings = new HTTPServerSettings;
    settings.port = 8080;
    readOption("port|p", &settings.port, "Sets the port used for serving.");
    readOption("simulate-cron-daily", &runDailyCronSimulation, "Sets the port used for serving.");
    // TODO: move (currently) unused cli crons to timer-based ones
    readOption("cron-daily", &runDailyCron, "Run daily cron tasks.");
    if (!finalizeCommandLineOptions())
        return;

    string[] cronRepositories;
    if (runDailyCron)
    {
        cronRepositories = ["dmd", "druntime", "phobos", "dlang.org", "tools", "installer"]
            .map!(r => "dlang/" ~ r).array;
    }
    else if (runDailyCronSimulation)
    {
        cronRepositories = ["dlang/phobos"];
    }

    if (cronRepositories)
    {
        CronConfig config = {simulate: runDailyCronSimulation};
        return cronDaily(cronRepositories, config);
    }

    startServer(settings);
    startCrons();
    lowerPrivileges();
    runEventLoop();
}

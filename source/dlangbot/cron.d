module dlangbot.cron;

import std.algorithm, std.range;
import std.datetime;
import std.format : format, formattedWrite;
import std.typecons : Tuple;

import vibe.core.log;
import vibe.data.json;

import dlangbot.github;
import dlangbot.github_api;

//==============================================================================
// Search for inactive PRs
//==============================================================================

struct CronConfig
{
    Duration stalledPRs = 90.days; // PRs with no activity within X days will get flagged
    Duration oldStablePRs = 3.days; // PRs targeting stable which should trigger a warning
    bool simulate;
    Duration waitAfterMergeNullState = 750.msecs; // Time to wait before refetching a PR with mergeable: null
}

alias PRTuple = Tuple!(PullRequest, "pr", GHComment[], "comments", GHComment[], "reviewComments", CronConfig, "config");
enum LabelAction {add, remove, none}
alias LabelResponse = Tuple!(LabelAction, "action", string, "label");

//==============================================================================
// Cron actions
//==============================================================================

auto findLastActivity(PRTuple t)
{
    auto now = Clock.currTime;

    // don't use updatedAt (labelling isn't an activity)
    // don't look at the events (could be spammed by CIs)
    SysTime lastComment = t.pr.createdAt;

    // comments and reviewComments are two different lists
    // -> take the newest date
    static foreach (el; ["comments", "reviewComments"])
    {{
        mixin("auto comments = t." ~ el ~ ";");
        if (comments.length)
        {
            auto date = comments[$ - 1].updatedAt;
            lastComment = max(lastComment, date);
        }
    }}

    auto timeDiff = now - lastComment;

    return timeDiff;
}

// label inactive PR
auto detectStalledPR(PRTuple t)
{
    // "stalled" gets automatically removed on a new push
    // be careful labeling changes the last updatedAt timestamp
    with(LabelAction)
    return LabelResponse(t.findLastActivity > t.config.stalledPRs ? add : remove, "stalled");
}

auto detectInactiveStablePR(PRTuple t)
{
    bool stalled = t.findLastActivity > t.config.oldStablePRs && t.pr.base.ref_ == "stable";
    with(LabelAction)
    return LabelResponse(stalled ? add : remove, "stable-stalled");
}

auto detectPRWithMergeConflicts(PRTuple t)
{
    import std.typecons : Nullable;

    if (t.pr.mergeable.isNull)
    {
        logInfo("[cron-daily/%s/%d/detectMerge]: mergeable is null.", t.pr.repoSlug, t.pr.number);
        // repeat request to receive computed mergeable information
        foreach (i; 0 .. 4)
        {
            import vibe.core.core : sleep;
            t.config.waitAfterMergeNullState.sleep;
            logInfo("[cron-daily/%s/%d/detectMerge]: repeating request", t.pr.repoSlug, t.pr.number);
            t.pr = t.pr.refresh;
            if (!t.pr.mergeable.isNull)
                goto mergable;
        }
        return LabelResponse(LabelAction.none, "");
    }
mergable:

    Nullable!bool isMergeable;
    if (!t.pr.mergeableState.isNull)
    {
        logInfo("[cron-daily/%s/%d/detectMerge]: mergeableState = %s", t.pr.repoSlug, t.pr.number, t.pr.mergeableState.get);
        with (PullRequest.MergeableState)
        final switch(t.pr.mergeableState.get)
        {
            case clean:
                // branch is up to date with master and has no conflicts
                isMergeable = true;
                break;
            case unstable:
                // branch isn't up to date with master, but has no conflicts
                isMergeable = true;
                break;
            case dirty:
                // GitHub detected conflicts
                isMergeable = false;
                break;
            case unknown, checking:
                // should only be set if mergeable is null
            case blocked:
                // the repo requires reviews and the PR hasn't been approved yet
                // the repo requires status checks and they have failed
                break;
        }
    }

    if (isMergeable.isNull)
    {
        if (t.pr.mergeable.isNull)
            return LabelResponse(LabelAction.none, "");

        logInfo("[cron-daily/%s/%d/detectMerge]: mergeable = %s", t.pr.repoSlug, t.pr.number, t.pr.mergeable.get);
        isMergeable = t.pr.mergeable.get;
    }

    // "needs rebase" gets automatically removed on a new push
    with(LabelAction)
    return LabelResponse(!isMergeable.get() ? add : remove, "needs rebase");
}

auto detectPRWithPersistentCIFailures(PRTuple t)
{
    // label PR with persistent CI failures
    // TODO: unclear whether we want all statuses for PR commit, or only the latest
    auto status = t.pr.combinedStatus;
    auto failCount = status.latestStatuses.filter!((e){
        if (e.state == CIState.failure ||
            e.state == CIState.error)
            switch (e.context) {
                case "auto-tester":
                case "CyberShadow/DAutoTest":
                case "continuous-integration/travis-ci/pr":
                case "continuous-integration/jenkins/pr-merge":
                case "appveyor":
                case "ci/circleci":
                    return true;
                default:
                    return false;
            }
        return false;
    }).walkLength;
    bool hasPersistentFailures = failCount >= 2;
    // "needs work" gets automatically removed on a new push
    with(LabelAction)
    return LabelResponse(hasPersistentFailures ? add : none, "needs work");
}

//==============================================================================
// Cron walker
//==============================================================================

auto walkPR(Actions)(string repoSlug, GHIssue issue, Actions actions, CronConfig config)
{
    const labels = issue.labels.map!(l => l.name).array.sort.release;
    string[] addLabels;
    string[] removeLabels;

    // only the detailed PR page contains more info like the mergeable state
    auto pr = ghGetRequest(issue.pullRequestURL).readJson.deserializeJson!PullRequest; // TODO: make const

    PRTuple t;
    t.pr = pr;
    t.config = config;
    // TODO: direction doesn't seem to work here
    // https://developer.github.com/v3/issues/comments/#list-comments-in-a-repository
    t.comments = ghGetRequest(pr.commentsURL).readJson.deserializeJson!(GHComment[]);
    t.reviewComments = ghGetRequest(pr.reviewCommentsURL).readJson.deserializeJson!(GHComment[]);

    // perform actions
    foreach (action; actions)
    {
        auto res = action(t);
        with(LabelAction)
        final switch(res.action)
        {
            case add:
                addLabels ~= res.label;
                break;
            case remove:
                removeLabels ~= res.label;
                break;
            case none:
                break;
        }
    }

    import std.uni : asLowerCase, sicmp;
    alias siEqual = (a, b) => sicmp(a, b) == 0;
    alias siLess = (a, b) => sicmp(a, b) < 0;
    // update labels
    auto putLabels = labels.chain(addLabels)
                        .array
                        .sort!siLess
                        .uniq!siEqual
                        .filter!(l => !removeLabels.map!asLowerCase.canFind(l.asLowerCase)).array;

    auto labelsSorted = labels.dup.sort!siLess;
    if (!labelsSorted.equal!siEqual(putLabels))
    {
        logInfo("[%s/%d/putLabels]: %s (before: %s)", repoSlug, pr.number, putLabels, labels);
        if (!config.simulate)
            pr.replaceLabels(putLabels);
    }
}

auto walkPRs(Actions)(string repoSlug, Actions actions, CronConfig config = CronConfig.init)
{
    // "updated" sorting is broken for PRs
    // As we need to load the PR itself anyways, we load all issues as
    // (1) the GitHubIssue object is smaller
    // (2) the GitHubIssue object contains respective labels of an issue
    auto pages = ghGetAllPages("%s/repos/%s/issues?state=open&sort=updated&direction=asc"
                        .format(githubAPIURL, repoSlug));

    size_t loadedPRs;
    foreach (page; pages)
    {
        foreach (idx, issueJson; page[].enumerate)
        {
            auto issue = issueJson.deserializeJson!GHIssue;
            logInfo("[cron-daily/%s/%d]: walkPR", repoSlug, issue.number);
            walkPR(repoSlug, issue, actions, config);

            // limit search for local testing
            version(unittest)
            if (idx >= 3)
                return;
        }
        loadedPRs += page[].length;
    }
    logInfo("ended cron.daily for repo: %s (prs: %d)", repoSlug, loadedPRs);
}

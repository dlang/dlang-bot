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
    // "needs rebase" gets automatically removed on a new push
    bool isMergeable = !t.pr.mergeable.isNull && t.pr.mergeable.get;
    with(LabelAction)
    return LabelResponse(!isMergeable ? add : remove, "needs rebase");
}

auto detectPRWithPersistentCIFailures(PRTuple t)
{
    // label PR with persistent CI failures
    auto status = t.pr.status;
    auto failCount = status.filter!((e){
        if (e.state == GHCiStatus.State.failure ||
            e.state == GHCiStatus.State.error)
            switch (e.context) {
                case "auto-tester":
                case "CyberShadow/DAutoTest":
                case "continuous-integration/travis-ci/pr":
                case "continuous-integration/travis-ci/jenkins":
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

    // update labels
    auto putLabels = labels.chain(addLabels)
                        .array
                        .sort.uniq
                        .filter!(l => !removeLabels.canFind(l)).array;

    if (!labels.equal(putLabels))
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

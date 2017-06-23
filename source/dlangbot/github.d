module dlangbot.github;

string githubAPIURL = "https://api.github.com";
string githubAuth, hookSecret;

import dlangbot.bugzilla : bugzillaURL, Issue, IssueRef;
import dlangbot.warnings : printMessages, UserMessage;

import std.algorithm, std.range;
import std.datetime;
import std.format : format, formattedWrite;
import std.typecons : Tuple;

import vibe.core.log;
import vibe.data.json;
import vibe.http.client : HTTPClientRequest, requestHTTP;
import vibe.http.common : HTTPMethod;
import vibe.stream.operations : readAllUTF8;

//==============================================================================
// Github comments
//==============================================================================

void printBugList(W)(W app, in IssueRef[] refs, in Issue[] descs)
{
    auto combined = zip(refs.map!(r => r.id), refs.map!(r => r.fixed), descs.map!(d => d.desc));
    app.put("Fix | Bugzilla | Description\n");
    app.put("--- | --- | ---\n");
    foreach (num, closed, desc; combined)
    {
        app.formattedWrite(
            "%1$s | [%2$s](%4$s/show_bug.cgi?id=%2$s) | %3$s\n",
            closed ? "✓" : "✗", num, desc, bugzillaURL);
    }
}

string formatComment(in ref PullRequest pr, in IssueRef[] refs, in Issue[] descs, in UserMessage[] msgs)
{
    import std.array : appender;

    auto app = appender!string;

    bool isMember = ghGetRequest(pr.membersURL)
        .readJson
        .deserializeJson!(GHUser[])
        .canFind!(l => l.login == pr.user.login);

    if (isMember)
    {
        app.formattedWrite(
`Thanks for your pull request, @%s!
`, pr.user.login, pr.repoSlug);
    }
    else
    {

    app.formattedWrite(
`Thanks for your pull request, @%s!  We are looking forward to reviewing it, and you should be hearing from a maintainer soon.

Some things that can help to speed things up:

- smaller, focused PRs are easier to review than big ones

- try not to mix up refactoring or style changes with bug fixes or feature enhancements

- provide helpful commit messages explaining the rationale behind each change

Bear in mind that large or tricky changes may require multiple rounds of review and revision.

Please see [CONTRIBUTING.md](https://github.com/%s/blob/master/CONTRIBUTING.md) for more information.

`, pr.user.login, pr.repoSlug);
    }

    if (refs.length)
    {
        app ~= "### Bugzilla references\n\n";
        app.printBugList(refs, descs);
    }
    if (msgs.length)
    {
        if (refs.length)
            app ~= "\n";
        app ~= "### Warnings\n\n";
        app.printMessages(msgs);
    }
    return app.data;
}

GHComment getBotComment(in ref PullRequest pr)
{
    // the bot may post multiple comments (mention-bot & bugzilla links)
    auto res = ghGetRequest(pr.commentsURL)
        .readJson[]
        .find!(c => c["user"]["login"] == "dlang-bot");
    if (res.length)
        return deserializeJson!GHComment(res[0]);
    return GHComment();
}

auto ghGetRequest(string url)
{
    return requestHTTP(url, (scope req) {
        req.headers["Authorization"] = githubAuth;
    });
}

auto ghGetRequest(scope void delegate(scope HTTPClientRequest req) userReq, string url)
{
    return requestHTTP(url, (scope req) {
        req.headers["Authorization"] = githubAuth;
        userReq(req);
    });
}

auto ghSendRequest(scope void delegate(scope HTTPClientRequest req) userReq, string url)
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

void updateGithubComment(in ref PullRequest pr, in ref GHComment comment,
                         string action, IssueRef[] refs, Issue[] descs, UserMessage[] msgs)
{
    logDebug("[github/updateGithubComment](%s): %s", pr.pid, refs);
    logDebug("%s", descs);
    assert(refs.map!(r => r.id).equal(descs.map!(d => d.id)));

    auto msg = pr.formatComment(refs, descs, msgs);
    logDebug("%s", msg);

    if (msg != comment.body_)
    {
        if (comment.url.length)
            comment.update(msg);
        else if (action != "closed" && action != "merged")
            comment.post(pr, msg);
    }
}


//==============================================================================
// Github Auto-merge
//==============================================================================

alias LabelsAndCommits = Tuple!(Json[], "labels", Json[], "commits");
enum MergeMethod { none = 0, merge, squash, rebase }

string labelName(MergeMethod method)
{
    final switch (method) with (MergeMethod)
    {
    case none: return null;
    case merge: return "auto-merge";
    case squash: return "auto-merge-squash";
    case rebase: return "auto-merge-rebase";
    }
}

MergeMethod autoMergeMethod(Json[] labels)
{
    auto labelNames = labels.map!(l => l["name"].get!string);
    if (labelNames.canFind!(l => l == "auto-merge"))
        return MergeMethod.merge;
    else if (labelNames.canFind!(l => l == "auto-merge-squash"))
        return MergeMethod.squash;
    else if (labelNames.canFind!(l => l == "auto-merge-rebase"))
        return MergeMethod.rebase;
    return MergeMethod.none;
}

auto handleGithubLabel(in ref PullRequest pr)
{
    auto labels = ghGetRequest(pr.labelsURL).readJson[];

    Json[] commits;
    if (auto method = labels.autoMergeMethod)
        commits = pr.tryMerge(method);

    return LabelsAndCommits(labels, commits);
}

Json[] tryMerge(in ref PullRequest pr, MergeMethod method)
{
    import std.conv : to;

    auto commits = ghGetRequest(pr.commitsURL).readJson[];

    if (!pr.isOpen)
    {
        logWarn("Can't auto-merge PR %s/%d - it is already closed", pr.repoSlug, pr.number);
        return commits;
    }

    if (commits.length == 0)
    {
        logWarn("Can't auto-merge PR %s/%d has no commits attached", pr.repoSlug, pr.number);
        return commits;
    }

    auto labelName = method.labelName;
    auto events = ghGetRequest(pr.eventsURL).readJson[]
        .retro
        .filter!(e => e["event"] == "labeled" && e["label"]["name"] == labelName);

    string author = "unknown";
    if (!events.empty)
        author = getUserEmail(events.front["actor"]["login"].get!string);

    GHMerge mergeInput = {
        commitMessage: "%s\nmerged-on-behalf-of: %s".format(pr.title, author),
        sha: commits[$ - 1]["sha"].get!string,
        mergeMethod: method
    };
    pr.postMerge(mergeInput);

    return commits;
}

void checkAndRemoveLabels(Json[] labels, in ref PullRequest pr, in string[] toRemoveLabels)
{
    labels
        .map!(l => l["name"].get!string)
        .filter!(n => toRemoveLabels.canFind(n))
        .each!(l => pr.removeLabel(l));
}

void addLabels(in ref PullRequest pr, inout string[] labels)
{
    ghSendRequest(HTTPMethod.POST, pr.labelsURL, labels);
}

void removeLabel(in ref PullRequest pr, string label)
{
    ghSendRequest(HTTPMethod.DELETE, pr.labelsURL ~ "/" ~ label);
}

void replaceLabels(in ref PullRequest pr, string[] labels)
{
    ghSendRequest(HTTPMethod.PUT, pr.labelsURL, labels);
}

string getUserEmail(string login)
{
    auto user = ghGetRequest("%s/users/%s".format(githubAPIURL, login)).readJson;
    auto name = user["name"].get!string;
    auto email = user["email"].opt!string(login ~ "@users.noreply.github.com");
    return "%s <%s>".format(name, email);
}

Json[] getIssuesForLabel(string repoSlug, string label)
{
    return ghGetRequest("%s/repos/%s/issues?state=open&labels=%s"
                .format(githubAPIURL, repoSlug, label)).readJson[];
}

auto getIssuesForLabels(string repoSlug, const string[] labels)
{
    // the GitHub API doesn't allow a logical OR
    Json[] issues;
    foreach (label; labels)
        issues ~= getIssuesForLabel(repoSlug, label);
    issues.sort!((a, b) => a["number"].get!int < b["number"].get!int);
    return issues.uniq!((a, b) => a["number"].get!int == b["number"].get!int);
}

void searchForAutoMergePrs(string repoSlug)
{
    static immutable labels = ["auto-merge", "auto-merge-squash"];
    foreach (issue; getIssuesForLabels(repoSlug, labels))
    {
        auto prNumber = issue["number"].get!uint;
        if ("pull_request" !in issue)
            continue;

        PullRequest pr;
        pr.base.repo.fullName = repoSlug;
        pr.number = prNumber;
        pr.state = PullRequest.State.open;
        pr.title = issue["title"].get!string;
        if (auto method = autoMergeMethod(issue["labels"][]))
            pr.tryMerge(method);
    }
}

/**
Allows contributors to use [<label>] messages in the title.
If they are part of a pre-defined, allowed list, the bot will add the
respective label.
*/
void checkTitleForLabels(in ref PullRequest pr)
{
    import std.algorithm.iteration : splitter;
    import std.regex;
    import std.string : strip, toLower;

    static labelRe = regex(`\[(.*)\]`);
    string[] userLabels;
    foreach (m; pr.title.matchAll(labelRe))
    {
        foreach (el; m[1].splitter(","))
            userLabels ~= el;
    }

    const string[string] userLabelsMap = [
        "trivial": "trivial",
        "wip": "WIP"
    ];

    auto mappedLabels = userLabels
                            .sort()
                            .uniq
                            .map!strip
                            .map!toLower
                            .filter!(l => l in userLabelsMap)
                            .map!(l => userLabelsMap[l])
                            .array;

    if (mappedLabels.length)
        pr.addLabels(mappedLabels);
}

//==============================================================================
// Search for inactive PRs
//==============================================================================

// range-based page loader for the GH API
private struct AllPages
{
    private string url;
    private string link = "next";

    // does not cache
    Json front() {
        scope req = ghGetRequest(url);
        link = req.headers.get("Link");
        return req.readJson;
    }
    void popFront()
    {
        import std.utf : byCodeUnit;
        if (link)
            url = link[1..$].byCodeUnit.until(">").array;
    }
    bool empty()
    {
        return !link.canFind("next");
    }
}

auto ghGetAllPages(string url)
{
    return AllPages(url);
}

void searchForInactivePrs(string repoSlug, Duration dur)
{
    auto now = Clock.currTime;
    // "updated" sorting is broken for PRs
    // As we need to load the PR itself anyways, we load all issues as
    // (1) the GitHubIssue object is smaller
    // (2) the GitHubIssue object contains respective labels of an issue
    auto pages = ghGetAllPages("%s/repos/%s/issues?state=open&sort=updated&direction=asc"
                        .format(githubAPIURL, repoSlug));

    int loadedPages;
    foreach (page; pages)
    {
        foreach (i, issue; page[])
        {
            auto labels = issue["labels"][].map!(l => l["name"].get!string).array.sort();
            string[] sendLabels;
            string[] removeLabels;

            // only the detailed PR page contains the mergeable state
            const pr = ghGetRequest(issue["pull_request"]["url"].get!string)
                        .readJson.deserializeJson!PullRequest;

            // fetch the recent comments
            // TODO: direction doesn't seem to work here
            // https://developer.github.com/v3/issues/comments/#list-comments-in-a-repository
            const lastComment = ghGetRequest(pr.commentsURL)
                                .readJson[$ - 1].deserializeJson!GHComment;

            auto timeDiff = now - lastComment.updatedAt;

            // label inactive PR
            // be careful labeling changes the last updatedAt timestamp
            if (timeDiff > dur)
                sendLabels ~= "stalled";
            else
                removeLabels ~= "stalled";

            // label PR with merge-conflicts
            if (!pr.mergeable.isNull)
            {
                if (pr.mergeable.get)
                    removeLabels ~= "needs rebase";
                else
                    sendLabels ~= "needs rebase";
            }

            // label PR with persistent CI failures
            auto status = pr.status;
            auto failCount = status.filter!((e){
                if (e.state == GHCiStatus.State.failure ||
                    e.state == GHCiStatus.State.error)
                    switch (e.context) {
                        case "auto-tester":
                        case "CyberShadow/DAutoTest":
                        case "continuous-integration/travis-ci/pr":
                        case "ci/circleci":
                            return true;
                        default:
                            return false;
                    }
                return false;
            }).walkLength;
            if (failCount >= 2)
                sendLabels ~= "needs work";

            auto putLabels = labels.chain(sendLabels).sort.uniq
                                .filter!(l => !removeLabels.canFind(l)).array;

            if (!labels.equal(putLabels))
                pr.replaceLabels(putLabels);

            // limit search for local testing
            version(unittest)
            if (i >= 3)
                return;
        }
        loadedPages += page[].length;
    }
    logInfo("ended cron.daily for repo: %s (pages: %d)", repoSlug, loadedPages);
}

//==============================================================================
// Github API objects
//==============================================================================

struct PullRequest
{
    import std.typecons : Nullable;

    static struct Repo
    {
        @name("full_name") string fullName;
        GHUser owner;
    }
    static struct Branch
    {
        string sha;
        string ref_;
        Repo repo;
    }
    Branch base, head;
    enum State { open, closed }
    enum MergeableState { clean, dirty, unstable, blocked, unknown }
    @byName State state;
    uint number;
    string title;
    @optional Nullable!bool mergeable;
    @optional @byName Nullable!MergeableState mergeable_state;
    @name("created_at") SysTime createdAt;
    @name("updated_at") SysTime updatedAt;
    bool locked;

    GHUser user;
    Nullable!GHUser assignee;
    GHUser[] assignees;

    string baseRepoSlug() const { return base.repo.fullName; }
    string headRepoSlug() const { return head.repo.fullName; }
    alias repoSlug = baseRepoSlug;
    bool isOpen() const { return state == State.open; }

    string htmlURL() const { return "https://github.com/%s/pull/%d".format(repoSlug, number); }
    string commentsURL() const { return "%s/repos/%s/issues/%d/comments".format(githubAPIURL, repoSlug, number); }
    string commitsURL() const { return "%s/repos/%s/pulls/%d/commits".format(githubAPIURL, repoSlug, number); }
    string eventsURL() const { return "%s/repos/%s/issues/%d/events".format(githubAPIURL, repoSlug, number); }
    string labelsURL() const { return "%s/repos/%s/issues/%d/labels".format(githubAPIURL, repoSlug, number); }
    string reviewsURL() const { return "%s/repos/%s/pulls/%d/reviews".format(githubAPIURL, repoSlug, number); }
    string mergeURL() const { return "%s/repos/%s/pulls/%d/merge".format(githubAPIURL, repoSlug, number); }
    string statusURL() const { return "%s/repos/%s/status/%s".format(githubAPIURL, repoSlug, head.sha); }
    string membersURL() const { return "%s/orgs/%s/public_members".format(githubAPIURL, base.repo.owner.login); }

    string pid() const
    {
        import std.conv : text;
        return text(repoSlug, "/", number);
    }

    GHComment[] comments() const {
        return ghGetRequest(commentsURL)
                .readJson
                .deserializeJson!(GHComment[]);
    }
    GHCommit[] commits() const {
        return ghGetRequest(commitsURL)
                .readJson
                .deserializeJson!(GHCommit[]);
    }
    GHReview[] reviews() const {
        return ghGetRequest((scope req) {
            // custom media type is required during preview period:
            // preview review api: https://developer.github.com/changes/2016-12-14-reviews-api
            req.headers["Accept"] = "application/vnd.github.black-cat-preview+json";
        }, reviewsURL)
            .readJson
            .deserializeJson!(GHReview[]);
    }
    GHCiStatus[] status() const {
        return ghGetRequest(statusURL)
                .readJson["statuses"]
                .deserializeJson!(GHCiStatus[]);
    }

    void postMerge(in ref GHMerge merge) const
    {
        ghSendRequest((scope req){
            req.method = HTTPMethod.PUT;
            // custom media type is required during preview period:
            // https://developer.github.com/changes/2016-09-26-pull-request-merge-api-update/
            req.headers["Accept"] = "application/vnd.github.polaris-preview+json";
            req.writeJsonBody(merge);
        }, mergeURL);
    }
}

static struct GHUser
{
    string login;
    ulong id;
    @name("avatar_url") string avatarURL;
    @name("gravatar_id") string gravatarId;
    string type;
    @name("site_admin") bool siteAdmin;
}

struct GHComment
{
    @name("created_at") SysTime createdAt;
    @name("updated_at") SysTime updatedAt;
    GHUser user;
    string body_;
    string url;

    static void post(in ref PullRequest pr, string msg)
    {
        ghSendRequest(HTTPMethod.POST, pr.commentsURL, ["body" : msg]);
    }

    void update(string msg) const
    {
        ghSendRequest(HTTPMethod.PATCH, url, ["body" : msg]);
    }

    void remove() const
    {
        if (url.length) // delete any existing comment
            ghSendRequest(HTTPMethod.DELETE, url);
    }
}

struct GHReview
{
    GHUser user;
    @name("commit_id") string commitId;
    string body_;
    enum State { APPROVED, CHANGES_REQUESTED, COMMENTED }
    @byName State state;
}

struct GHCommit
{
    string sha;
    static struct CommitAuthor
    {
        string name;
        string email;
        SysTime date;
    }
    static struct Commit
    {
        CommitAuthor author;
        CommitAuthor committer;
        string message;
    }
    Commit commit;
    GHUser author;
    GHUser committer;
}

struct GHCiStatus
{
    enum State { success, error, failure, pending }
    @byName State state;
    string description;
    @name("target_url") string targetUrl;
    string context; // "CyberShadow/DAutoTest", "Project Tester",
                    // "ci/circleci", "auto-tester", "codecov/project",
                    // "codecov/patch", "continuous-integration/travis-ci/pr"
}

struct GHMerge
{
    @name("commit_message") string commitMessage;
    string sha;
    @name("merge_method") @byName MergeMethod mergeMethod;
}

//==============================================================================
// Github hook signature
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

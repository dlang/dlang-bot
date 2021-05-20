module dlangbot.github_api;

shared string githubAPIURL = "https://api.github.com";
shared string githubAuth, githubHookSecret;

import std.algorithm, std.range;
import std.datetime : SysTime;
import std.format : format;
import std.meta : AliasSeq;
import std.typecons : Nullable;

import vibe.core.log;
import vibe.data.json;
import vibe.http.client : HTTPClientRequest;
public import vibe.http.common : HTTPMethod;
import vibe.stream.operations : readAllUTF8;

import dlangbot.utils : request;

auto ghGetRequest(string url)
{
    return request(url, (scope req) {
        req.headers["Authorization"] = githubAuth;
    });
}

auto ghGetRequest(scope void delegate(scope HTTPClientRequest req) userReq, string url)
{
    return request(url, (scope req) {
        req.headers["Authorization"] = githubAuth;
        userReq(req);
    });
}

auto ghSendRequest(scope void delegate(scope HTTPClientRequest req) userReq, string url)
{
    HTTPMethod method;
    request(url, (scope req) {
        req.headers["Authorization"] = githubAuth;
        userReq(req);
        method = req.method;
    }, (scope res) {
        if (res.statusCode / 100 == 2)
        {
            logInfo("%s %s, %s\n", method, url, res.statusPhrase);
            res.bodyReader.readAllUTF8;
        }
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

//==============================================================================
// Github API objects
//==============================================================================

struct PullRequest
{
    static struct Repo
    {
        import vibe.data.json : Name = name;
        ulong id;
        string name;
        bool private_;
        string description;
        bool fork;
        @Name("full_name") string fullName;
        GHUser owner;
        @Name("created_at") SysTime createdAt;
        @Name("updated_at") Nullable!SysTime updatedAt;
        @Name("pushed_at") Nullable!SysTime pushedAt;
        @Name("git_url") string gitURL;
        @Name("ssh_url") string sshURL;
        @Name("clone_url") string cloneURL;
        @Name("svn_url") string svnURL;
        Nullable!string homepage;
        ulong size;
        @Name("stargazers_count") ulong stargazersCount;
        @Name("watchers_count") ulong watchersCount;
        Nullable!string language;
        @Name("has_issues") bool hasIssues;
        @Name("has_downloads") bool hasDownloads;
        @Name("has_wiki") bool hasWiki;
        @Name("has_pages") bool hasPages;
        @Name("forks_count") ulong forksCount;
        @Name("mirror_url") Nullable!string mirrorURL;
        @Name("open_issues_count") ulong openIssuesCount;
        ulong forks;
        @Name("default_branch") string defaultBranch;

    }
    static struct Branch
    {
        string sha;
        string ref_;
        Nullable!string label;
        Nullable!GHUser user;
        Nullable!Repo repo;
    }
    Branch base, head;
    enum MergeableState { checking, clean, dirty, unstable, blocked, unknown, draft }
    @byName GHState state;
    uint number;
    string url;
    string title;
    @optional Nullable!bool mergeable;
    // https://platform.github.community/t/documentation-about-mergeable-state/4259
    @optional @byName @name("mergeable_state") Nullable!MergeableState mergeableState;
    @name("created_at") SysTime createdAt;
    @name("updated_at") SysTime updatedAt;
    @name("closed_at") Nullable!SysTime closedAt;
    bool locked;
    // TODO: update payloads
    //@name("maintainer_can_modify") bool maintainerCanModify;
    @optional @name("comments") ulong nrComments;
    @optional @name("review_comments") ulong nrReviewComments;
    @optional @name("commits") ulong nrCommits;
    @optional @name("additions") ulong nrAdditions;
    @optional @name("deletions") ulong nrDeletions;
    @optional @name("changed_files") ulong nrChangedFiles;

    GHUser user;
    Nullable!GHUser assignee;
    GHUser[] assignees;
    Nullable!GHMilestone milestone;

    string baseRepoSlug() const { return base.repo.get().fullName; }
    string headRepoSlug() const { return head.repo.get().fullName; }
    alias repoSlug = baseRepoSlug;
    bool isOpen() const { return state == GHState.open; }

    string htmlURL() const { return "https://github.com/%s/pull/%d".format(repoSlug, number); }
    string commentsURL() const { return "%s/repos/%s/issues/%d/comments".format(githubAPIURL, repoSlug, number); }
    string reviewCommentsURL() const { return "%s/repos/%s/pulls/%d/comments".format(githubAPIURL, repoSlug, number); }
    string commitsURL() const { return "%s/repos/%s/pulls/%d/commits".format(githubAPIURL, repoSlug, number); }
    string eventsURL() const { return "%s/repos/%s/issues/%d/events".format(githubAPIURL, repoSlug, number); }
    string labelsURL() const { return "%s/repos/%s/issues/%d/labels".format(githubAPIURL, repoSlug, number); }
    string reviewsURL() const { return "%s/repos/%s/pulls/%d/reviews".format(githubAPIURL, repoSlug, number); }
    string mergeURL() const { return "%s/repos/%s/pulls/%d/merge".format(githubAPIURL, repoSlug, number); }
    string combinedStatusURL() const { return "%s/repos/%s/commits/%s/status".format(githubAPIURL, repoSlug, head.sha); }
    string membersURL() const { return "%s/orgs/%s/public_members".format(githubAPIURL, base.repo.get().owner.login); }

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
    /// get combined status (contains latest status for each CI context)
    GHCombinedCIStatus combinedStatus() const {
        return ghGetRequest(combinedStatusURL)
                .readJson
                .deserializeJson!GHCombinedCIStatus;
    }

    GHLabel[] labels() const {
        return ghGetRequest(labelsURL)
                .readJson
                .deserializeJson!(GHLabel[]);
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

    typeof(this) refresh() {
        return ghGetRequest(url)
                .readJson
                .deserializeJson!(typeof(this));
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
    Nullable!GHUser user;
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

enum CIState { error /*default*/, failure, success, pending }

struct GHCIStatus
{
    @byName CIState state;
    string description;
    @name("target_url") string targetUrl;
    string context; // "CyberShadow/DAutoTest", "Project Tester",
                    // "ci/circleci", "auto-tester", "codecov/project",
                    // "codecov/patch", "continuous-integration/travis-ci/pr"
}

struct GHCombinedCIStatus
{
    @byName CIState state;
    @name("statuses") GHCIStatus[] latestStatuses; // latest per context
}

struct GHMerge
{
    enum MergeMethod { none = 0, merge, squash, rebase }
    @name("commit_message") string commitMessage;
    string sha;
    @name("merge_method") @byName MergeMethod mergeMethod;
}

struct GHLabel
{
    ulong id;
    string url;
    string name;
    string color;
    bool default_;
}

enum GHState { open, closed }

struct GHIssue
{
    static struct SimplifiedGHPullRequest
    {
        string url;
    }
    // this isn't really useful except for detecting whether it's a pull request
    @name("pull_request") Nullable!SimplifiedGHPullRequest _pullRequest;

    bool isPullRequest() const
    {
        return !_pullRequest.isNull;
    }
    uint number;
    ulong id;
    string title;
    string url;
    GHUser user;
    GHLabel[] labels;
    @byName GHState state;
    bool locked;
    Nullable!GHUser assignee;
    GHUser[] assignees;
    Nullable!GHMilestone milestone;
    ulong comments;
    @name("created_at") SysTime createdAt;
    @name("updated_at") SysTime updatedAt;
    @name("closed_at") Nullable!SysTime closedAt;
    Nullable!string body_;

    string labelsURL() const { return "%s/repos/%s/issues/%d/labels".format(githubAPIURL, repoSlug, number); }
    string commentsURL() const { return "%s/repos/%s/issues/%d/comments".format(githubAPIURL, repoSlug, number); }
    string eventsURL() const { return "%s/repos/%s/issues/%d/events".format(githubAPIURL, repoSlug, number); }
    string pullRequestURL() const { return "%s/repos/%s/pulls/%d".format(githubAPIURL, repoSlug, number); }

    @name("repository_url") string repositoryURL;
    string repoSlug() const
    {
        int slashes;
        return repositoryURL[$ - repositoryURL.retro.countUntil!((c){
            if (c == '/') slashes++;
            return slashes >= 2;
        }) .. $];
    }

    unittest
    {
        GHIssue issue;
        issue.repositoryURL = "https://api.github.com/repos/dlang/phobos";
        assert(issue.repoSlug == "dlang/phobos");
    }

    PullRequest pullRequest() const
    {
        assert(isPullRequest);

        return ghGetRequest(_pullRequest.get().url)
                .readJson
                .deserializeJson!PullRequest;
    }
}

struct GHMilestone
{
    string url;
    @name("html_url") string htmlURL;
    @name("labels_url") string labelsURL;
    uint number;
    ulong id;
    string title;
    Nullable!string description;
    GHUser creator;
    @name("open_issues") ulong openIssues;
    @name("closed_issues") ulong closedIssues;
    @byName GHState state;
    @name("created_at") SysTime createdAt;
    @name("updated_at") SysTime updatedAt;
    @name("due_on") Nullable!SysTime dueOn;
    @name("closed_at") Nullable!SysTime closedAt;
}

//==============================================================================
// Github hook signature
//==============================================================================

auto getSignature(string data)
{
    import std.digest, std.digest.hmac, std.digest.sha;
    import std.string : representation;

    auto hmac = HMAC!SHA1(githubHookSecret.representation);
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

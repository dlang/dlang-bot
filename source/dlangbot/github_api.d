module dlangbot.github_api;

string githubAPIURL = "https://api.github.com";
string githubAuth, hookSecret;

import std.algorithm, std.range;
import std.datetime : SysTime;
import std.format : format;

import vibe.core.log;
import vibe.data.json;
import vibe.http.client : HTTPClientRequest, requestHTTP;
public import vibe.http.common : HTTPMethod;
import vibe.stream.operations : readAllUTF8;

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
    enum MergeMethod { none = 0, merge, squash, rebase }
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

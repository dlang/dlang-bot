import app;
import utils;

import vibe.d;
import std.functional;
import std.stdio;

// existing dlang bot comment -> update comment
unittest
{
    auto expectedURLs = ["/github/repos/dlang/phobos/pulls/4921/commits",
                         "/github/repos/dlang/phobos/issues/4921/labels",
                         "/github/repos/dlang/phobos/issues/4921/comments",
                         "/bugzilla/buglist.cgi?bug_id=8573&ctype=csv&columnlist=short_desc",
                         "/github/repos/dlang/phobos/issues/comments/262784442"];

    payloader = (scope HTTPServerRequest req, scope HTTPServerResponse res) {
        if (req.requestURL == "/github/repos/dlang/phobos/issues/comments/262784442")
        {
            assert(req.method == HTTPMethod.PATCH);
            auto expectedComment =
`Fix | Bugzilla | Description
--- | --- | ---
✗ | [8573](%s/show_bug.cgi?id=8573) | A simpler Phobos function that returns the index of the mix or max item
`.format(bugzillaURL);
            assert(req.json["body"].get!string == expectedComment);
            res.writeVoidBody;
            return DirectionTypes.STOP;
        }
        return DirectionTypes.CONTINUE;
    }.toDelegate();

    "./payloads/github_hooks/dlang_phobos_synchronize_4921.json".buildGitHubRequest(expectedURLs);
}

// no existing dlang bot comment -> create comment
unittest
{
    auto expectedURLs = ["/github/repos/dlang/phobos/pulls/4921/commits",
                         "/github/repos/dlang/phobos/issues/4921/labels",
                         "/github/repos/dlang/phobos/issues/4921/comments",
                         "/bugzilla/buglist.cgi?bug_id=8573&ctype=csv&columnlist=short_desc",
                         "/github/repos/dlang/phobos/issues/4921/comments"];

    payloader = (scope HTTPServerRequest req, scope HTTPServerResponse res) {
        // be careful this URL is called twice, once as GET and afterwards a POST to submit the new comment
        if (req.requestURL == "/github/repos/dlang/phobos/issues/4921/comments" && expectedURLs.length == 0)
        {
            assert(req.method == HTTPMethod.POST);
            auto expectedComment =
`Fix | Bugzilla | Description
--- | --- | ---
✗ | [8573](%s/show_bug.cgi?id=8573) | A simpler Phobos function that returns the index of the mix or max item
`.format(bugzillaURL);
            assert(req.json["body"].get!string == expectedComment);
            res.writeVoidBody;
            return DirectionTypes.STOP;
        }
        return DirectionTypes.CONTINUE;
    }.toDelegate();

    jsonPostprocessor = (scope HTTPServerRequest req, Json j) {
        if (req.requestURL == "/github/repos/dlang/phobos/issues/4921/comments")
            return Json.emptyArray;
        return j;
    };

    "./payloads/github_hooks/dlang_phobos_synchronize_4921.json".buildGitHubRequest(expectedURLs);
}

// existing dlang bot comment, but no commits that reference a issue
// -> delete comment
unittest
{
    auto expectedURLs = ["/github/repos/dlang/phobos/pulls/4921/commits",
                         "/github/repos/dlang/phobos/issues/4921/labels",
                         "/github/repos/dlang/phobos/issues/4921/comments",
                         "/github/repos/dlang/phobos/issues/comments/262784442"];

    payloader = (scope HTTPServerRequest req, scope HTTPServerResponse res) {
        if (req.requestURL == "/github/repos/dlang/phobos/issues/comments/262784442")
        {
            assert(req.method == HTTPMethod.DELETE);
            res.writeVoidBody;
            return DirectionTypes.STOP;
        }
        return DirectionTypes.CONTINUE;
    }.toDelegate();

    jsonPostprocessor = (scope HTTPServerRequest req, Json j) {
        if (req.requestURL == "/github/repos/dlang/phobos/pulls/4921/commits")
            return Json.emptyArray;
        return j;
    };

    "./payloads/github_hooks/dlang_phobos_synchronize_4921.json".buildGitHubRequest(expectedURLs);
}

// existing dlang bot comment -> update comment
// auto-merge label -> remove (due to synchronization)
unittest
{
    auto expectedURLs = [
        "/github/repos/dlang/phobos/pulls/4921/commits",
        "/github/repos/dlang/phobos/issues/4921/labels",
        "/github/repos/dlang/phobos/issues/4921/labels/auto-merge",
        "/github/repos/dlang/phobos/issues/4921/comments",
        "/bugzilla/buglist.cgi?bug_id=8573&ctype=csv&columnlist=short_desc",
        "/github/repos/dlang/phobos/issues/comments/262784442"
    ];

    payloader = (scope HTTPServerRequest req, scope HTTPServerResponse res) {
        if (req.requestURL == "/github/repos/dlang/phobos/issues/4921/labels/auto-merge")
        {
            assert(req.method == HTTPMethod.DELETE);
            res.statusCode = 200;
            res.writeVoidBody;
            return DirectionTypes.STOP;
        }
        return DirectionTypes.CONTINUE;
    }.toDelegate();

    jsonPostprocessor = (scope HTTPServerRequest req, Json j) {
        if (req.requestURL == "/github/repos/dlang/phobos/issues/4921/labels")
            j[0]["name"] = "auto-merge";

        return j;
    };

    //"./payloads/github_hooks/dlang_phobos_synchronize_4921.json".buildGitHubRequest(expectedURLs);
}



// send pending status event -> no action
unittest
{
    string[] expectedURLs = [];

    payloader = (scope HTTPServerRequest req, scope HTTPServerResponse res) {
        return DirectionTypes.CONTINUE;
    }.toDelegate();

    "./payloads/github_hooks/dlang_dmd_status_6324.json".buildGitHubRequest(expectedURLs, (ref Json j, scope HTTPClientRequest req){
        req.headers["X-GitHub-Event"] = "status";
    });
}

// send failed status event -> no action
unittest
{
    string[] expectedURLs = [];

    payloader = (scope HTTPServerRequest req, scope HTTPServerResponse res) {
        return DirectionTypes.CONTINUE;
    }.toDelegate();

    "./payloads/github_hooks/dlang_dmd_status_6324.json".buildGitHubRequest(expectedURLs, (ref Json j, scope HTTPClientRequest req){
        j["state"] = "failed";
        req.headers["X-GitHub-Event"] = "status";
    });
}


// send success status event -> tryMergeForAllOpenPrs -> no action (no auto-merge PR)
unittest
{
    auto expectedURLs = [
        "/github/repos/dlang/dmd/pulls?state=open",
        "/github/repos/dlang/dmd/issues/6327/labels",
        "/github/repos/dlang/dmd/issues/6325/labels",
    ];

    payloader = (scope HTTPServerRequest req, scope HTTPServerResponse res) {
        return DirectionTypes.CONTINUE;
    }.toDelegate();

    jsonPostprocessor = (scope HTTPServerRequest req, Json j) {
        if (req.requestURL == "/github/repos/dlang/dmd/pulls?state=open")
        {
            Json k = j[0..2];
            return k;
        }

        return j;
    };

    "./payloads/github_hooks/dlang_dmd_status_6324.json".buildGitHubRequest(expectedURLs, (ref Json j, scope HTTPClientRequest req){
        j["state"] = "success";
        req.headers["X-GitHub-Event"] = "status";
    });
}

// send success status event -> don't trigger PR check due to being within the same time frame
unittest
{
    string[] expectedURLs = [];

    jsonPostprocessor = (scope HTTPServerRequest req, Json j) {
        if (req.requestURL == "/github/repos/dlang/dmd/pulls?state=open")
        {
            Json k = j[0..2];
            return k;
        }

        return j;
    };

    "./payloads/github_hooks/dlang_dmd_status_6324.json".buildGitHubRequest(expectedURLs, (ref Json j, scope HTTPClientRequest req){
        j["state"] = "success";
        req.headers["X-GitHub-Event"] = "status";
    });
}

// send success status event -> tryMergeForAllOpenPrs -> merge()
// PR 6237 has the label "auto-merge"
unittest
{
    auto expectedURLs = [
        "/github/repos/dlang/dmd/pulls?state=open",
        "/github/repos/dlang/dmd/issues/6327/labels",
        "/github/repos/dlang/dmd/pulls/6327/commits",
        "/github/repos/dlang/dmd/pulls/6327/merge",
        "/github/repos/dlang/dmd/issues/6325/labels",
    ];

    payloader = (scope HTTPServerRequest req, scope HTTPServerResponse res) {
        if (req.requestURL == "/github/repos/dlang/dmd/pulls/6327/merge")
        {
            assert(req.json["sha"] == "782fd3fdd4a9c23e1307b4b963b443ed60517dfe");
            assert(req.json["merge_method"] == "merge");
            res.statusCode = 200;
            res.writeVoidBody;
            return DirectionTypes.STOP;
        }
        return DirectionTypes.CONTINUE;
    }.toDelegate();

    jsonPostprocessor = (scope HTTPServerRequest req, Json j) {
        if (req.requestURL == "/github/repos/dlang/dmd/pulls?state=open")
        {
            Json k = j[0..2];
            return k;
        }
        if (req.requestURL == "/github/repos/dlang/dmd/issues/6327/labels")
            j[0]["name"] = "auto-merge";
        return j;
    };

    "./payloads/github_hooks/dlang_dmd_status_6324.json".buildGitHubRequest(expectedURLs, (ref Json j, scope HTTPClientRequest req){
        j["state"] = "success";
        req.headers["X-GitHub-Event"] = "status";
        timeBetweenFullPRChecks = 0.seconds;
    });
}

// send merge event
unittest
{
    auto expectedURLs = ["/github/repos/dlang/phobos/pulls/4963/commits",
                         "/github/repos/dlang/phobos/issues/4963/comments"];

    "./payloads/github_hooks/dlang_phobos_merged_4963.json".buildGitHubRequest(expectedURLs);
}

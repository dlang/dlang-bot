import app;
import utils;

import vibe.d;

// existing dlang bot comment -> update comment
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/pulls/4921/commits",
        "/github/repos/dlang/phobos/issues/4921/comments",
        "/bugzilla/buglist.cgi?bug_id=8573&ctype=csv&columnlist=short_desc",
        "/github/repos/dlang/phobos/issues/comments/262784442",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.PATCH);
            auto expectedComment =
`Fix | Bugzilla | Description
--- | --- | ---
✗ | [8573](%s/show_bug.cgi?id=8573) | A simpler Phobos function that returns the index of the mix or max item
`.format(bugzillaURL);
            assert(req.json["body"].get!string == expectedComment);
            res.writeVoidBody;
        }
    );

    postGitHubHook("dlang_phobos_synchronize_4921.json");
}

// no existing dlang bot comment -> create comment
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/pulls/4921/commits",
        "/github/repos/dlang/phobos/issues/4921/comments", (ref Json j) {
            j = Json.emptyArray;
        },
        "/bugzilla/buglist.cgi?bug_id=8573&ctype=csv&columnlist=short_desc",
        "/github/repos/dlang/phobos/issues/4921/comments",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.POST);
            auto expectedComment =
`Fix | Bugzilla | Description
--- | --- | ---
✗ | [8573](%s/show_bug.cgi?id=8573) | A simpler Phobos function that returns the index of the mix or max item
`.format(bugzillaURL);
            assert(req.json["body"].get!string == expectedComment);
            res.writeVoidBody;
        }
    );

    postGitHubHook("dlang_phobos_synchronize_4921.json");
}

// existing dlang bot comment, but no commits that reference a issue
// -> delete comment
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/pulls/4921/commits", (ref Json j) {
            j = Json.emptyArray;
         },
         "/github/repos/dlang/phobos/issues/4921/comments",
         "/github/repos/dlang/phobos/issues/comments/262784442",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.DELETE);
            res.writeVoidBody;
        }
    );

    postGitHubHook("dlang_phobos_synchronize_4921.json");
}

// send merge event
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/pulls/4963/commits",
        "/github/repos/dlang/phobos/issues/4963/comments"
    );

    postGitHubHook("dlang_phobos_merged_4963.json");
}

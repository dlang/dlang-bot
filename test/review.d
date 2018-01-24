import utils;

@("check-auto-merge-on-approval-positive")
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/issues/5114/labels",
        "/github/repos/dlang/phobos/commits/0fb66f092b897b55318509c6582008b3f912311a/status",
        "/github/repos/dlang/phobos/pulls/5114/commits",
        "/github/repos/dlang/phobos/issues/5114/events",
        "/github/users/ZombineDev",
        "/github/repos/dlang/phobos/pulls/5114/merge", (scope HTTPServerRequest req, scope HTTPServerResponse res) {
            assert(req.json["merge_method"] == "merge");
            assert(req.json["commit_message"] == "Fix tan returning -nan for inputs where abs(x) >= 2^63\n"~
                   "merged-on-behalf-of: ZombineDev <ZombineDev@users.noreply.github.com>");
        }
    );

    postGitHubHook("dlang_phobos_review_5114.json", "pull_request_review");
}

// review approved --> look if merge possible --> no auto-merge
@("check-auto-merge-on-approval-negative")
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/issues/5114/labels", (ref Json j) {
            j[0]["name"] = "foo-bar";
            j = j[0 .. 1];
        }
    );

    postGitHubHook("dlang_phobos_review_5114.json", "pull_request_review");
}

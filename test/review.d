import utils;

// review approved --> look if merge possible --> tryMerge
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/issues/5114/labels",
        "/github/repos/dlang/phobos/pulls/5114/commits",
        "/github/repos/dlang/phobos/issues/5114/events",
        "/github/users/ZombineDev",
        "/github/repos/dlang/phobos/pulls/5114/merge", (scope HTTPServerRequest req, scope HTTPServerResponse res) {
            assert(req.json["sha"] == "0fb66f092b897b55318509c6582008b3f912311a");
            assert(req.json["merge_method"] == "merge");
            assert(req.json["commit_message"] == "Fix tan returning -nan for inputs where abs(x) >= 2^63\n"~
                   "merged-on-behalf-of: ZombineDev <ZombineDev@users.noreply.github.com>");
            res.statusCode = 200;
        }
    );

    postGitHubHook("dlang_phobos_review_5114.json", "pull_request_review");
}

// review approved --> look if merge possible --> no auto-merge
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

import utils;

@("pending-ignored")
unittest
{
    setAPIExpectations();

    postGitHubHook("dlang_dmd_status_6324.json", "status");
}

@("failed-ignored")
unittest
{
    setAPIExpectations();

    postGitHubHook("dlang_dmd_status_6324.json", "status",
        (ref Json j, scope HTTPClientRequest req){
            j["state"] = "failed";
        }
    );
}

@("trigger-merge-check-on-success")
unittest
{
    prThrottler.reset;

    // success status triggers merge check for all open auto-merge PRs
    setAPIExpectations(
        "/github/repos/dlang/dmd/issues?state=open&labels=auto-merge", (ref Json j) {
            j = Json.emptyArray;
        },
        "/github/repos/dlang/dmd/issues?state=open&labels=auto-merge-squash", (ref Json j) {
            j = Json.emptyArray;
        }
    );

    postGitHubHook("dlang_dmd_status_6324.json", "status",
        (ref Json j, scope HTTPClientRequest req){
            j["state"] = "success";
        }
    );

    // not triggered again within throttle time
    setAPIExpectations();

    postGitHubHook("dlang_dmd_status_6324.json", "status",
        (ref Json j, scope HTTPClientRequest req){
            j["state"] = "success";
        }
    );
}

@("trigger-merge-check-and-merge-on-success")
unittest
{
    prThrottler.reset;

    setAPIExpectations(
        "/github/repos/dlang/dmd/issues?state=open&labels=auto-merge",
        // PR 6327 has the label "auto-merge"
        "/github/repos/dlang/dmd/issues?state=open&labels=auto-merge-squash", (ref Json j) {
            j = Json.emptyArray;
        },
        "/github/repos/dlang/dmd/pulls/6327",
        "/github/repos/dlang/dmd/commits/782fd3fdd4a9c23e1307b4b963b443ed60517dfe/status",
        "/github/repos/dlang/dmd/pulls/6327/commits",
        "/github/repos/dlang/dmd/issues/6327/events",
        "/github/repos/dlang/dmd/pulls/6327/merge",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.json["sha"] == "782fd3fdd4a9c23e1307b4b963b443ed60517dfe");
            assert(req.json["merge_method"] == "merge");
            assert(req.json["commit_message"] == "Fix issue 16977 - bad debug info for function default arguments\n\n"~
                   "Merged-on-behalf-of: unknown");
        }
    );

    postGitHubHook("dlang_dmd_status_6324.json", "status",
        (ref Json j, scope HTTPClientRequest req){
            j["state"] = "success";
        }
    );
}

@("trigger-merge-check-and-squash-on-success")
unittest
{
    prThrottler.reset;

    setAPIExpectations(
        "/github/repos/dlang/dmd/issues?state=open&labels=auto-merge", (ref Json j) {
            j = Json.emptyArray;
        },
        "/github/repos/dlang/dmd/issues?state=open&labels=auto-merge-squash",
        // PR 6328 has the label "auto-merge-squash"
        "/github/repos/dlang/dmd/pulls/6328",
        "/github/repos/dlang/dmd/commits/d6fc98058b637f9a558206847e6d7057ab9fb3de/status", (ref Json j) {
            j["state"] = "success"; // fake
        },
        "/github/repos/dlang/dmd/pulls/6328/commits",
        "/github/repos/dlang/dmd/issues/6328/events",
        "/github/users/MartinNowak",
        "/github/repos/dlang/dmd/pulls/6328/merge",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.json["sha"] == "d6fc98058b637f9a558206847e6d7057ab9fb3de");
            assert(req.json["merge_method"] == "squash");
            assert(req.json["commit_message"] == "taking address of local means it cannot be 'scope' later\n\n"~
                   "Merged-on-behalf-of: Martin Nowak <somemail@example.org>");
        }
    );

    postGitHubHook("dlang_dmd_status_6324.json", "status",
        (ref Json j, scope HTTPClientRequest req){
            j["state"] = "success";
        }
    );
}

@("trigger-merge-check-and-merge-and-squash-on-success")
unittest
{
    prThrottler.reset;

    setAPIExpectations(
        "/github/repos/dlang/dmd/issues?state=open&labels=auto-merge",
        // 6327 has "auto-merge"
        "/github/repos/dlang/dmd/issues?state=open&labels=auto-merge-squash",
        // 6328 has "auto-merge-squash"
        "/github/repos/dlang/dmd/pulls/6327",
        "/github/repos/dlang/dmd/commits/782fd3fdd4a9c23e1307b4b963b443ed60517dfe/status",
        "/github/repos/dlang/dmd/pulls/6327/commits",
        "/github/repos/dlang/dmd/issues/6327/events",
        "/github/repos/dlang/dmd/pulls/6327/merge",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.json["sha"] == "782fd3fdd4a9c23e1307b4b963b443ed60517dfe");
            assert(req.json["merge_method"] == "merge");
            assert(req.json["commit_message"] == "Fix issue 16977 - bad debug info for function default arguments\n\n"~
                   "Merged-on-behalf-of: unknown");
        },
        "/github/repos/dlang/dmd/pulls/6328",
        "/github/repos/dlang/dmd/commits/d6fc98058b637f9a558206847e6d7057ab9fb3de/status", (ref Json j) {
            j["state"] = "success"; // fake
        },
        "/github/repos/dlang/dmd/pulls/6328/commits",
        "/github/repos/dlang/dmd/issues/6328/events",
        "/github/users/MartinNowak",
        "/github/repos/dlang/dmd/pulls/6328/merge",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.json["sha"] == "d6fc98058b637f9a558206847e6d7057ab9fb3de");
            assert(req.json["merge_method"] == "squash");
            assert(req.json["commit_message"] == "taking address of local means it cannot be 'scope' later\n\n"~
                   "Merged-on-behalf-of: Martin Nowak <somemail@example.org>");
        }
    );

    postGitHubHook("dlang_dmd_status_6324.json", "status",
        (ref Json j, scope HTTPClientRequest req){
            j["state"] = "success";
        }
    );
}

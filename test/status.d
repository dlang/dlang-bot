import utils;

// send pending status event -> no action
unittest
{
    setAPIExpectations();

    postGitHubHook("dlang_dmd_status_6324.json", "status");
}

// send failed status event -> no action
unittest
{
    setAPIExpectations();

    postGitHubHook("dlang_dmd_status_6324.json", "status",
        (ref Json j, scope HTTPClientRequest req){
            j["state"] = "failed";
        }
    );
}

// send success status event -> tryMergeForAllOpenPrs -> no action (no auto-merge PR)
unittest
{
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
}

// send success status event within throttle time -> no action
unittest
{
    setAPIExpectations();

    postGitHubHook("dlang_dmd_status_6324.json", "status",
        (ref Json j, scope HTTPClientRequest req){
            j["state"] = "success";
        }
    );
}

// send success status event -> tryMergeForAllOpenPrs -> merge()
// PR 6237 has the label "auto-merge"
unittest
{
    lastFullPRCheck = SysTime.min;

    setAPIExpectations(
        "/github/repos/dlang/dmd/issues?state=open&labels=auto-merge",
        "/github/repos/dlang/dmd/issues?state=open&labels=auto-merge-squash", (ref Json j) {
            j = Json.emptyArray;
        },
        "/github/repos/dlang/dmd/pulls/6327/commits",
        "/github/repos/dlang/dmd/pulls/6327/merge",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.json["sha"] == "782fd3fdd4a9c23e1307b4b963b443ed60517dfe");
            assert(req.json["merge_method"] == "merge");
            res.statusCode = 200;
            res.writeVoidBody;
        }
    );

    postGitHubHook("dlang_dmd_status_6324.json", "status",
        (ref Json j, scope HTTPClientRequest req){
            j["state"] = "success";
        }
    );
}

// send success status event -> tryMergeForAllOpenPrs -> merge()
// PR 6237 has the label "auto-merge-squash"
unittest
{
    lastFullPRCheck = SysTime.min;

    setAPIExpectations(
        "/github/repos/dlang/dmd/issues?state=open&labels=auto-merge", (ref Json j) {
            j = Json.emptyArray;
        },
        "/github/repos/dlang/dmd/issues?state=open&labels=auto-merge-squash",
        "/github/repos/dlang/dmd/pulls/6328/commits",
        "/github/repos/dlang/dmd/pulls/6328/merge",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.json["sha"] == "d6fc98058b637f9a558206847e6d7057ab9fb3de");
            assert(req.json["merge_method"] == "squash");
            res.statusCode = 200;
            res.writeVoidBody;
        }
    );

    postGitHubHook("dlang_dmd_status_6324.json", "status",
        (ref Json j, scope HTTPClientRequest req){
            j["state"] = "success";
        }
    );
}

// send success status event -> tryMergeForAllOpenPrs -> merge()
// 6327 has "auto-merge"
// 6328 has "auto-merge-squash"
unittest
{
    lastFullPRCheck = SysTime.min;

    setAPIExpectations(
        "/github/repos/dlang/dmd/issues?state=open&labels=auto-merge",
        "/github/repos/dlang/dmd/issues?state=open&labels=auto-merge-squash",
        "/github/repos/dlang/dmd/pulls/6327/commits",
        "/github/repos/dlang/dmd/pulls/6327/merge",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.json["sha"] == "782fd3fdd4a9c23e1307b4b963b443ed60517dfe");
            assert(req.json["merge_method"] == "merge");
            res.statusCode = 200;
            res.writeVoidBody;
        },
        "/github/repos/dlang/dmd/pulls/6328/commits",
        "/github/repos/dlang/dmd/pulls/6328/merge",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.json["sha"] == "d6fc98058b637f9a558206847e6d7057ab9fb3de");
            assert(req.json["merge_method"] == "squash");
            res.statusCode = 200;
            res.writeVoidBody;
        }
    );

    postGitHubHook("dlang_dmd_status_6324.json", "status",
        (ref Json j, scope HTTPClientRequest req){
            j["state"] = "success";
        }
    );
}

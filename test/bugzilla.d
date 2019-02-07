import utils;

@("after-merge-close-issue-bugzilla")
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/pulls/4963/commits", (ref Json j) {
            j[0]["commit"]["message"] = "Fix Issue 17564";
         },
        "/github/repos/dlang/phobos/issues/4963/comments",
        "/github/repos/dlang/phobos/issues/4963/labels",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            res.writeJsonBody(Json.emptyArray);
        },
        "/github/repos/dlang/phobos/issues/4963/labels",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            res.writeVoidBody;
        },
        "/trello/1/search?query=name:%22Issue%2017564%22&"~trelloAuth,
        "/bugzilla/buglist.cgi?bug_id=17564&ctype=csv&columnlist=short_desc,bug_status,resolution,bug_severity,priority",
        "/bugzilla/jsonrpc.cgi?params=%7B%22Bugzilla_login%22%3A%22bugzilla%40test.org%22%2C%22resolution%22%3A%22FIXED%22%2C%22comment%22%3A%7B%22body%22%3A%22dlang%2Fphobos%20pull%20request%20%234963%20%5C%22%5BDEMO%20for%20DIP1005%5D%20Converted%20imports%20to%20selective%20imports%20in%20std.array%5C%22%20was%20merged%3A%5Cn%5Cnhttps%3A%2F%2Fgithub.com%2Fdlang%2Fphobos%2Fpull%2F4963%22%7D%2C%22Bugzilla_password%22%3A%22BUGZILLA_DUMMY_PW%22%2C%22status%22%3A%22RESOLVED%22%2C%22ids%22%3A%5B17564%5D%7D&method=Bug.update",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.GET);
            auto j = Json(["result": Json("Success.")]);
            res.writeJsonBody(j);
        },
    );

    postGitHubHook("dlang_phobos_merged_4963.json");
}

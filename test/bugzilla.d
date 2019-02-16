import std.string;

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
        "/bugzilla/jsonrpc.cgi",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.POST);
            assert(req.json["method"].get!string == "Bug.update");

            auto comment = req.json["params"][0]["comment"]["body"].get!string;
			enum expected = q"EOF
dlang/phobos pull request #4963 "[DEMO for DIP1005] Converted imports to selective imports in std.array" was merged into master:

https://github.com/dlang/phobos/pull/4963
EOF".chomp;
            assert(comment == expected, comment);

            auto j = Json(["error" : Json(null), "result" : Json.emptyObject]);
            res.writeJsonBody(j);
        },
    );

    postGitHubHook("dlang_phobos_merged_4963.json");
}

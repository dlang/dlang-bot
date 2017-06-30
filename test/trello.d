import utils;

import std.stdio, std.format : format;

// no existing dlang bot comment -> create comment
unittest
{
    setAPIExpectations(
        "/bugzilla/buglist.cgi?bug_id=16794&ctype=csv&columnlist=short_desc,bug_status,resolution,bug_severity,priority",
        "/trello/1/cards/583f517a333add7c28e0cec7/actions?filter=commentCard&"~trelloAuth,
        (ref Json j) { j = Json.emptyArray; },
        "/trello/1/cards/583f517a333add7c28e0cec7/actions/comments?"~trelloAuth,
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.POST);
            assert(req.json["text"] ==
`- [Issue 16794 - dmd not working on Ubuntu 16.10 because of default PIE linking](https://issues.dlang.org/show_bug.cgi?id=16794)
`);
        }
    );

    postTrelloHook("active_issue_16794.json");
}

// update existing dlang bot comment
unittest
{
    setAPIExpectations(
        "/bugzilla/buglist.cgi?bug_id=16794&ctype=csv&columnlist=short_desc,bug_status,resolution,bug_severity,priority",
        "/trello/1/cards/583f517a333add7c28e0cec7/actions?filter=commentCard&"~trelloAuth,
        (ref Json j) { j[0]["data"]["text"] = "- [Issue 16794 - bla bla](https://issues.dlang.org/show_bug.cgi?id=16794)\n"; },
        "/trello/1/cards/583f517a333add7c28e0cec7/actions/583f517b91413ef81f1f9d34/comments?"~trelloAuth,
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.PUT);
            assert(req.json["text"] ==
`- [Issue 16794 - dmd not working on Ubuntu 16.10 because of default PIE linking](https://issues.dlang.org/show_bug.cgi?id=16794)
`);
        }
    );

    postTrelloHook("active_issue_16794.json");
}

// no existing dlang bot comment -> create comment
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/dmd/pulls/6359/commits",
        "/github/repos/dlang/dmd/issues/6359/comments",
        "/bugzilla/buglist.cgi?bug_id=16794&ctype=csv&columnlist=short_desc,bug_status,resolution,bug_severity,priority",
        "/github/orgs/dlang/public_members?per_page=100",
        "/github/repos/dlang/dmd/issues/6359/comments",
        "/github/repos/dlang/dmd/issues/6359/labels",
        // action: add bug fix label
        "/github/repos/dlang/dmd/issues/6359/labels",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.POST);
            assert(req.json[0].get!string == "Bug fix");
        },
        "/trello/1/search?query=name:%22Issue%2016794%22&"~trelloAuth,
        "/trello/1/cards/583f517a333add7c28e0cec7/actions?filter=commentCard&"~trelloAuth,
        "/trello/1/cards/583f517a333add7c28e0cec7/actions/583f517b91413ef81f1f9d34/comments?"~trelloAuth,
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.PUT);
            assert(req.json["text"] ==
`- [Issue 16794 - dmd not working on Ubuntu 16.10 because of default PIE linking](https://issues.dlang.org/show_bug.cgi?id=16794)
- https://github.com/dlang/dmd/pull/6359
`);
        },
        "/trello/1/cards/583f517a333add7c28e0cec7?"~trelloAuth,
        "/trello/1/board/55586bf9fd02d8c66074321a/lists?"~trelloAuth,
        "/trello/1/cards/583f517a333add7c28e0cec7/idList?value=55586d9b810fb97f9459df7d&"~trelloAuth,
        "/trello/1/cards/583f517a333add7c28e0cec7/pos?value=bottom&"~trelloAuth,
    );

    postGitHubHook("dlang_dmd_open_6359.json");
}

// no existing dlang bot comment -> create comment
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/dmd/pulls/6359/commits",
        "/github/repos/dlang/dmd/issues/6359/comments",
        "/bugzilla/buglist.cgi?bug_id=16794&ctype=csv&columnlist=short_desc,bug_status,resolution,bug_severity,priority",
        "/github/orgs/dlang/public_members?per_page=100",
        "/github/repos/dlang/dmd/issues/6359/comments",
        "/github/repos/dlang/dmd/issues/6359/labels",
        // action: add bug fix label
        "/github/repos/dlang/dmd/issues/6359/labels",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.POST);
            assert(req.json[0].get!string == "Bug fix");
        },
        "/trello/1/search?query=name:%22Issue%2016794%22&"~trelloAuth,
        "/trello/1/cards/583f517a333add7c28e0cec7/actions?filter=commentCard&"~trelloAuth,
        (ref Json j) { j = Json.emptyArray; },
        "/trello/1/cards/583f517a333add7c28e0cec7/actions/comments?"~trelloAuth,
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.POST);
            assert(req.json["text"] == "- https://github.com/dlang/dmd/pull/6359\n");
        },
        "/trello/1/cards/583f517a333add7c28e0cec7?"~trelloAuth,
        (ref Json j) { j["idList"] = "55586d9b810fb97f9459df7d"; },
        "/trello/1/board/55586bf9fd02d8c66074321a/lists?"~trelloAuth,
    );

    postGitHubHook("dlang_dmd_open_6359.json");
}

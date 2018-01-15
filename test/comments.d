import utils;

import std.format : format;

@("update-comment")
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/pulls/4921/commits",
        "/github/repos/dlang/phobos/issues/4921/labels",
        "/github/repos/dlang/phobos/issues/4921/comments",
        "/github/orgs/dlang/public_members?per_page=100",
        "/bugzilla/buglist.cgi?bug_id=8573&ctype=csv&columnlist=short_desc,bug_status,resolution,bug_severity,priority",
        "/github/repos/dlang/phobos/issues/comments/262784442",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.PATCH);
            auto expectedComment =
`### Bugzilla references

Auto-close | Bugzilla | Description
--- | --- | ---
✗ | [8573](%s/show_bug.cgi?id=8573) | A simpler Phobos function that returns the index of the mix or max item
`.format(bugzillaURL);
            assert(req.json["body"].get!string.canFind(expectedComment));
        },
        "/trello/1/search?query=name:%22Issue%208573%22&"~trelloAuth,
    );

    postGitHubHook("dlang_phobos_synchronize_4921.json");
}

@("create-comment")
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/pulls/4921/commits",
        "/github/repos/dlang/phobos/issues/4921/labels",
        "/github/repos/dlang/phobos/issues/4921/comments", (ref Json j) {
            j = Json.emptyArray;
        },
        "/github/orgs/dlang/public_members?per_page=100",
        "/bugzilla/buglist.cgi?bug_id=8573&ctype=csv&columnlist=short_desc,bug_status,resolution,bug_severity,priority",
        // no bug fix label, since Issues are only referenced but not fixed according to commit messages
        "/github/repos/dlang/phobos/issues/4921/comments",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.POST);
            auto expectedComment =
`### Bugzilla references

Auto-close | Bugzilla | Description
--- | --- | ---
✗ | [8573](%s/show_bug.cgi?id=8573) | A simpler Phobos function that returns the index of the mix or max item
`.format(bugzillaURL);
            assert(req.json["body"].get!string.canFind(expectedComment));
            res.writeVoidBody;
        },
        "/trello/1/search?query=name:%22Issue%208573%22&"~trelloAuth,
    );

    postGitHubHook("dlang_phobos_synchronize_4921.json");
}

@("update-comment-without-issue-ref")
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/pulls/4921/commits", (ref Json j) {
            j = Json.emptyArray;
         },
        "/github/repos/dlang/phobos/issues/4921/labels", (ref Json j) {
            // ignore casing
            j[0]["name"] = "bug fix";
        },
         "/github/repos/dlang/phobos/issues/4921/comments",
        "/github/orgs/dlang/public_members?per_page=100",
         "/github/repos/dlang/phobos/issues/comments/262784442",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.PATCH);
            auto body_= req.json["body"].get!string;
            assert(body_.canFind("@andralex"));
            assert(!body_.canFind("Auto-close | Bugzilla"), "Shouldn't contain bug header");
            assert(!body_.canFind("/show_bug.cgi?id="), "Shouldn't contain a Bugzilla reference");
        }
    );

    postGitHubHook("dlang_phobos_synchronize_4921.json");
}

@("no-duplicate-comments")
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/pulls/4921/commits", (ref Json j) {
            j = Json.emptyArray;
         },
        "/github/repos/dlang/phobos/issues/4921/labels",
         "/github/repos/dlang/phobos/issues/4921/comments", (ref Json j) {
            // any arbitrary comment should be removed
            j[0]["body"] = "Foo bar";
         },
        "/github/orgs/dlang/public_members?per_page=100",
         "/github/repos/dlang/phobos/issues/comments/262784442",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.PATCH);
            auto body_= req.json["body"].get!string;
            assert(body_.canFind("@andralex"));
            assert(!body_.canFind("Auto-close | Bugzilla"), "Shouldn't contain bug header");
            assert(!body_.canFind("/show_bug.cgi?id="), "Shouldn't contain a Bugzilla reference");
        }
    );

    postGitHubHook("dlang_phobos_synchronize_4921.json");
}

@("add-enhancement-label")
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/pulls/4921/commits", (ref Json j) {
            j[0]["commit"]["message"] = "Fix Issue 8573";
        },
         "/github/repos/dlang/phobos/issues/4921/comments",
        "/bugzilla/buglist.cgi?bug_id=8573&ctype=csv&columnlist=short_desc,bug_status,resolution,bug_severity,priority",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            res.writeBody(
`bug_id,"short_desc","bug_status","resolution","bug_severity","priority"
8573,"A simpler Phobos function that returns the index of the mix or max item","NEW","---","enhancement","P2"`);
        },
        "/github/repos/dlang/phobos/issues/4921/labels",
        "/github/repos/dlang/phobos/issues/4921/labels", (ref Json j) {
            j = Json.emptyArray;
        },
        "/github/orgs/dlang/public_members?per_page=100",
        "/github/repos/dlang/phobos/issues/comments/262784442",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.PATCH);
            auto body_= req.json["body"].get!string;
            assert(body_.canFind("@andralex"));
        },
        "/github/repos/dlang/phobos/issues/4921/labels",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.json[].equal(["Enhancement"]));
        },
        "/trello/1/search?query=name:%22Issue%208573%22&"~trelloAuth,
    );

    postGitHubHook("dlang_phobos_synchronize_4921.json");
}

@("do-not-readd-labels-1-#97")
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/pulls/4921/commits", (ref Json j) {
            j[0]["commit"]["message"] = "Fix Issue 8573";
        },
         "/github/repos/dlang/phobos/issues/4921/comments",
        "/bugzilla/buglist.cgi?bug_id=8573&ctype=csv&columnlist=short_desc,bug_status,resolution,bug_severity,priority",
        "/github/repos/dlang/phobos/issues/4921/labels",
        "/github/repos/dlang/phobos/issues/4921/labels", (ref Json j) {
            j[0]["name"] = "Enhancement";
        },
        "/github/orgs/dlang/public_members?per_page=100",
        "/github/repos/dlang/phobos/issues/comments/262784442",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.PATCH);
            auto body_= req.json["body"].get!string;
            assert(body_.canFind("@andralex"));
        },
        "/trello/1/search?query=name:%22Issue%208573%22&"~trelloAuth,
    );

    postGitHubHook("dlang_phobos_synchronize_4921.json");
}

@("remove-auto-merge-on-sync")
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/pulls/4921/commits", (ref Json j) {
            j[0]["commit"]["message"] = "No message";
         },
        "/github/repos/dlang/phobos/issues/4921/labels", (ref Json j) {
            j[0]["name"] = "auto-merge";
        },
        "/github/repos/dlang/phobos/issues/4921/labels/auto-merge",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.DELETE);
        },
        "/github/repos/dlang/phobos/issues/4921/comments",
        "/github/orgs/dlang/public_members?per_page=100",
        "/github/repos/dlang/phobos/issues/comments/262784442",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.PATCH);
        }
    );

    postGitHubHook("dlang_phobos_synchronize_4921.json");
}

@("send-merge-event")
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/pulls/4963/commits",
        "/github/repos/dlang/phobos/issues/4963/comments",
    );

    postGitHubHook("dlang_phobos_merged_4963.json");
}

@("redirect-critical-fixes-to-stable")
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/pulls/4921/commits", (ref Json j) {
            j[0]["commit"]["message"] = "Fix Issue 8573";
        },
        "/github/repos/dlang/phobos/issues/4921/labels",
        "/github/repos/dlang/phobos/issues/4921/comments", (ref Json j) {
            j = Json.emptyArray;
        },
        "/bugzilla/buglist.cgi?bug_id=8573&ctype=csv&columnlist=short_desc,bug_status,resolution,bug_severity,priority",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            res.writeBody(
`bug_id,"short_desc","bug_status","resolution","bug_severity","priority"
8573,"A simpler Phobos function that returns the index of the mix or max item","NEW","---","regression","P2"`);
        },
        "/github/orgs/dlang/public_members?per_page=100",
        "/github/repos/dlang/phobos/issues/4921/labels",
        "/github/repos/dlang/phobos/issues/4921/labels",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            res.writeJsonBody(Json.emptyArray);
        },
        "/github/repos/dlang/phobos/issues/4921/comments",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.POST);
            auto expectedComment =
("### Bugzilla references

Auto-close | Bugzilla | Description
--- | --- | ---
✓ | [8573](%s/show_bug.cgi?id=8573) | A simpler Phobos function that returns the index of the mix or max item

### ⚠️⚠️⚠️ Warnings ⚠️⚠️⚠️

- Regression or critical bug fixes should always target the `stable` branch." ~
" Learn more about [rebasing to `stable`](https://wiki.dlang.org/Starting_as_a_Contributor#Stable_Branch) or" ~
" the [D release process](https://github.com/dlang/DIPs/blob/master/DIPs/archive/DIP75.md#branching-strategy).
").format(bugzillaURL);
            assert(req.json["body"].get!string.canFind(expectedComment));
            res.writeVoidBody;
        },
        "/trello/1/search?query=name:%22Issue%208573%22&"~trelloAuth,
    );

    postGitHubHook("dlang_phobos_synchronize_4921.json");
}

@("hello-world-for-contributors")
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/pulls/4921/commits", (ref Json j) {
            j = Json.emptyArray;
         },
        "/github/repos/dlang/phobos/issues/4921/labels",
        "/github/repos/dlang/phobos/issues/4921/comments",
        "/github/orgs/dlang/public_members?per_page=100",
        "/github/repos/dlang/phobos/issues/comments/262784442",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.PATCH);
            assert(req.json["body"].get!string.canFind("Thanks for your pull request, @andralex!"));
            // don't show the the default contributors advice
            assert(!req.json["body"].get!string.canFind("CONTRIBUTING"));
        },
    );

    postGitHubHook("dlang_phobos_synchronize_4921.json");
}

@("do-not-readd-labels-2-#112")
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/pulls/5519/commits",
        "/github/repos/dlang/phobos/issues/5519/labels",
        "/github/repos/dlang/phobos/issues/5519/labels/auto-merge",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.DELETE);
        },
        "/bugzilla/buglist.cgi?bug_id=17564&ctype=csv&columnlist=short_desc,bug_status,resolution,bug_severity,priority",
        "/github/repos/dlang/phobos/issues/5519/comments",
        "/github/orgs/dlang/public_members?per_page=100",
        "/github/repos/dlang/phobos/issues/comments/311653375",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.PATCH);
        },
        "/github/repos/dlang/phobos/issues/5519/labels",
        "/trello/1/search?query=name:%22Issue%2017564%22&"~trelloAuth,
    );

    postGitHubHook("dlang_phobos_synchronize_5519.json");
}

@("do-not-readd-labels-3-#112")
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/pulls/5519/commits",
        "/bugzilla/buglist.cgi?bug_id=17564&ctype=csv&columnlist=short_desc,bug_status,resolution,bug_severity,priority",
        "/github/repos/dlang/phobos/issues/5519/comments",
        "/github/orgs/dlang/public_members?per_page=100",
        "/github/repos/dlang/phobos/issues/comments/311653375",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.PATCH);
        },
        "/github/repos/dlang/phobos/issues/5519/labels",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.GET);
        },
        "/trello/1/search?query=name:%22Issue%2017564%22&"~trelloAuth,
    );

    postGitHubHook("dlang_phobos_edit_5519.json");
}

@("do-not-comment-closed-prs-#119")
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/pulls/4921/commits",
        "/github/repos/dlang/phobos/issues/4921/labels",
        "/github/repos/dlang/phobos/issues/4921/comments",
        "/bugzilla/buglist.cgi?bug_id=8573&ctype=csv&columnlist=short_desc,bug_status,resolution,bug_severity,priority",
        "/trello/1/search?query=name:%22Issue%208573%22&"~trelloAuth,
    );

    postGitHubHook("dlang_phobos_synchronize_4921.json", "pull_request", (ref Json j, scope req) {
        j["pull_request"]["state"] = "closed";
    });
}

@("redirect-only-fixes-to-stable-#138")
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/pulls/4921/commits", (ref Json j) {
            j[0]["commit"]["message"] = "Issue 8573";
        },
        "/github/repos/dlang/phobos/issues/4921/labels",
        "/github/repos/dlang/phobos/issues/4921/comments", (ref Json j) {
            j = Json.emptyArray;
        },
        "/bugzilla/buglist.cgi?bug_id=8573&ctype=csv&columnlist=short_desc,bug_status,resolution,bug_severity,priority",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            res.writeBody(
`bug_id,"short_desc","bug_status","resolution","bug_severity","priority"
8573,"A simpler Phobos function that returns the index of the mix or max item","NEW","---","regression","P2"`);
        },
        "/github/orgs/dlang/public_members?per_page=100",
        "/github/repos/dlang/phobos/issues/4921/comments",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.POST);
            assert(!req.json["body"].get!string.canFind("Regression or critical bug fixes"));
        },
        "/trello/1/search?query=name:%22Issue%208573%22&"~trelloAuth,
    );

    postGitHubHook("dlang_phobos_synchronize_4921.json");
}

@("redirect-only-closing-fixes-to-stable-#138")
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/pulls/4921/commits", (ref Json j) {
            j[0]["commit"]["message"] = "Fix Issue 8573";
        },
        "/github/repos/dlang/phobos/issues/4921/labels",
        "/github/repos/dlang/phobos/issues/4921/comments", (ref Json j) {
            j = Json.emptyArray;
        },
        "/bugzilla/buglist.cgi?bug_id=8573&ctype=csv&columnlist=short_desc,bug_status,resolution,bug_severity,priority",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            res.writeBody(
`bug_id,"short_desc","bug_status","resolution","bug_severity","priority"
8573,"A simpler Phobos function that returns the index of the mix or max item","CLOSED","---","regression","P2"`);
        },
        "/github/repos/dlang/phobos/issues/4921/labels",
        "/github/repos/dlang/phobos/issues/4921/labels",
        "/github/orgs/dlang/public_members?per_page=100",
        "/github/repos/dlang/phobos/issues/4921/comments",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.POST);
            assert(!req.json["body"].get!string.canFind("Regression or critical bug fixes"));
        },
        "/trello/1/search?query=name:%22Issue%208573%22&"~trelloAuth,
    );

    postGitHubHook("dlang_phobos_synchronize_4921.json");
}

@("remove-review-labels-on-push")
unittest
{
    import std.array : replace;
    foreach (label; ["needs work", "Needs work", "stalled"])
    {
        setAPIExpectations(
            "/github/repos/dlang/phobos/pulls/4921/commits", (ref Json j) {
                j = Json.emptyArray;
             },
            "/github/repos/dlang/phobos/issues/4921/labels", (ref Json j) {
                j[0]["name"] = label;
            },
            // encodeComponent is avoided on purpose
            "/github/repos/dlang/phobos/issues/4921/labels/" ~ label.replace(" ", "%20"),
            (scope HTTPServerRequest req, scope HTTPServerResponse res){
                assert(req.method == HTTPMethod.DELETE);
            },
             "/github/repos/dlang/phobos/issues/4921/comments",
            "/github/orgs/dlang/public_members?per_page=100",
             "/github/repos/dlang/phobos/issues/comments/262784442",
            (scope HTTPServerRequest req, scope HTTPServerResponse res){
                assert(req.method == HTTPMethod.PATCH);
                auto body_ = req.json["body"].get!string;
                assert(body_.canFind("@andralex"));
                assert(!body_.canFind("Auto-close | Bugzilla"), "Shouldn't contain bug header");
                assert(!body_.canFind("/show_bug.cgi?id="), "Shouldn't contain a Bugzilla reference");
            }
        );
        postGitHubHook("dlang_phobos_synchronize_4921.json");
    }
}

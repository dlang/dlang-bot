import utils;

import std.format : format;

// existing comment
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

Fix | Bugzilla | Description
--- | --- | ---
✗ | [8573](%s/show_bug.cgi?id=8573) | A simpler Phobos function that returns the index of the mix or max item
`.format(bugzillaURL);
            assert(req.json["body"].get!string.canFind(expectedComment));
        },
        "/trello/1/search?query=name:%22Issue%208573%22&"~trelloAuth,
    );

    postGitHubHook("dlang_phobos_synchronize_4921.json");
}

// no existing dlang bot comment -> create comment and add bug fix label
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

Fix | Bugzilla | Description
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

// existing dlang bot comment, but no commits that reference a issue
// -> update comment (without references to Bugzilla)
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
            auto body_= req.json["body"].get!string;
            assert(body_.canFind("@andralex"));
            assert(!body_.canFind("Fix | Bugzilla"), "Shouldn't contain bug header");
            assert(!body_.canFind("/show_bug.cgi?id="), "Shouldn't contain a Bugzilla reference");
        }
    );

    postGitHubHook("dlang_phobos_synchronize_4921.json");
}

// existing dlang bot comment, but no commits that reference a issue
// -> update comment (without references to Bugzilla)
// test that we don't create a duplicate comment
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
            assert(!body_.canFind("Fix | Bugzilla"), "Shouldn't contain bug header");
            assert(!body_.canFind("/show_bug.cgi?id="), "Shouldn't contain a Bugzilla reference");
        }
    );

    postGitHubHook("dlang_phobos_synchronize_4921.json");
}

// existing dlang bot comment + enhancement bugzilla labels
// -> test that we add an enhancement label (not bug fix)
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
        "/github/repos/dlang/phobos/issues/4921/labels",
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

// existing dlang bot comment + existing bugzilla labels
// -> test that we don't resend an enhancement label (#97)
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
        "/github/repos/dlang/phobos/issues/4921/labels",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            import std.stdio;
            writeln(req.json);
            assert(req.json[].length == 0);
        },
        "/trello/1/search?query=name:%22Issue%208573%22&"~trelloAuth,
    );

    postGitHubHook("dlang_phobos_synchronize_4921.json");
}

// existing dlang bot comment -> update comment
// auto-merge label -> remove (due to synchronization)
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
            res.statusCode = 200;
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

// send merge event
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/pulls/4963/commits",
        "/github/repos/dlang/phobos/issues/4963/comments",
        "/github/orgs/dlang/public_members?per_page=100",
    );

    postGitHubHook("dlang_phobos_merged_4963.json");
}

// critical bug fix (not in stable) -> show warning to target stable
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/pulls/4921/commits",
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
        // no bug fix label, since Issues are only referenced but not fixed according to commit messages
        "/github/repos/dlang/phobos/issues/4921/comments",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.POST);
            auto expectedComment =
"### Bugzilla references

Fix | Bugzilla | Description
--- | --- | ---
✗ | [8573](%s/show_bug.cgi?id=8573) | A simpler Phobos function that returns the index of the mix or max item

### ⚠️⚠️⚠️ Warnings ⚠️⚠️⚠️

- Regression or critical bug fixes should always target the `stable` branch. [Learn more](https://wiki.dlang.org/Starting_as_a_Contributor#Stable_Branch)
".format(bugzillaURL);
            assert(req.json["body"].get!string.canFind(expectedComment));
            res.writeVoidBody;
        },
        "/trello/1/search?query=name:%22Issue%208573%22&"~trelloAuth,
    );

    postGitHubHook("dlang_phobos_synchronize_4921.json");
}

// contributors should see a different hello world message
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

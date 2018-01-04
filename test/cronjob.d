import utils;

import std.format : format;
import std.stdio;

string[] repositories = ["dlang/phobos"];

void dontTestStalled(ref Json j)
{
    import std.datetime : Clock, days;
    j[$ - 1]["created_at"] = (Clock.currTime - 2.days).toISOExtString;
    j[$ - 1]["updated_at"] = (Clock.currTime - 2.days).toISOExtString;
}

// test the first items of the cron job
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/issues?state=open&sort=updated&direction=asc",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            res.headers["Link"] = `<https://api.github.com/repositories/1257084/issues?state=open&sort=updated&direction=asc&page=2>; rel="next", <https://api.github.com/repositories/1257084/issues?state=open&sort=updated&direction=asc&page=3>; rel="last"`;
        },
        "/github/repos/dlang/phobos/pulls/2526",
        "/github/repos/dlang/phobos/status/a04acd6a2813fb344d3e47369cf7fd64523ece44",
        "/github/repos/dlang/phobos/issues/2526/comments",
        "/github/repos/dlang/phobos/pulls/2526/comments",
        "/github/repos/dlang/phobos/issues/2526/labels",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.PUT);
            assert(req.json[].map!(e => e.get!string).equal(["blocked", "stalled"]));
        },
        "/github/repos/dlang/phobos/pulls/3534",
        "/github/repos/dlang/phobos/status/b7bf452ca52c2a529e79a830eee97310233e3a9c",
        "/github/repos/dlang/phobos/issues/3534/comments",
        "/github/repos/dlang/phobos/pulls/3534/comments",
        "/github/repos/dlang/phobos/issues/3534/labels",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.PUT);
            assert(req.json[].map!(e => e.get!string).equal(
                ["blocked", "needs rebase", "needs work", "stalled"]
            ));
        },
        "/github/repos/dlang/phobos/pulls/4551",
        "/github/repos/dlang/phobos/status/c4224ad203f5497569452ff05284124eb7030602",
        "/github/repos/dlang/phobos/issues/4551/comments",
        "/github/repos/dlang/phobos/pulls/4551/comments",
        "/github/repos/dlang/phobos/issues/4551/labels",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.PUT);
            assert(req.json[].map!(e => e.get!string).equal(
                ["blocked", "needs rebase", "needs work", "stalled"]
            ));
        },
        "/github/repos/dlang/phobos/pulls/3620",
        "/github/repos/dlang/phobos/status/5b8b90e1824cb90635719f6d3b1f6c195a95a47e",
        "/github/repos/dlang/phobos/issues/3620/comments",
        "/github/repos/dlang/phobos/pulls/3620/comments",
        "/github/repos/dlang/phobos/issues/3620/labels",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.PUT);
            assert(req.json[].map!(e => e.get!string).equal(
                ["Bug Fix", "decision block", "Enhancement", "needs rebase", "stalled"]
            ));
        },
    );
    testCronDaily(repositories);
}

// test that stalled isn't falsely removed (e.g. by recent labelling)
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/issues?state=open&sort=updated&direction=asc", (ref Json j) {
            // only test one pull request
            j = Json([j[0]]);
        },
        "/github/repos/dlang/phobos/pulls/2526", (ref Json j) {
            import std.datetime : Clock, days;
            // simulate a recent label update
            j["updated_at"] = (Clock.currTime - 2.days).toISOExtString;
        },
        "/github/repos/dlang/phobos/status/a04acd6a2813fb344d3e47369cf7fd64523ece44",
        "/github/repos/dlang/phobos/issues/2526/comments",
        "/github/repos/dlang/phobos/pulls/2526/comments",
        "/github/repos/dlang/phobos/issues/2526/labels",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.PUT);
            assert(req.json[].map!(e => e.get!string).equal(["blocked", "stalled"]));
        },
    );

    testCronDaily(repositories);
}

// test that no label updates are sent if no activity was found
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/issues?state=open&sort=updated&direction=asc", (ref Json j) {
            // only test one pull request
            j = Json([j[0]]);
        },
        "/github/repos/dlang/phobos/pulls/2526", (ref Json j) {
            j["mergeable"] = false;
        },
        "/github/repos/dlang/phobos/status/a04acd6a2813fb344d3e47369cf7fd64523ece44",
        "/github/repos/dlang/phobos/issues/2526/comments", &dontTestStalled,
        "/github/repos/dlang/phobos/pulls/2526/comments",
    );

    testCronDaily(repositories);
}

// test that the merge state gets refreshed
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/issues?state=open&sort=updated&direction=asc", (ref Json j) {
            // only test one pull request
            j = Json([j[0]]);
        },
        "/github/repos/dlang/phobos/pulls/2526", (ref Json j) {
            j["mergeable"] = null;
        },
        "/github/repos/dlang/phobos/pulls/2526", (ref Json j) {
            j["mergeable"] = false;
            j["mergeable_state"] = "dirty";
        },
        "/github/repos/dlang/phobos/status/a04acd6a2813fb344d3e47369cf7fd64523ece44",
        "/github/repos/dlang/phobos/issues/2526/comments", &dontTestStalled,
        "/github/repos/dlang/phobos/pulls/2526/comments",
        "/github/repos/dlang/phobos/issues/2526/labels",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.PUT);
            assert(req.json[].map!(e => e.get!string).equal(["blocked", "needs rebase"]));
        },
    );

    testCronDaily(repositories);
}

// for "blocked" PRs, the `mergeable` attribute should be preferred
// if mergeable is true, "needs rebase" should be removed
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/issues?state=open&sort=updated&direction=asc", (ref Json j) {
            // only test one pull request
            j = Json([j[0]]);
            j[0]["labels"][0]["name"] = "needs rebase";
        },
        "/github/repos/dlang/phobos/pulls/2526", (ref Json j) {
            j["mergeable"] = true;
            j["mergeable_state"] = "blocked";
        },
        "/github/repos/dlang/phobos/status/a04acd6a2813fb344d3e47369cf7fd64523ece44",
        "/github/repos/dlang/phobos/issues/2526/comments", &dontTestStalled,
        "/github/repos/dlang/phobos/pulls/2526/comments",
        "/github/repos/dlang/phobos/issues/2526/labels",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.PUT);
            assert(req.json[].length == 0);
        },
    );

    testCronDaily(repositories);
}

// test that two or more failing CI trigger "needs work"
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/issues?state=open&sort=updated&direction=asc", (ref Json j) {
            // only test one pull request
            j = Json([j[0]]);
        },
        "/github/repos/dlang/phobos/pulls/2526",
        "/github/repos/dlang/phobos/status/a04acd6a2813fb344d3e47369cf7fd64523ece44", (ref Json j) {
            j["statuses"][1]["state"] = "error";
            j["statuses"][2]["state"] = "failure";
        },
        "/github/repos/dlang/phobos/issues/2526/comments", &dontTestStalled,
        "/github/repos/dlang/phobos/pulls/2526/comments",
        "/github/repos/dlang/phobos/issues/2526/labels",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.PUT);
            assert(req.json[].map!(e => e.get!string).equal(["blocked", "needs work"]));
        },
    );

    testCronDaily(repositories);
}

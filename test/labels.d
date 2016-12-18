import app;
import utils;

import vibe.d;
import std.functional;
import std.stdio;

// send normal label event --> nothing
unittest
{
    auto expectedURLs = [
        "/github/repos/dlang/phobos/issues/4921/labels",
    ];

    "./payloads/github_hooks/dlang_phobos_label_4921.json".buildGitHubRequest(expectedURLs, (ref Json j, scope HTTPClientRequest req){
        j["pull_request"]["state"] = "open";
    }.toDelegate);
}


// send auto-merge label event, but closed PR --> nothing
unittest
{
    auto expectedURLs = [
        "/github/repos/dlang/phobos/pulls/4921/commits",
        "/github/repos/dlang/phobos/issues/4921/labels",
    ];

    jsonPostprocessor = (scope HTTPServerRequest req, Json j) {
        if (req.requestURL == "/github/repos/dlang/phobos/issues/4921/labels")
            j[0]["name"] = "auto-merge";

        return j;
    };

    "./payloads/github_hooks/dlang_phobos_label_4921.json".buildGitHubRequest(expectedURLs);
}

// send auto-merge label event --> try merge --> failure
unittest
{
    auto expectedURLs = [
        "/github/repos/dlang/phobos/pulls/4921/commits",
        "/github/repos/dlang/phobos/issues/4921/labels",
        "/github/repos/dlang/phobos/pulls/4921/merge",
    ];

    payloader = (scope HTTPServerRequest req, scope HTTPServerResponse res) {
        if (req.requestURL == "/github/repos/dlang/phobos/pulls/4921/merge")
        {
            // https://developer.github.com/v3/pulls/#response-if-merge-cannot-be-performed
            assert(req.json["sha"] == "d2c7d3761b73405ee39da3fd7fe5030dee35a39e");
            assert(req.json["merge_method"] == "merge");
            res.statusCode = 405;
            res.writeVoidBody;
            return DirectionTypes.STOP;
        }
        return DirectionTypes.CONTINUE;
    }.toDelegate();

    jsonPostprocessor = (scope HTTPServerRequest req, Json j) {
        if (req.requestURL == "/github/repos/dlang/phobos/issues/4921/labels")
            j[0]["name"] = "auto-merge";

        return j;
    };

    "./payloads/github_hooks/dlang_phobos_label_4921.json".buildGitHubRequest(expectedURLs, (ref Json j, scope HTTPClientRequest req){
        j["pull_request"]["state"] = "open";
    }.toDelegate);
}

// send auto-merge-squash label event --> try merge --> success
unittest
{
    auto expectedURLs = [
        "/github/repos/dlang/phobos/pulls/4921/commits",
        "/github/repos/dlang/phobos/issues/4921/labels",
        "/github/repos/dlang/phobos/pulls/4921/merge",
    ];

    payloader = (scope HTTPServerRequest req, scope HTTPServerResponse res) {
        if (req.requestURL == "/github/repos/dlang/phobos/pulls/4921/merge")
        {
            assert(req.json["sha"] == "d2c7d3761b73405ee39da3fd7fe5030dee35a39e");
            assert(req.json["merge_method"] == "squash");
            res.statusCode = 200;
            res.writeVoidBody;
            return DirectionTypes.STOP;
        }
        return DirectionTypes.CONTINUE;
    }.toDelegate();

    jsonPostprocessor = (scope HTTPServerRequest req, Json j) {
        if (req.requestURL == "/github/repos/dlang/phobos/issues/4921/labels")
            j[0]["name"] = "auto-merge-squash";

        return j;
    };

    "./payloads/github_hooks/dlang_phobos_label_4921.json".buildGitHubRequest(expectedURLs, (ref Json j, scope HTTPClientRequest req){
        j["pull_request"]["state"] = "open";
    }.toDelegate);
}

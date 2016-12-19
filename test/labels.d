import app;
import utils;

import vibe.d;
import std.functional;

// send normal label event --> nothing
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/issues/4921/labels",
    );

    postGitHubHook("dlang_phobos_label_4921.json", "pull_request",
        (ref Json j, scope HTTPClientRequest req){
            j["pull_request"]["state"] = "open";
    }.toDelegate);
}

// send auto-merge label event, but closed PR --> nothing
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/pulls/4921/commits",
        "/github/repos/dlang/phobos/issues/4921/labels", (ref Json j) {
            j[0]["name"] = "auto-merge";
        },
    );

    postGitHubHook("dlang_phobos_label_4921.json");
}

// send auto-merge label event --> try merge --> failure
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/pulls/4921/commits",
        "/github/repos/dlang/phobos/issues/4921/labels", (ref Json j) {
            j[0]["name"] = "auto-merge";
        },
        "/github/repos/dlang/phobos/pulls/4921/merge", (scope HTTPServerRequest req, scope HTTPServerResponse res) {
            // https://developer.github.com/v3/pulls/#response-if-merge-cannot-be-performed
            assert(req.json["sha"] == "d2c7d3761b73405ee39da3fd7fe5030dee35a39e");
            assert(req.json["merge_method"] == "merge");
            res.statusCode = 405;
            res.writeVoidBody;
        }
    );

    postGitHubHook("dlang_phobos_label_4921.json", "pull_request",
        (ref Json j, scope HTTPClientRequest req){
            j["pull_request"]["state"] = "open";
    }.toDelegate);
}

// send auto-merge-squash label event --> try merge --> success
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/pulls/4921/commits",
        "/github/repos/dlang/phobos/issues/4921/labels", (ref Json j) {
            j[0]["name"] = "auto-merge-squash";
        },
        "/github/repos/dlang/phobos/pulls/4921/merge",
        (scope HTTPServerRequest req, scope HTTPServerResponse res) {
            assert(req.json["sha"] == "d2c7d3761b73405ee39da3fd7fe5030dee35a39e");
            assert(req.json["merge_method"] == "squash");
            assert(req.json["commit_message"] ==
`Issue 8573 - A simpler Phobos function that returns the index of the mix or max item

Issue 8573 - A simpler Phobos function that returns the index of the mix or max item

added some review fixes

fixed an issue with a mutable variable

Applied review feedback

Renamed functions to minIndex and maxIndex + used sizediff_t for return value type

Updated function so that it works optimally even for lazy ranges and algorithms

Reverted to having only copyable elements in ranges

Added more unittests; implemented an array path; fixed documentation

Squashed commits (#4921)`);
            res.statusCode = 200;
            res.writeVoidBody;
        }
    );

    postGitHubHook("dlang_phobos_label_4921.json", "pull_request",
        (ref Json j, scope HTTPClientRequest req){
            j["pull_request"]["state"] = "open";
        }
    );
}

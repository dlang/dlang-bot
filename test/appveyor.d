import utils;

unittest
{
    setAPIExpectations(
        "/github/repos/dlang/dmd/pulls/6359/commits", (ref Json j) {
            j = Json.emptyArray;
        },
        "/github/repos/dlang/dmd/issues/6359/comments",
        "/github/orgs/dlang/public_members?per_page=100",
        "/github/repos/dlang/dmd/issues/6359/comments", // dlang-bot post
        "/github/repos/dlang/dmd/issues/6359/labels",
        "/appveyor/projects/greenify/dmd/history?recordsNumber=100", (ref Json j) {
            j["builds"][0]["status"] = "queued";
            j["builds"][1]["status"] = "queued";
            j["builds"][2]["status"] = "cancelled";
            j["builds"][0]["pullRequestId"] = "6359";
            j["builds"][1]["pullRequestId"] = "6359";
            j["builds"][2]["pullRequestId"] = "6359";
            j["builds"] = j["builds"][0..2];
        },
        "/appveyor/builds/greenify/dmd/13074433/cancel",
        HTTPStatus.noContent,
        (scope HTTPServerRequest req, scope HTTPServerResponse res) {
            assert(req.method == HTTPMethod.DELETE);
            res.writeVoidBody;
        },
    );

    runAppVeyor = true;
    scope(exit) runAppVeyor = false;
    postGitHubHook("dlang_phobos_synchronize_4921.json", "pull_request", (ref Json j, scope req){
        j["pull_request"]["number"] = 6359;
        j["pull_request"]["base"]["repo"]["name"] = "dmd";
        j["pull_request"]["base"]["repo"]["full_name"] = "dlang/dmd";
        j["pull_request"]["base"]["repo"]["owner"]["login"] = "dlang";
    });
}

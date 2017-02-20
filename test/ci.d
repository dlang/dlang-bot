import utils;

// manual test
unittest
{
    import std.typecons : Tuple;

    alias Entry = Tuple!(string, "repoSlug", int, "pr", string, "context", string, "url");

    auto urls = [
        Entry("dlang/phobos", 5151, "Project Tester", "https://ci.dawg.eu/job/phobos_trigger/343/"),
        Entry("dlang/phobos", 5131, "CyberShadow/DAutoTest", "http://dtest.dlang.io/results/86959530a962d84f01679c0aa45dd2c9714cc6ac/feb55b1f448c28dfb72ce409f8b1994f097dddb5/"),
        Entry("dlang/phobos", 5151, "auto-tester", "https://auto-tester.puremagic.com/pull-history.ghtml?projectid=1&repoid=3&pullid=5151"),
        Entry("dlang/phobos", 5151, "ci/circleci", "https://circleci.com/gh/dlang/phobos/1778?utm_campaign=vcs-integration-link&utm_medium=referral&utm_source=github-build-link"),
        Entry("dlang/phobos", -1, "codecov/patch ", "https://codecov.io/gh/dlang/phobos/compare/395ae88ac75ee0c03f6475ad4a5b073cfaf4e084...c652bce17d242c71875d99e379e37259101ea9fd"),
        Entry("dlang/phobos", -1, "codecov/project", "https://codecov.io/gh/dlang/phobos/compare/395ae88ac75ee0c03f6475ad4a5b073cfaf4e084...c652bce17d242c71875d99e379e37259101ea9fd"),
        Entry("dlang/dmd", 6552, "continuous-integration/travis-ci/pr", "https://travis-ci.org/dlang/dmd/builds/203056613"),
        Entry("dlang/dmd", 6553, "CyberShadow/DAutoTest", "http://dtest.dlang.io/results/86959530a962d84f01679c0aa45dd2c9714cc6ac/9f9369c96a0b8b8e4844c6d8d6f3fae9391a1450/"),
        Entry("dlang/dmd", 6552, "Project Tester", "https://ci.dawg.eu/job/dmd_trigger/974/"),
        Entry("dlang/dmd", 6552, "auto-tester", "https://auto-tester.puremagic.com/pull-history.ghtml?projectid=1&repoid=1&pullid=6552"),
        Entry("dlang/dmd", 6552, "ci/circleci", "https://circleci.com/gh/dlang/dmd/2827?utm_campaign=vcs-integration-link&utm_medium=referral&utm_source=github-build-link"),
    ];

    setAPIExpectations(
        "/projecttester/job/phobos_trigger/343/",
        "/dtest/results/86959530a962d84f01679c0aa45dd2c9714cc6ac/feb55b1f448c28dfb72ce409f8b1994f097dddb5/",
        "/circleci/project/github/dlang/phobos/1778",
        "/travis/repos/dlang/dmd/builds/203056613",
        "/dtest/results/86959530a962d84f01679c0aa45dd2c9714cc6ac/9f9369c96a0b8b8e4844c6d8d6f3fae9391a1450/",
        "/projecttester/job/dmd_trigger/974/",
        "/circleci/project/github/dlang/dmd/2827",
    );

    import dlangbot.ci : getPRForStatus;
    foreach (i, e; urls)
    {
        auto pr = getPRForStatus(e.repoSlug, e.url, e.context);
        if (e.pr >= 0)
            assert(pr == e.pr);
    }
}

// send hooks
unittest
{
    runPRReview = true;
    scope(exit) runPRReview = false;

    setAPIExpectations(
        "/github/repos/dlang/dmd/issues?state=open&labels=auto-merge", (ref Json j) {
            j = Json.emptyArray;
        },
        "/github/repos/dlang/dmd/issues?state=open&labels=auto-merge-squash", (ref Json j) {
            j = Json.emptyArray;
        },
        "/github/repos/dlang/dmd/status/eb53933e2d0989f6da3edf8581bb3de4acac9f0e",
        "/github/repos/dlang/dmd/pulls/6324/reviews",
        "/github/repos/dlang/dmd/issues/6324/labels",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            assert(req.method == HTTPMethod.POST);
            assert(req.json[].length == 1);
            assert(req.json[0] == "needs review");
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

module dlangbot.ci;

import dlangbot.github;

import vibe.core.log;
import vibe.http.client : HTTPClientRequest, requestHTTP;

import std.conv : to;
import std.format : format;
import std.regex : matchFirst, regex;
import std.exception;
import std.variant : Nullable;

// list of used APIs (overwritten by the test suite)
string dTestAPI = "http://dtest.dlang.io";
string circleCiAPI = "https://circleci.com/api/v1.1";
string projectTesterAPI = "https://ci.dawg.eu";

// only since 2.073
auto nullable(T)(T t) {  return Nullable!T(t); }

/**
There's no way to get the PR number from a GitHub status event (or other API
endpoints).
Hence we have to check the sender for this information.
*/
Nullable!uint getPRForStatus(string repoSlug, string url, string context)
{
    Nullable!uint prNumber;

    try {
        logDebug("getPRNumber (repo: %s, ci: %s)", repoSlug, context);
        switch (context) {
            case "auto-tester":
                prNumber = checkAutoTester(url);
                break;
            case "ci/circleci":
                prNumber = checkCircleCi(url);
                break;
            case "continuous-integration/travis-ci/pr":
                prNumber = checkTravisCi(url);
                break;
            case "CyberShadow/DAutoTest":
                prNumber = checkDTest(url);
                break;
            case "Project Tester":
                prNumber = checkProjectTester(url);
                break;
            // CodeCov provides no way atm
            default:
        }
    } catch (Exception e) {
        logDebug("PR number for: %s (by CI: %s) couldn't be detected", repoSlug, context);
        logDebug("Exception", e);
    }

    return prNumber;
}

class PRDetectionException : Exception
{
    this()
    {
        super("Failure to detected PR number");
    }
}

Nullable!uint checkCircleCi(string url)
{
    import std.algorithm.iteration : splitter;
    import std.array : array;
    import std.range : back, retro;

    // https://circleci.com/gh/dlang/dmd/2827?utm_campaign=v...
    static circleCiRe = regex(`circleci.com/gh/(.*)/([0-9]+)`);
    Nullable!uint pr;

    auto m = url.matchFirst(circleCiRe);
    enforce(!m.empty);

    string repoSlug = m[1];
    ulong buildNumber = m[2].to!ulong;

    auto resp = requestHTTP("%s/project/github/%s/%d"
                .format(circleCiAPI, repoSlug, buildNumber)).readJson;
    if (auto prs = resp["pull_requests"][])
    {
        pr = prs[0]["url"].get!string
                            .splitter("/")
                            .array // TODO: splitter is not bidirectional
                                   //  https://issues.dlang.org/show_bug.cgi?id=17047
                            .back.to!uint;
    }
    // branch in upstream
    return pr;
}


Nullable!uint checkTravisCi(string url)
{
    import dlangbot.travis : getPRNumber;

    // https://travis-ci.org/dlang/dmd/builds/203056613
    static travisCiRe = regex(`travis-ci.org/(.*)/builds/([0-9]+)`);
    Nullable!uint pr;

    auto m = url.matchFirst(travisCiRe);
    enforce(!m.empty);

    string repoSlug = m[1];
    ulong buildNumber = m[2].to!ulong;

    return getPRNumber(repoSlug, buildNumber);
}

// tests PRs only
auto checkAutoTester(string url)
{
    // https://auto-tester.puremagic.com/pull-history.ghtml?projectid=1&repoid=1&pullid=6552
    static autoTesterRe = regex(`pullid=([0-9]+)`);

    auto m = url.matchFirst(autoTesterRe);
    enforce(!m.empty);
    return m[1].to!uint.nullable;
}

// tests PRs only
auto checkDTest(string url)
{
    import vibe.stream.operations : readAllUTF8;

    // http://dtest.dlang.io/results/f3f364ddcf96e98d1a6566b04b130c3f8b37a25f/378ec2f7616ec7ca4554c5381b45561473b0c218/
    static dTestRe = regex(`results/([0-9a-f]+)/([0-9a-f]+)`);
    static dTestReText = regex(`<tr>.*Pull request.*<a href=".*\/pull\/([0-9]+)"`);

    // to enable testing: don't use link directly
    auto shas = url.matchFirst(dTestRe);
    enforce(!shas.empty);
    string headSha = shas[1]; // = PR
    string baseSha= shas[2];  // e.g upstream/master

    auto m = requestHTTP("%s/results/%s/%s/".format(dTestAPI, headSha, baseSha))
            .bodyReader
            .readAllUTF8
            .matchFirst(dTestReText);

    enforce(!m.empty);
    return m[1].to!uint.nullable;
}

// tests PRs only ?
Nullable!uint checkProjectTester(string url)
{
    import vibe.stream.operations : readAllUTF8;
    import vibe.inet.url : URL;

    // 1: repoSlug, 2: pr
    static projectTesterReText = `href="https:\/\/github[.]com\/(.*)\/pull\/([0-9]+)`;

    auto uri = URL(url);

    auto m = requestHTTP("%s%s".format(projectTesterAPI, uri.path))
            .bodyReader
            .readAllUTF8
            .matchFirst(projectTesterReText);

    enforce(!m.empty, "Project tester detection failed");
    return m[2].to!uint.nullable;
}

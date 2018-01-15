module dlangbot.appveyor;

string appveyorAPIURL = "https://ci.appveyor.com/api";
string appveyorAuth;

import vibe.core.log;

//==============================================================================
// Dedup AppVeyor builds
//==============================================================================

// https://www.appveyor.com/docs/api/projects-builds/#cancel-build
void cancelBuild(string repoSlug, size_t buildId)
{
    import std.format : format;
    import vibe.http.common : HTTPMethod;
    import vibe.stream.operations : readAllUTF8;
    import dlangbot.utils : request;

    auto url = "%s/builds/%s/%s/cancel".format(appveyorAPIURL, repoSlug, buildId);
    request(url, (scope req) {
        req.headers["Authorization"] = appveyorAuth;
        req.method = HTTPMethod.DELETE;
    }, (scope res) {
        if (res.statusCode / 100 == 2)
            logInfo("[appveyor/%s]: Canceled Build %s\n", repoSlug, buildId);
        else
            logError("[appveyor/%s]: POST %s failed;  %s %s.\n%s", repoSlug, url, res.statusPhrase,
                res.statusCode, res.bodyReader.readAllUTF8);
    });
}

// https://www.appveyor.com/docs/api/projects-builds/#get-project-history
void dedupAppVeyorBuilds(string action, string repoSlug, uint pullRequestNumber)
{
    import std.algorithm.iteration : filter;
    import std.conv : to;
    import std.format : format;
    import std.range : drop;
    import vibe.data.json : Json;
    import dlangbot.utils : request;

    if (action != "synchronize" && action != "merged")
        return;

    static bool activeState(string state)
    {
        import std.algorithm.comparison : among;
        return state.among("created", "queued", "started") > 0;
    }
    // GET /api/projects/{accountName}/{projectSlug}/history?recordsNumber={records-per-page}[&startBuildId={buildId}&branch={branch}]

    auto url = "%s/projects/%s/history?recordsNumber=100".format(appveyorAPIURL, repoSlug);
    auto activeBuildsForPR = request(url, (scope req) {
            req.headers["Authorization"] = appveyorAuth;
        })
        .readJson["builds"][]
        .filter!(b => "pullRequestId" in b && !b["pullRequestId"].type != Json.undefined)
        .filter!(b => activeState(b["status"].get!string))
        .filter!(b => b["pullRequestId"].get!string.to!uint == pullRequestNumber);

    // Keep only the most recent build for this PR.  Kill all builds
    // when it got merged as it'll be retested after the merge anyhow.
    foreach (b; activeBuildsForPR.drop(action == "merged" ? 0 : 1))
        cancelBuild(repoSlug, b["buildId"].get!size_t);
}


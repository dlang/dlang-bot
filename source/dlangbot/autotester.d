module dlangbot.autotester;

string ghAutoTesterLogin, ghAutoTesterPassword;

/**
Sends an auto-merge command to the auto-tester.
This is an experimental method that depends on scraping the API.
Moreover it's only supported for dlang/{dmd,druntime,phobos}
*/
void setAutoMerge(string repoSlug, ulong pullId)
{
    import requests : queryParams, Request, Response;
    import std.conv : to;
    import std.exception : enforce;
    import std.format : format;
    import std.regex : matchFirst, regex;
    import vibe.core.log : logDebug;

    // temporarily not tested
    version(unittest){} else
    try {

    Request rq = Request();
    Response rs;

    int repoId;
    switch (repoSlug) {
        case "dlang/dmd":
            repoId = 1; break;
        case "dlang/druntime":
            repoId = 2; break;
        case "dlang/phobos":
            repoId = 3; break;
        default:
            logDebug("repoSlug: %s isn't supported by the auto-tester", repoSlug);
            return;
    }

    logDebug("auto-tester: starting request (slug=%s,pull=%d)", repoSlug, pullId);

    // login to github
    {
        auto re = regex(`name="authenticity_token".*value="(.*)"`);
        string url = "https://github.com/login/oauth/authorize?scope=public_repo&response_type=code&client_id=efb9cf46977efe7abd51&state=index.ghtml|";
        rs = rq.get(url);

        auto githubCsrfToken = rs.responseBody.to!string.matchFirst(re);
        enforce(!githubCsrfToken.empty, "Couldn't find CSFR token");
        rs = rq.post("https://github.com/session", queryParams(
            "authenticity_token", githubCsrfToken[1],
            "login", ghAutoTesterLogin,
            "password", ghAutoTesterPassword,
            "commit", "Sign in"
        ));
        enforce(rs.code == 200);
    }

    logDebug("auto-tester: logged into github (slug=%s,pull=%d)", repoSlug, pullId);

    string autoMergeAPI;
    // request CSFR from auto-tester
    {
        auto url = "https://auto-tester.puremagic.com/pull-history.ghtml?projectid=1&repoid=%d&pullid=%d"
                   .format(repoId, pullId);
        rs = rq.get(url);
        enforce(rs.code == 200);

        auto autoTesterRe = regex(`<td>(.*) – <a href="(addv2\/toggle_auto_merge.*)">Toggle<\/a><\/td>`);
        auto autoTesterStatus = rs.responseBody.to!string.matchFirst(autoTesterRe);
        enforce(!autoTesterStatus.empty, "Couldn't find CSFR token");

        // skip if already toggled
        if (autoTesterStatus[1] == "Yes")
            return;

        autoMergeAPI = "https://auto-tester.puremagic.com/" ~ autoTesterStatus[2];
    }

    logDebug("auto-tester: sending auto-merge (slug=%s,pull=%d)", repoSlug, pullId);
    rq.get(autoMergeAPI);

    } catch(Exception e) {
        logDebug("auto-tester: failed to sending auto-merge (slug=%s,pull=%d): %s", repoSlug, pullId, e.msg);
    }
}

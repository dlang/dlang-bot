module dlangbot.codecov;

import dlangbot.github_api;

import std.datetime : SysTime;
import std.typecons : Nullable;

import vibe.core.log;
import vibe.data.json;

// codecov sends strings for numbers
struct CodeCovHook
{
    static struct CodeCovCompare
    {
        string message, url, notation;
        string coverage; // TODO: convert
    }
    CodeCovCompare compare;

    struct CodeCovRepo
    {
        @name("commitid") string sha;
        string branch;
    }
    struct CodeCovPull
    {
        string title;
        string id; // TODO: convert
        string state;
        string number; // TODO: convert
        CodeCovRepo head;
        CodeCovRepo base;
    }
    @optional Nullable!CodeCovPull pull;

    struct CodeCovTotals
    {
        @name("c") string coverage; // TODO: convert
        /*
        TODO: quite cryptic.
         "p":0,
         "s":1,
         "diff":null,
         "m":4254,
         "b":0,
         "C":0,
         "d":0,
         "n":17400,
         "f":136,
         "h":13146,
         "c":"75.55172",
         "M":0,
         "N":0
        */
    }

    struct CodeCovFullRepo
    {
        string message;
        uint version_;
        string branch;
        @name("parent") string parentSha;
        @optional @name("pullid") Nullable!string pullId; // TODO: convert
        string state;

        // CodeCov doesn't send ISO strings
        //SysTime timestamp;
        //@optional Nullable!SysTime updatestamp;

        @name("ci_passed") bool passed;
        @optional @name("service_url") Nullable!string serviceURL;
        // CodeCov sends booleans as strings
        //@optional Nullable!bool notified;
        //@optional Nullable!bool archived;
        //@optional Nullable!bool deleted;

        CodeCovTotals totals;
        @name("parent_totals") CodeCovTotals parentTotals;

        // Not needed: author, logs
    }

    CodeCovFullRepo base;
    CodeCovFullRepo head;

    string repoSlug()
    {
        return owner.name ~ "/" ~ repo.name;
    }

    static struct CodeCovOwner
    {
        import vibe.data.json : Name = name;
        @Name("username") string name;
    }
    CodeCovOwner owner;

    static struct CodeCovRepoInfo
    {
        string name;
    }
    CodeCovRepoInfo repo;
}

void handleCodecovPR(CodeCovHook* _hook)
{
    auto hook = *_hook;
    import std.stdio;
    import std.format : format;
    if (hook.pull.isNull)
        return;

    logDebug("[codecov/handleStatus](%s): sha=%s", hook.repoSlug, hook.pull.head.sha);
    GHStatuses status = {
        state: GHStatuses.State.success,
        targetURL: hook.compare.url,
        description: "Total coverage: %s (%s)".format(hook.compare.message, hook.compare.coverage),
        context: "dlangbot/codecov",
    };
    logDebug("[codecov/handleStatus](%s): status=%s", status);
    ghSendRequest((scope req){
        req.writeJsonBody(status);
    }, githubAPIURL ~ "/repos/%s/statuses/%s".format(hook.repoSlug, hook.pull.head.sha));
}

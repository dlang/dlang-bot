module dlangbot.buildkite;

import std.datetime.systime;

import vibe.data.json;
import vibe.data.json : Name = name;
import vibe.http.client : HTTPClientRequest;
import vibe.http.common : enforceHTTP, HTTPStatus;

import dlangbot.utils : request;
static import scw=dlangbot.scaleway_api;

string buildkiteAPIURL = "https://api.buildkite.com/v2";
string buildkiteAuth, buildkiteHookSecret;

string dlangbotAgentAuth;

//==============================================================================
// Buildkite hooks and Dlang-bot API
//==============================================================================

Json verifyRequest(string secret, string body_)
{
    import std.digest : secureEqual;
    import std.exception : enforce;

    enforceHTTP(secureEqual(secret, buildkiteHookSecret), HTTPStatus.unauthorized, "hook secret mismatch");
    return parseJsonString(body_);
}

void verifyAgentRequest(string authentication)
{
    import std.digest : secureEqual;
    enforceHTTP(secureEqual(authentication, dlangbotAgentAuth), HTTPStatus.unauthorized);
}

void handleBuild(in ref Build build, in ref Pipeline p)
{
    if (p.name == "build-release")
        scaleReleaseBuilder(p.scheduledBuildsCount + p.runningBuildsCount);
}

void agentShutdownCheck(string hostname)
{
    import std.algorithm : startsWith;

    if (hostname.startsWith("release-builder"))
    {
        immutable p = pipeline("build-release");
        scaleReleaseBuilder(p.scheduledBuildsCount + p.runningBuildsCount, hostname);
    }
}

private void scaleReleaseBuilder(uint nbuilds, string serverToDecommision = null)
{
    import std.algorithm : filter, find, startsWith;
    import std.array : front;
    import std.range : empty, walkLength;
    import std.uuid : randomUUID;
    import vibe.core.log : logWarn;

    assert(serverToDecommision == null || serverToDecommision.startsWith("release-builder-"));

    auto servers = scw.servers;
    immutable nservers = servers.filter!(s => s.name.startsWith("release-builder-")).walkLength;

    if (nservers < nbuilds)
    {
        immutable img = scw.images.find!(i => i.name == "release-builder").front;
        foreach (_; nservers .. nbuilds)
            scw.createServer("release-builder-" ~ randomUUID().toString, "C2S", img).action(scw.Server.Action.poweron);
    }
    else if (nbuilds < nservers && serverToDecommision != null)
    {
        servers = servers.find!(s => s.name == serverToDecommision);
        if (servers.empty)
            logWarn("Failed to find server to decommission %s", serverToDecommision);
        else
            servers.front.action(scw.Server.Action.terminate);
    }
}

//==============================================================================
// Buildkite API
//==============================================================================

struct Pipeline
{
    string name;
    @Name("scheduled_builds_count") uint scheduledBuildsCount;
    @Name("running_builds_count") uint runningBuildsCount;
}

struct Build
{
    enum State { scheduled, passed, failed, cancelled }
    @byName State state;
    string branch, commit;
    @Name("meta_data") string[string] metadata;
}

struct Agent
{
    string id, name, hostname;
    @Name("created_at") SysTime createdAt;
    @Name("last_job_finished_at") SysTime lastJobFinishedAt;
}

Pipeline pipeline(string name)
{
    import vibe.textfilter.urlencode : urlEncode;

    return bkGET("/organizations/dlang/pipelines/" ~ urlEncode(name))
        .readJson
        .deserializeJson!(Pipeline);
}

Pipeline[] pipelines()
{
    return bkGET("/organizations/dlang/pipelines")
        .readJson
        .deserializeJson!(Pipeline[]);
}

Agent[] agents()
{
    return bkGET("/organizations/dlang/agents")
        .readJson
        .deserializeJson!(Agent[]);
}

auto bkGET(string path)
{
    return request(buildkiteAPIURL ~ path, (scope req) {
        req.headers["Authorization"] = buildkiteAuth;
    });
}

auto bkGET(scope void delegate(scope HTTPClientRequest req) userReq, string path)
{
    return request(buildkiteAPIURL ~ path, (scope req) {
        req.headers["Authorization"] = buildkiteAuth;
        userReq(req);
    });
}

/// returns number of release builders
/*size_t decommissionDefunctReleaseBuilders()
{
    auto servers = scw.servers().filter!(s => s.hostname.startsWith("release-builder-"));
    auto agents = agents().filter!(a => a.hostname.startsWith("release-builder-"));
    auto stale = servers.filter!(s =>
        s.state == s.State.running &&
        s.creationDate > Clock.currTime - 10.minutes &&
        !agents.canFind!(a => a.hostname == s.hostname));
    stale.each!(s => s.decommision);
    // count servers not agents to account for booting ones (and undetected hanging servers)
    return servers.walkLength - stale.walkLength;
}*/

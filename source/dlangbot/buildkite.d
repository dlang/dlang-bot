module dlangbot.buildkite;

import std.algorithm : filter, find, startsWith;
import std.datetime.systime;
import std.range : empty, front, walkLength;
import std.uuid : randomUUID;

import vibe.core.log : logDebug, logInfo, logWarn;
import vibe.data.json : Name = name;
import vibe.data.json;
import vibe.http.client : HTTPClientRequest;
import vibe.http.common : enforceHTTP, HTTPStatus;

import dlangbot.utils : request;
static import scw=dlangbot.scaleway_api;
static import hc=dlangbot.hcloud_api;

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
        provisionReleaseBuilder(numReleaseBuilds);
    else
        provisionCIAgent(numCIBuilds);
}

void agentShutdownCheck(string hostname)
{
    import std.algorithm : startsWith;

    if (hostname.startsWith("release-builder-"))
        decommissionReleaseBuilder(numReleaseBuilds, hostname);
    else if (hostname.startsWith("ci-agent-"))
        decommissionCIAgent(numCIBuilds, hostname);
}

private void provisionReleaseBuilder(uint nbuilds)
{
    auto servers = scw.servers;
    immutable nservers = servers.filter!(s => s.name.startsWith("release-builder-")).walkLength;

    logInfo("check provision release-builder nservers: %s, nbuilds: %s", nservers, nbuilds);
    if (nservers >= nbuilds)
        return;

    immutable img = scw.images.find!(i => i.name == "release-builder").front;
    foreach (_; nservers .. nbuilds)
        scw.createServer("release-builder-" ~ randomUUID().toString, "C2S", img).action(scw.Server.Action.poweron);
}

private void decommissionReleaseBuilder(uint nbuilds, string hostname)
{
    assert(hostname.startsWith("release-builder-"));

    auto servers = scw.servers;
    immutable nservers = servers.filter!(s => s.name.startsWith("release-builder-")).walkLength;

    if (nbuilds >= nservers)
        return;

    servers = servers.find!(s => s.name == hostname);
    if (servers.empty)
        logWarn("Failed to find server to decommission %s", hostname);
    else
        servers.front.decommission();
}

private void provisionCIAgent(uint nbuilds)
{
    auto servers = hc.servers;
    immutable nservers = servers.filter!(s => s.name.startsWith("ci-agent-")).walkLength;

    logInfo("check provision ci-agent nservers: %s, nbuilds: %s", nservers, nbuilds);
    if (nservers >= nbuilds)
        return;

    immutable img = hc.images(hc.Image.Type.snapshot).find!(i => i.description == "ci-agent").front;
    foreach (_; nservers .. nbuilds)
        hc.createServer("ci-agent-" ~ randomUUID().toString, "cx41", img);
}

private void decommissionCIAgent(uint nbuilds, string hostname)
{
    assert(hostname.startsWith("ci-agent-"));

    auto servers = hc.servers;
    immutable nservers = servers.filter!(s => s.name.startsWith("ci-agent-")).walkLength;

    if (nbuilds >= nservers)
        return;

    servers = servers.find!(s => s.name == hostname);
    if (servers.empty)
        logWarn("Failed to find server to decommission %s", hostname);
    else
        servers.front.decommission();
}

private uint numReleaseBuilds()
{
    auto p = pipeline("build-release");
    return p.scheduledBuildsCount + p.runningBuildsCount;
}

/// estimate number of scheduled compute-hours
private uint numCIBuilds()
{
    import core.time : Duration, hours, minutes, seconds;
    import std.algorithm : clamp, filter, fold, map, max, mean, sum;
    import std.conv : to;
    import std.datetime.timezone : UTC;
    import std.math : ceil;

    immutable now = Clock.currTime(UTC());
    auto workload = Duration.zero;

    foreach (p; pipelines.filter!(p => p.defaultQueue))
    {
        if (!p.scheduledBuildsCount && !p.runningBuildsCount)
            continue;

        auto builds = p.builds(Build.State.passed, 10);
        immutable avgTime = builds.map!(b => b.finishedAt - b.startedAt).mean(Duration.zero);

        if (avgTime <= Duration.zero) // assume 1 hour per build
        {
            logWarn("avgTime for %s is unknown", p.name);
            workload += (p.scheduledBuildsCount + p.runningBuildsCount).hours;
            continue;
        }
        logDebug("avgTime for %s is %s", p.name, avgTime);

        workload += p.scheduledBuildsCount * avgTime;
        if (p.runningBuildsCount)
        {
            builds = p.builds(Build.State.running);
            workload += builds.map!(b => clamp(avgTime - (now - b.startedAt), 1.seconds, avgTime)).sum(Duration.zero);
        }
    }
    // round up to number of compute-hours to match hourly billing
    immutable workloadHours = (workload.total!"seconds" / 3600.0).ceil.to!uint;
    logInfo("scheduled ci workload ≅ %s, rounded to %s hours", workload, workloadHours);
    return workloadHours;
}

//==============================================================================
// Buildkite API
//==============================================================================

struct Pipeline
{
    string name;
    @Name("scheduled_builds_count") uint scheduledBuildsCount;
    @Name("running_builds_count") uint runningBuildsCount;

    /// returns whether pipeline runs (partially) on default queue
    bool defaultQueue()
    {
        import std.algorithm : any, all, startsWith;

        return steps.length > 0 &&
            steps.any!(s => s.agentQueryRules.all!(a => a == "queue=default" || !a.startsWith("queue=")));
    }

    static struct Step
    {
        @Name("agent_query_rules") string[] agentQueryRules;
    }
    Step[] steps;

    Build[] builds(Build.State state, uint perPage=100, uint page=1)
    {
        import std.string : format;

        return bkGET("/organizations/dlang/pipelines/%s/builds?state=%s&per_page=%s&page=%s".format(
                name, state, perPage, page))
            .readJson
            .deserializeJson!(typeof(return));
    }
}

struct Build
{
    enum State { running, scheduled, passed, failed, blocked, canceled, canceling, skipped, not_run, finished }
    @byName State state;
    @optional @Name("started_at") SysTime startedAt;
    @optional @Name("finished_at") SysTime finishedAt;
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

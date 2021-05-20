module dlangbot.buildkite;

import core.time : Duration, hours, minutes, seconds;
import std.algorithm : canFind, filter, find, startsWith;
import std.datetime.systime : Clock, SysTime;
import std.datetime.timezone : UTC;
import std.exception : enforce;
import std.range : empty, front, walkLength;
import std.typecons : Tuple;
import std.uuid : randomUUID;

import vibe.core.log : logDebug, logInfo, logWarn;
import vibe.data.json : Name = name;
import vibe.data.json;
import vibe.http.client : HTTPClientRequest;
import vibe.http.common : enforceHTTP, HTTPStatus, HTTPMethod;

import dlangbot.utils : request, expectOK;
static import hc=dlangbot.hcloud_api;

shared string buildkiteAPIURL = "https://graphql.buildkite.com/v1";
shared string buildkiteAuth, buildkiteHookSecret;

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

void handleBuild(string pipeline)
{
    auto info = queryState(pipeline == "build-release" ? pipeline : null);
    try
        info = reapDeadServers(info);
    catch (Exception e)
        logWarn("reapDeadServers failed %s", e);
    provisionCIAgent(numCIBuilds(info.pipelines), info.hcServers);
}

void agentShutdownCheck(string hostname)
{
    import std.algorithm : startsWith;

    auto info = queryState(hostname.startsWith("release-builder-") ? "build-release" : null);
    try
        info = reapDeadServers(info);
    catch (Exception e)
        logWarn("reapDeadServers failed %s", e);
    if (hostname.startsWith("ci-agent-"))
        decommissionCIAgent(numCIBuilds(info.pipelines), info.hcServers, hostname);
}

Info reapDeadServers(Info info, Duration bootTimeout = 10.minutes)
{
    import std.algorithm : each, fold, map, partition, remove, sort;
    import std.array : array;

    auto runningAgentHosts = info.agents.edges.sort!((a, b) => a.hostname < b.hostname).groupBy
        .map!(agents => agents.fold!((hn, a) => a.connectionState == "connected" ? a.hostname : hn)(cast(string) null))
        .filter!(hn => !hn.empty).array;
    immutable now = Clock.currTime(UTC());
    auto deadHCServers = info.hcServers
        .partition!(s => runningAgentHosts.canFind(s.name) || s.created > now - bootTimeout);
    if (deadHCServers.length)
    {
        logInfo("found dead servers hcloud: %s", deadHCServers.length);
        deadHCServers.each!(s => s.decommission);
    }
    info.hcServers.length -= deadHCServers.length;
    return info;
}

// for use as cron-job
void cronReapDeadServers() nothrow @trusted
{
    logDebug("cronReapDeadServers");
    try
        reapDeadServers(queryState());
    catch (Exception e)
        logWarn("cronReapDeadServers failed %s", e);
}

struct Info
{
    Organization organization;
    alias organization this;
    hc.Server[] hcServers;
}

Info queryState(string pipelineSearch=null)
{
    import std.algorithm : map, remove, each;
    import std.array : array;
    import vibe.core.core : runTask;

    typeof(return) ret;
    [
        { ret.organization = organization(pipelineSearch); },
        { ret.hcServers = hc.servers.remove!(s => !s.name.startsWith("ci-agent-")); },
    ].map!runTask.array.each!(task => task.join);
    return ret;
}

private void provisionCIAgent(uint nbuilds, hc.Server[] servers)
{
    immutable nservers = servers.length;
    logInfo("check provision ci-agent nservers: %s, nbuilds: %s", nservers, nbuilds);
    if (nservers >= nbuilds)
        return;

    immutable img = hc.images(hc.Image.Type.snapshot).find!(i => i.description == "ci-agent").front;
    foreach (_; nservers .. nbuilds)
        hc.createServer("ci-agent-" ~ randomUUID().toString, "cx41", img);
}

private void decommissionCIAgent(uint nbuilds, hc.Server[] servers, string hostname)
{
    assert(hostname.startsWith("ci-agent-"));

    if (nbuilds >= servers.length)
        return;

    servers = servers.find!(s => s.name == hostname);
    if (servers.empty)
        logWarn("Failed to find server to decommission %s", hostname);
    else
        servers.front.decommission();
}

private uint numReleaseBuilds(Node!Pipeline[] pipelines)
{
    pipelines = pipelines.find!(p => p.name == "build-release");
    auto p = pipelines.empty ? Pipeline.init : pipelines.front;
    return cast(uint)(p.scheduledBuilds.length + p.runningBuilds.length);
}

/// estimate number of scheduled compute-hours
private uint numCIBuilds(Node!Pipeline[] pipelines)
{
    import std.algorithm : clamp, filter, fold, map, max, mean, sum;
    import std.conv : to;
    import std.math : ceil;

    immutable now = Clock.currTime(UTC());
    auto workload = Duration.zero;

    foreach (p; pipelines.filter!(p => p.defaultQueue))
    {
        if (!p.scheduledBuilds.length && !p.runningBuilds.length)
            continue;

        immutable avgTime = p.passedBuilds.map!(b => b.finishedAt - b.startedAt).mean(Duration.zero);
        if (avgTime <= Duration.zero) // assume 1 hour per build
        {
            logWarn("avgTime for %s is unknown", p.name);
            workload += (p.scheduledBuilds.length && p.runningBuilds.length).hours;
            continue;
        }
        logDebug("avgTime for %s is %s", p.name, avgTime);

        workload += p.scheduledBuilds.length * avgTime;
        if (p.runningBuilds.length)
            workload += p.runningBuilds.map!(b => clamp(avgTime - (now - b.startedAt), 1.seconds, avgTime)).sum(Duration.zero);
    }

    // round up to number of compute-hours to match hourly billing
    immutable workloadHours = (workload.total!"seconds" / 3600.0).ceil.to!uint;
    logInfo("scheduled ci workload ≅ %s, rounded to %s hours", workload, workloadHours);
    return workloadHours;
}

//==============================================================================
// Buildkite API
//==============================================================================

// dummy wrappers to flatten graphql pagination
struct Node(T)
{
    T node;
    alias node this;
}
struct Edges(T)
{
    Node!T[] edges;
    alias edges this;
}

struct Pipeline
{
    static struct Steps { string yaml; }
    string name;
    Steps steps;
    Edges!Build passedBuilds, scheduledBuilds, runningBuilds;

    /// returns whether pipeline runs (partially) on default queue
    bool defaultQueue() const
    {
        return !steps.yaml.canFind("queue=");
    }
}

struct Build
{
    @optional SysTime startedAt;
    @optional SysTime finishedAt;
}

struct Agent
{
    string id, name, hostname;
    // connected, stopping, stopped, ... (e.g. lost or so)
    string connectionState;
}

struct Organization
{
    Edges!Pipeline pipelines;
    Edges!Agent agents;
}

Organization organization(string pipelineSearch=null)
{
    auto resp = bkQuery(organizationQuery, ["pipelineSearch": pipelineSearch])
        .readJson;
    enforce("errors" !in resp, "Error in GraphQL query\n"~resp["errors"].toString);
    return resp["data"]["organization"]
        .deserializeJson!Organization;
}

private auto bkQuery(string query, string[string] variables = null)
{
    return request(buildkiteAPIURL, (scope req) {
        req.headers["Authorization"] = buildkiteAuth;
        req.method = HTTPMethod.POST;
        req.writeJsonBody(["query": Json(query), "variables": variables.serializeToJson]);
    }).expectOK;
}

//==============================================================================
// Buildkite GraphQL queries
//==============================================================================

enum organizationQuery = q"GQL
query($pipelineSearch:String) {
  organization(slug: dlang) {
    pipelines(first: 100, search: $pipelineSearch) {
      edges {
        node {
          name
          steps {
            yaml
          }
          passedBuilds: builds(first: 10, state: PASSED) {
            edges {
              node {
                startedAt
                finishedAt
              }
            }
          }
          runningBuilds: builds(first: 100, state: RUNNING) {
            edges {
              node {
                startedAt
              }
            }
          }
          scheduledBuilds: builds(first: 100, state: SCHEDULED) {
            edges {
              node {
                branch
              }
            }
          }
        }
      }
    }
    agents(first: 100) {
      edges {
        node {
          id
          name
          hostname
          connectionState
        }
      }
    }
  }
}
GQL";

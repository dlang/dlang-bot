module dlangbot.buildkite;

import std.algorithm : canFind, filter, find, startsWith;
import std.datetime.systime;
import std.exception : enforce;
import std.range : empty, front, walkLength;
import std.uuid : randomUUID;

import vibe.core.log : logDebug, logInfo, logWarn;
import vibe.data.json : Name = name;
import vibe.data.json;
import vibe.http.client : HTTPClientRequest;
import vibe.http.common : enforceHTTP, HTTPStatus, HTTPMethod;

import dlangbot.utils : request;
static import scw=dlangbot.scaleway_api;
static import hc=dlangbot.hcloud_api;

string buildkiteAPIURL = "https://graphql.buildkite.com/v1";
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

void handleBuild(string pipeline)
{
    if (pipeline == "build-release")
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
    immutable nservers = servers.filter!(s => s.healthy && s.name.startsWith("release-builder-")).walkLength;

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
    immutable nservers = servers.filter!(s => s.healthy && s.name.startsWith("ci-agent-")).walkLength;

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
    return cast(uint)(p.scheduledBuilds.length + p.runningBuilds.length);
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

struct Organization
{
    Edges!Pipeline pipelines;
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

Pipeline pipeline(string name)
{
    auto resp = bkQuery(pipelineQuery, ["pipeline": "dlang/"~name])
        .readJson;
    enforce("errors" !in resp, "Error in GraphQL query\n"~resp["errors"].toString);
    return resp["data"]["pipeline"]
        .deserializeJson!Pipeline;
}

Node!Pipeline[] pipelines()
{
    auto resp = bkQuery(pipelinesQuery)
        .readJson;
    enforce("errors" !in resp, "Error in GraphQL query\n"~resp["errors"].toString);
    return resp["data"]["organization"]
        .deserializeJson!Organization
        .pipelines;
}

auto bkQuery(string query, string[string] variables = null)
{
    return request(buildkiteAPIURL, (scope req) {
        req.headers["Authorization"] = buildkiteAuth;
        req.method = HTTPMethod.POST;
        req.writeJsonBody(["query": Json(query), "variables": variables.serializeToJson]);
    });
}

//==============================================================================
// Buildkite GraphQL queries
//==============================================================================

enum pipelineQuery = q"GQL
query($pipeline:ID!) {
  pipeline(slug: $pipeline) {
    ...pipelineFields
  }
}
GQL"~pipelineFragment;

enum pipelinesQuery = q"GQL
query {
  organization(slug: dlang) {
    pipelines(first: 100) {
      edges {
        node {
          ...pipelineFields
        }
      }
    }
  }
}
GQL"~pipelineFragment;

enum pipelineFragment = q"GQL
fragment pipelineFields on Pipeline {
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
GQL";

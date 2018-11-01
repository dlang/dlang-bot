module dlangbot.buildkite;

import std.datetime.systime;

import vibe.data.json;
import vibe.data.json : Name = name;
import vibe.http.client : HTTPClientRequest;

import dlangbot.utils : request;
static import scw=dlangbot.scaleway_api;

string buildkiteAPIURL = "https://api.buildkite.com/v2";
string buildkiteAuth, buildkiteHookSecret;

Json verifyRequest(string secret, string body_)
{
    import std.digest : secureEqual;
    import std.exception : enforce;

    enforce(secureEqual(secret, buildkiteHookSecret), "hook secret mismatch");
    return parseJsonString(body_);
}

void handleBuild(in ref Build build, in ref Pipeline pipeline)
{
    if (pipeline.name == "build-release")
        scaleReleaseBuilders(pipeline.scheduledBuildsCount + pipeline.runningBuildsCount);
}

struct Pipeline
{
    string url;
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

private:

void scaleReleaseBuilders(uint needed)
{
    import std.algorithm : filter, find, startsWith;
    import std.array : front;
    import std.range : walkLength;
    import std.uuid : randomUUID;

    immutable cnt = scw.servers.filter!(s => s.name.startsWith("release-builder-")).walkLength;
    if (cnt >= needed)
        return;
    immutable img = scw.images.find!(i => i.name == "release-builder").front;
    foreach (_; cnt .. needed)
        scw.createServer("release-builder-" ~ randomUUID().toString, "C2S", img).action("poweron");
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

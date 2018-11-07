import utils;

import core.time : minutes;

//==============================================================================
// buildkite hook
//==============================================================================

@("answers-ping")
unittest
{
    setAPIExpectations();

    postBuildkiteHook("ping.json");
}

//==============================================================================
// Release-Builders on Scaleway (Bare Metal)
//==============================================================================

@("spawns-release-builder")
unittest
{
    setAPIExpectations(
        "/buildkite", &graphQL!("buildkite_pipeline", (ref Json j) {
            j["data"]["pipeline"]["scheduledBuilds"]["edges"] ~=
                ["node": ["branch": "master"]].serializeToJson;
        }),
        "/scaleway/servers", (ref Json j) {
            j["servers"] = Json.emptyArray;
        },
        "/scaleway/images",
        "/scaleway/servers",
        (scope HTTPServerRequest req, scope HTTPServerResponse res) {
            assert(req.method == HTTPMethod.POST);
            assert(req.json["name"].get!string.startsWith("release-builder-"));
            auto name = req.json["name"].get!string;
            assert(req.json["image"] == "487de557-88fe-4029-a404-831c19744ebd");
            assert(req.json["organization"] == "aa435976-67f1-455c-b988-f4dc04c91f40");
            res.writeJsonBody(["server": ["id": "a4919456-92a2-4cab-b503-ca13aa14c786", "name": name, "state": "stopped"]]);
        },
        "/scaleway/servers/a4919456-92a2-4cab-b503-ca13aa14c786/action",
        (scope HTTPServerRequest req, scope HTTPServerResponse res) {
            assert(req.method == HTTPMethod.POST);
            assert(req.json["action"] == "poweron");
            res.writeBody("");
        }
    );

    postBuildkiteHook("build_scheduled_build-release.json");
}

@("reuse-running-release-builder")
unittest
{
    setAPIExpectations(
        "/buildkite", &graphQL!("buildkite_pipeline", (ref Json j) {
            j["data"]["pipeline"]["scheduledBuilds"]["edges"] ~=
                ["node": ["branch": "master"]].serializeToJson;
        }),
        "/scaleway/servers",
    );

    postBuildkiteHook("build_scheduled_build-release.json");
}

@("spawns-additional-release-builders")
unittest
{
    setAPIExpectations(
        "/buildkite", &graphQL!("buildkite_pipeline", (ref Json j) {
            j["data"]["pipeline"]["scheduledBuilds"]["edges"] ~=
                ["node": ["branch": "master"]].serializeToJson;
            j["data"]["pipeline"]["runningBuilds"]["edges"] ~=
                ["node": ["startedAt": (now - 30.minutes).toISOExtString]].serializeToJson;
        }),
        "/scaleway/servers",
        "/scaleway/images",
        "/scaleway/servers",
        (scope HTTPServerRequest req, scope HTTPServerResponse res) {
            assert(req.method == HTTPMethod.POST);
            assert(req.json["name"].get!string.startsWith("release-builder-"));
            auto name = req.json["name"].get!string;
            assert(req.json["image"] == "487de557-88fe-4029-a404-831c19744ebd");
            assert(req.json["organization"] == "aa435976-67f1-455c-b988-f4dc04c91f40");
            res.writeJsonBody(["server": ["id": "c9660dc8-cdd9-426c-99c8-1155a568d53e", "name": name, "state": "stopped"]]);
        },
        "/scaleway/servers/c9660dc8-cdd9-426c-99c8-1155a568d53e/action",
        (scope HTTPServerRequest req, scope HTTPServerResponse res) {
            assert(req.method == HTTPMethod.POST);
            assert(req.json["action"] == "poweron");
            res.writeBody("");
        }
    );

    postBuildkiteHook("build_scheduled_build-release.json");
}

//==============================================================================
// CI-Agents on Hetzner Cloud
//==============================================================================

Json hcloudCreateServerResp(ulong id, string name)
{
    import core.time : Duration;
    import std.datetime.timezone : SimpleTimeZone;
    import std.file : readText;
    import vibe.data.json : parseJsonString;

    // use zulu to get +00:00 instead of Z suffix
    static zulu = new immutable SimpleTimeZone(Duration.zero, "Etc/Zulu");
    auto time = now(zulu).toISOExtString;

    auto json = "data/payloads/hcloud_servers_post".readText.parseJsonString;
    json["server"]["id"] = id;
    json["server"]["name"] = name;
    json["server"]["created"] = time;
    json["action"]["started"] = time;
    return json;
}

// gets pipeline from buildkite GraphQL query for all pipelines
Json findPipeline(Json j, string name)
{
    return j["data"]["organization"]["pipelines"]["edges"][]
        .find!(p => p["node"]["name"] == name)[0]["node"];
}

@("spawns-ci-agent")
unittest
{
    setAPIExpectations(
        "/buildkite", &graphQL!("buildkite_pipelines", (ref Json j) {
            j.findPipeline("dmd")["scheduledBuilds"]["edges"] ~=
                ["node": ["branch": "master"]].serializeToJson;
        }),
        "/hcloud/servers", (ref Json j) {
            j["servers"] = Json.emptyArray;
        },
        "/hcloud/images?sort=created:desc&type=snapshot",
        "/hcloud/servers",
        (scope HTTPServerRequest req, scope HTTPServerResponse res) {
            assert(req.method == HTTPMethod.POST);
            auto name = req.json["name"].get!string;
            assert(name.startsWith("ci-agent-"));
            assert(req.json["image"] == "1461991");
            res.writeJsonBody(hcloudCreateServerResp(1321993, name));
        },
    );

    postBuildkiteHook("build_scheduled_dmd.json");
}

@("reuse-running-ci-agents")
unittest
{
    setAPIExpectations(
        "/buildkite", &graphQL!("buildkite_pipelines", (ref Json j) {
            j.findPipeline("dmd")["scheduledBuilds"]["edges"] ~=
                ["node": ["branch": "master"]].serializeToJson;
        }),
        "/hcloud/servers",
    );

    postBuildkiteHook("build_scheduled_dmd.json");
}

@("spawns-additional-ci-agents")
unittest
{
    setAPIExpectations(
        "/buildkite", &graphQL!("buildkite_pipelines", (ref Json j) {
            j.findPipeline("dmd")["scheduledBuilds"]["edges"] ~=
                ["node": ["branch": "master"]].serializeToJson;
            j.findPipeline("dmd")["scheduledBuilds"]["edges"] ~=
                ["node": ["branch": "master"]].serializeToJson;
            j.findPipeline("phobos")["scheduledBuilds"]["edges"] ~=
                ["node": ["branch": "MartinNowak:fix19337"]].serializeToJson;
        }),
        "/hcloud/servers",
        "/hcloud/images?sort=created:desc&type=snapshot",
        "/hcloud/servers",
        (scope HTTPServerRequest req, scope HTTPServerResponse res) {
            assert(req.method == HTTPMethod.POST);
            auto name = req.json["name"].get!string;
            assert(name.startsWith("ci-agent-"));
            assert(req.json["image"] == "1461991");
            res.writeJsonBody(hcloudCreateServerResp(1321994, name));
        },
    );

    postBuildkiteHook("build_scheduled_dmd.json");
}

@("reuses-existing-agent-from-running-builds")
unittest
{
    import std.datetime.systime : Clock;
    import std.datetime.timezone : UTC;

    setAPIExpectations(
        "/buildkite", &graphQL!("buildkite_pipelines", (ref Json j) {
            j.findPipeline("dmd")["runningBuilds"]["edges"] ~=
                ["node": ["startedAt": (now - 15.minutes).toISOExtString]].serializeToJson;
            j.findPipeline("dmd")["runningBuilds"]["edges"] ~=
                ["node": ["startedAt": (now - 5.minutes).toISOExtString]].serializeToJson;
            j.findPipeline("phobos")["scheduledBuilds"]["edges"] ~=
                ["node": ["branch": "master"]].serializeToJson;
        }),
        "/hcloud/servers",
    );

    postBuildkiteHook("build_scheduled_dmd.json");
}

//==============================================================================
// agent shutdown check
//==============================================================================

@("terminates-unneeded-release-builders")
unittest
{
    setAPIExpectations(
        "/buildkite", &graphQL!"buildkite_pipeline",
        "/scaleway/servers", (ref Json j) {
            j["servers"][0]["name"] = "release-builder-123456";
            j["servers"][0]["id"] = "a4919456-92a2-4cab-b503-ca13aa14c786";
        },
        "/scaleway/servers/a4919456-92a2-4cab-b503-ca13aa14c786/action",
        (scope HTTPServerRequest req, scope HTTPServerResponse res) {
            assert(req.method == HTTPMethod.POST);
            assert(req.json["action"] == "terminate");
            res.writeBody("");
        }
    );

    postAgentShutdownCheck("release-builder-123456");
}

@("terminates-unneeded-ci-agents")
unittest
{
    setAPIExpectations(
        "/buildkite", &graphQL!"buildkite_pipelines",
        "/hcloud/servers", (ref Json j) {
            j["servers"][0]["name"] = "ci-agent-123456";
            j["servers"][0]["id"] = 1321993;
        },
        "/hcloud/servers/1321993",
        (scope HTTPServerRequest req, scope HTTPServerResponse res) {
            assert(req.method == HTTPMethod.DELETE);
            res.writeBody("");
        }
    );

    postAgentShutdownCheck("ci-agent-123456");
}

@("keeps-needed-release-builders")
unittest
{
    setAPIExpectations(
        "/buildkite", &graphQL!("buildkite_pipeline", (ref Json j) {
            j["data"]["pipeline"]["runningBuilds"]["edges"] ~=
                ["node": ["startedAt": (now - 30.minutes).toISOExtString]].serializeToJson;
        }),
        "/scaleway/servers",
    );

    postAgentShutdownCheck("release-builder-123456");
}

@("keeps-needed-release-ci-agents")
unittest
{
    setAPIExpectations(
        "/buildkite", &graphQL!("buildkite_pipelines", (ref Json j) {
            j.findPipeline("dmd")["scheduledBuilds"]["edges"] ~=
                ["node": ["branch": "master"]].serializeToJson;
        }),
        "/hcloud/servers",
    );

    postAgentShutdownCheck("ci-agent-123456");
}

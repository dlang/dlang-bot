import utils;

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
        "/buildkite/organizations/dlang/pipelines/build-release", (ref Json j) {
            j["scheduled_builds_count"] = 1;
        },
        "/scaleway/servers", (ref Json j) {
            j["servers"] = Json.emptyArray;
        },
        "/scaleway/images",
        "/scaleway/servers",
        (scope HTTPServerRequest req, scope HTTPServerResponse res) {
            assert(req.method == HTTPMethod.POST);
            assert(req.json["name"].get!string.startsWith("release-builder-"));
            auto name = req.json["name"].get!string;
            assert(req.json["image"] == "5e2333ca-278b-40cb-8a50-22ed6a659063");
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
        "/buildkite/organizations/dlang/pipelines/build-release", (ref Json j) {
            j["scheduled_builds_count"] = 1;
        },
        "/scaleway/servers",
    );

    postBuildkiteHook("build_scheduled_build-release.json");
}

@("spawns-additional-release-builders")
unittest
{
    setAPIExpectations(
        "/buildkite/organizations/dlang/pipelines/build-release", (ref Json j) {
            j["scheduled_builds_count"] = 2;
        },
        "/scaleway/servers",
        "/scaleway/images",
        "/scaleway/servers",
        (scope HTTPServerRequest req, scope HTTPServerResponse res) {
            assert(req.method == HTTPMethod.POST);
            assert(req.json["name"].get!string.startsWith("release-builder-"));
            auto name = req.json["name"].get!string;
            assert(req.json["image"] == "5e2333ca-278b-40cb-8a50-22ed6a659063");
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

@("spawns-ci-agent")
unittest
{
    setAPIExpectations(
        "/buildkite/organizations/dlang/pipelines", (ref Json j) {
            j[].find!(p => p["name"] == "dmd")[0]["scheduled_builds_count"] = 1;
        },
        "/hcloud/servers", (ref Json j) {
            j["servers"] = Json.emptyArray;
        },
        "/hcloud/images?type=snapshot",
        "/hcloud/servers",
        (scope HTTPServerRequest req, scope HTTPServerResponse res) {
            assert(req.method == HTTPMethod.POST);
            auto name = req.json["name"].get!string;
            assert(name.startsWith("ci-agent-"));
            assert(req.json["image"] == "1456126");
            auto resp = serializeToJson(["name": name, "status": "initializing"]);
            resp["id"] = 1321993;
            res.writeJsonBody(resp);
        },
    );

    postBuildkiteHook("build_scheduled_dmd.json");
}

@("reuse-running-ci-agents")
unittest
{
    setAPIExpectations(
        "/buildkite/organizations/dlang/pipelines", (ref Json j) {
            j[].find!(p => p["name"] == "dmd")[0]["scheduled_builds_count"] = 1;
        },
        "/hcloud/servers",
    );

    postBuildkiteHook("build_scheduled_dmd.json");
}

@("spawns-additional-ci-agents")
unittest
{
    setAPIExpectations(
        "/buildkite/organizations/dlang/pipelines", (ref Json j) {
            j[].find!(p => p["name"] == "dmd")[0]["scheduled_builds_count"] = 2;
        },
        "/hcloud/servers",
        "/hcloud/images?type=snapshot",
        "/hcloud/servers",
        (scope HTTPServerRequest req, scope HTTPServerResponse res) {
            assert(req.method == HTTPMethod.POST);
            auto name = req.json["name"].get!string;
            assert(name.startsWith("ci-agent-"));
            assert(req.json["image"] == "1456126");
            auto resp = serializeToJson(["name": name, "status": "initializing"]);
            resp["id"] = 1321994;
            res.writeJsonBody(resp);
        },
    );

    postBuildkiteHook("build_scheduled_dmd.json");
}

@("reuses-existing-agent-from-current-build")
unittest
{
    setAPIExpectations(
        "/buildkite/organizations/dlang/pipelines", (ref Json j) {
            j[].find!(p => p["name"] == "dmd")[0]["running_builds_count"] = 2;
            j[].find!(p => p["name"] == "dmd")[0]["scheduled_builds_count"] = 1;
        },
        "/hcloud/servers",
        "/hcloud/images?type=snapshot",
        "/hcloud/servers",
        (scope HTTPServerRequest req, scope HTTPServerResponse res) {
            assert(req.method == HTTPMethod.POST);
            auto name = req.json["name"].get!string;
            assert(name.startsWith("ci-agent-"));
            assert(req.json["image"] == "1456126");
            auto resp = serializeToJson(["name": name, "status": "initializing"]);
            resp["id"] = 1321994;
            res.writeJsonBody(resp);
        },
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
        "/buildkite/organizations/dlang/pipelines/build-release",
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
        "/buildkite/organizations/dlang/pipelines",
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
        "/buildkite/organizations/dlang/pipelines/build-release", (ref Json j) {
            j["running_builds_count"] = 1;
        },
        "/scaleway/servers",
    );

    postAgentShutdownCheck("release-builder-123456");
}

@("keeps-needed-release-ci-agents")
unittest
{
    setAPIExpectations(
        "/buildkite/organizations/dlang/pipelines", (ref Json j) {
            j[].find!(p => p["name"] == "dmd")[0]["scheduled_builds_count"] = 1;
        },
        "/hcloud/servers",
    );

    postAgentShutdownCheck("ci-agent-123456");
}

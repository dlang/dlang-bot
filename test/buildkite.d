import utils;

@("answers-ping")
unittest
{
    setAPIExpectations();

    postBuildkiteHook("ping.json");
}

@("spawns-release-builder")
unittest
{
    setAPIExpectations(
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

    postBuildkiteHook("build_scheduled.json");
}

@("reuse-running-release-builder")
unittest
{
    setAPIExpectations(
        "/scaleway/servers",
    );

    postBuildkiteHook("build_scheduled.json");
}

@("spawns-additional-builder")
unittest
{
    setAPIExpectations(
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

    postBuildkiteHook("build_scheduled.json", (ref Json j, scope req) {
        j["pipeline"]["scheduled_builds_count"] = 2;
    });
}

//==============================================================================
// agent shutdown check
//==============================================================================

@("terminates-unneeded-server")
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

@("keeps-needed-server")
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

@("spawns-needed-server")
unittest
{
    setAPIExpectations(
        "/buildkite/organizations/dlang/pipelines/build-release", (ref Json j) {
            j["running_builds_count"] = 1;
            j["scheduled_builds_count"] = 1;
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

    postAgentShutdownCheck("release-builder-123456");
}

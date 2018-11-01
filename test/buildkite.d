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

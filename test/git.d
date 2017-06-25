import utils;

// send rebase label
unittest
{
    setAPIExpectations();
    import std.stdio;

    import std.array, std.conv, std.file, std.path, std.uuid;
    auto uniqDir = tempDir.buildPath("dlang-bot-git", randomUUID.to!string.replace("-", ""));
    uniqDir.mkdirRecurse;
    scope(exit) uniqDir.rmdirRecurse;

    postGitHubHook("dlang_phobos_label_4921.json", "pull_request",
        (ref Json j, scope HTTPClientRequest req){
            j["head"]["repo"]["full_name"] = "/tmp/foobar";
            j["pull_request"]["state"] = "open";
            j["label"]["name"] = "bot-rebase";
    }.toDelegate);

    // check result
}

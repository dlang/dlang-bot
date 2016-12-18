module utils;

import vibe.d, std.algorithm, std.process, std.range, std.regex, std.stdio;
import std.functional, std.string;
import app;

string testServerURL;
string ghTestHookURL;

version(unittest)
shared static this()
{
    // overwrite environment configs
    githubAuth = "ABC";
    hookSecret = "BLABLA";

    // start our hook server
    auto settings = new HTTPServerSettings;
    settings.port = 9000;
    startServer(settings);
    startFakeAPIServer();

    testServerURL = "http://" ~ settings.bindAddresses[0] ~ ":"
                             ~ settings.port.to!string;
    ghTestHookURL = testServerURL ~ "/github_hook";

    import vibe.core.log;
    setLogLevel(LogLevel.info);

    runAsync = false;
    runTrello = false;
}

void startFakeAPIServer()
{
    // start a fake API server
    auto fakeSettings = new HTTPServerSettings;
    fakeSettings.port = 9001;
    fakeSettings.bindAddresses = ["0.0.0.0"];
    fakeSettings.options = HTTPServerOption.defaults & HTTPServerOption.parseJsonBody;
    auto router = new URLRouter;
    router.any("*", &payloadServer);

    listenHTTP(fakeSettings, router);

    auto fakeAPIServerURL = "http://" ~ fakeSettings.bindAddresses[0] ~ ":"
                                      ~ fakeSettings.port.to!string;

    githubAPIURL = fakeAPIServerURL ~ "/github";
    trelloAPIURL = fakeAPIServerURL ~ "/trello";
    travisAPIURL = fakeAPIServerURL ~ "/travis";
    bugzillaURL = fakeAPIServerURL ~ "/bugzilla";
}

enum DirectionTypes { CONTINUE, STOP}

// serves saved GitHub API payloads
auto payloadServer(scope HTTPServerRequest req, scope HTTPServerResponse res)
{
    import std.path, std.file;

    if (urlExpector !is null)
        urlExpector(req, res);
    else
        logInfo("Requesting: %s", req.requestURL);

    if (payloader !is null)
    {
        auto dir = payloader(req, res);
        if (dir != DirectionTypes.CONTINUE)
            return;
    }

    string apiPrefix = req.requestURL[1..$].splitter("/").front;
    auto url = req.requestURL[apiPrefix.length + 2 .. $].replace("/", "_") ~ ".json";
    string filePath = buildPath("payloads", apiPrefix ~ "_api", url);
    if (!filePath.exists)
    {
        assert(0, "Please create payload: " ~ filePath);
    }
    else
    {
        logInfo("reading payload: %s", filePath);
        auto payload = filePath.readText;
        if (apiPrefix == "github")
        {
            auto payloadJson = payload.parseJsonString;
            if (req.requestURL.canFind("/comments"))
            {
                foreach (ref comment; payloadJson[])
                    comment["url"] = comment["url"].get!string.replace("https://api.github.com", githubAPIURL);
            }
            if (jsonPostprocessor !is null)
                payloadJson = jsonPostprocessor(req, payloadJson);

            if (payloadJson.type == Json.Type.Array)
            {
                foreach (ref el; payloadJson[])
                {
                    if ("comments_url" in el)
                        el["comments_url"] = el["comments_url"].get!string.replace("https://api.github.com", githubAPIURL);
                    if ("commits_url" in el)
                        el["commits_url"] = el["commits_url"].get!string.replace("https://api.github.com", githubAPIURL);
                }
            }


            payload = payloadJson.toString;
        }
        return res.writeBody(payload);
    }
}


DirectionTypes delegate(HTTPServerRequest req, HTTPServerResponse res) payloader;
void delegate(HTTPServerRequest req, HTTPServerResponse res) urlExpector;
Json delegate(HTTPServerRequest req, Json j) jsonPostprocessor;

void buildGitHubRequest(string payload, ref string[] expectedURLs, void delegate(ref Json j, scope HTTPClientRequest req) postprocess = null)
{
    import std.file : readText;

    // simple observer that checks whether a request is expected
    urlExpector = (scope HTTPServerRequest req, scope HTTPServerResponse res) {
        auto idx = expectedURLs.countUntil(req.requestURL);
        if (idx >= 0)
            expectedURLs = expectedURLs.remove(idx);
        else
            assert(0, "Request for unexpected URL received: " ~ req.requestURL);
    };

    // safety copy
    auto timeBetweenFullPRChecksCopy = timeBetweenFullPRChecks;

    auto req = requestHTTP(ghTestHookURL, (scope req) {
        req.method = HTTPMethod.POST;

        auto payload = payload.readText.parseJsonString;

        // localize accessed URLs
        if ("pull_request" in payload)
        {
            payload["pull_request"]["comments_url"] = payload["pull_request"]["comments_url"].get!string
                .replace("https://api.github.com", githubAPIURL);
            payload["pull_request"]["commits_url"] = payload["pull_request"]["commits_url"].get!string
                .replace("https://api.github.com", githubAPIURL);
        }

        req.headers["X-GitHub-Event"] = "pull_request";

        if (postprocess !is null)
            postprocess(payload, req);

        auto respStr = payload.toString;
        req.headers["X-Hub-Signature"] = getSignature(respStr);
        req.writeBody(cast(ubyte[]) respStr);
    });
    scope(failure) {
        if (req.statusCode != 200)
            writeln(req.bodyReader.readAllUTF8);
    }
    assert(req.statusCode == 200);
    assert(req.bodyReader.readAllUTF8 == "handled");
    scope(failure) {
        writefln("Didn't request: %s", expectedURLs);
    }
    assert(expectedURLs.length == 0);

    // sanity-cleanup
    urlExpector = null;
    payloader = null;
    jsonPostprocessor = null;
    timeBetweenFullPRChecks = timeBetweenFullPRChecksCopy;
}

// synchronize event -> should unlabel the PR

module utils;

import vibe.d, std.algorithm, std.process, std.range, std.regex, std.stdio;
import std.functional, std.string;

// forward commonly needed imports
public import dlangbot.app;
public import vibe.http.common : HTTPMethod;
public import vibe.http.client : HTTPClientRequest;
public import vibe.http.server : HTTPServerRequest, HTTPServerResponse;
public import std.functional : toDelegate;
public import vibe.data.json : deserializeJson, Json;
public import std.datetime : SysTime;
public import std.algorithm;

// existing dlang bot comment -> update comment

string testServerURL;
string ghTestHookURL;
string trelloTestHookURL;

string payloadDir = "./data/payloads";
string hookDir = "./data/hooks";

version(unittest)
shared static this()
{
    // overwrite environment configs
    githubAuth = "GH_DUMMY_AUTH_TOKEN";
    hookSecret = "GH_DUMMY_HOOK_SECRET";
    trelloAuth = "key=01234&token=abcde";
    cronDailySecret = "dummyCronSecret";

    // start our hook server
    auto settings = new HTTPServerSettings;
    settings.port = 9000;
    startServer(settings);
    startFakeAPIServer();

    testServerURL = "http://" ~ settings.bindAddresses[0] ~ ":"
                             ~ settings.port.to!string;
    ghTestHookURL = testServerURL ~ "/github_hook";
    trelloTestHookURL = testServerURL ~ "/trello_hook";

    import vibe.core.log;
    setLogLevel(LogLevel.info);

    runAsync = false;
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
    bugzillaURL = fakeAPIServerURL ~ "/bugzilla";
}

// serves saved GitHub API payloads
auto payloadServer(scope HTTPServerRequest req, scope HTTPServerResponse res)
{
    import std.path, std.file;
    APIExpectation expectation = void;

    // simple observer that checks whether a request is expected
    auto idx = apiExpectations.map!(x => x.url).countUntil(req.requestURL);
    if (idx >= 0)
    {
        expectation = apiExpectations[idx];
        if (apiExpectations.length > 1)
            apiExpectations = apiExpectations[0 .. idx] ~ apiExpectations[idx + 1 .. $];
        else
            apiExpectations.length = 0;
    }
    else
    {
        scope(failure) {
            writeln("Remaining expected URLs:", apiExpectations.map!(x => x.url));
        }
        assert(0, "Request for unexpected URL received: " ~ req.requestURL);
    }

    string filePath = buildPath(payloadDir, req.requestURL[1 .. $].replace("/", "_"));

    if (expectation.reqHandler !is null)
    {
        scope(failure) {
            writefln("Method: %s", req.method);
            writefln("Json: %s", req.json);
        }
        expectation.reqHandler(req, res);
        if (res.headerWritten)
            return;
        if (!filePath.exists)
            return res.writeVoidBody;
    }

    if (!filePath.exists)
    {
        assert(0, "Please create payload: " ~ filePath);
    }
    else
    {
        logInfo("reading payload: %s", filePath);
        auto payload = filePath.readText;
        if (req.requestURL.startsWith("/github", "/trello"))
        {
            auto payloadJson = payload.parseJsonString;
            replaceAPIReferences("https://api.github.com", githubAPIURL, payloadJson);
            replaceAPIReferences("https://api.trello.com", trelloAPIURL, payloadJson);

            if (expectation.jsonHandler !is null)
                expectation.jsonHandler(payloadJson);

            payload = payloadJson.toString;
        }
        return res.writeBody(payload);
    }
}

void replaceAPIReferences(string official, string local, ref Json json)
{
    void recursiveReplace(ref Json j)
    {
        switch (j.type)
        {
        case Json.Type.array:
        case Json.Type.object:
            j.each!recursiveReplace;
            break;
        case Json.Type.string:
            string v = j.get!string;
            if (v.countUntil(official) >= 0)
                j = v.replace(official, githubAPIURL);
            break;
        default:
            break;
        }
    }
    recursiveReplace(json);
}

struct APIExpectation
{
    string url;

    // implement a custom request handler
    private void delegate(scope HTTPServerRequest req, scope HTTPServerResponse res) reqHandler;

    // modify the json of the payload before being served
    private void delegate(ref Json j) jsonHandler;

    this(string url)
    {
        this.url = url;
    }
}

APIExpectation[] apiExpectations;

void setAPIExpectations(Args...)(Args args)
{
    import std.functional : toDelegate;
    import std.traits :  Parameters;
    apiExpectations.length = 0;
    foreach (i, arg; args)
    {
        static if (is(Args[i] : string))
        {
            apiExpectations ~= APIExpectation(arg);
        }
        else
        {
            alias params = Parameters!arg;
            static if (is(params[0] : HTTPServerRequest))
            {
                apiExpectations[$ - 1].reqHandler = arg.toDelegate;
            }
            else static if (is(params[0] : Json))
            {
                apiExpectations[$ - 1].jsonHandler = arg.toDelegate;
            }
            else
            {
                static assert(0, "Unknown handler type");
            }
            assert(apiExpectations[$ - 1].jsonHandler is null ||
                   apiExpectations[$ - 1].reqHandler is null, "Either provide a reqHandler or a jsonHandler");
        }
    }
}

void postGitHubHook(string payload, string eventType = "pull_request",
    void delegate(ref Json j, scope HTTPClientRequest req) postprocess = null,
    int line = __LINE__, string file = __FILE__)
{
    import std.file : readText;
    import std.path : buildPath;
    import dlangbot.github : getSignature;

    logInfo("Starting test in %s:%d with payload: %s", file, line, payload);

    payload = hookDir.buildPath("github", payload);

    auto req = requestHTTP(ghTestHookURL, (scope req) {
        req.method = HTTPMethod.POST;

        auto payload = payload.readText.parseJsonString;

        // localize accessed URLs
        replaceAPIReferences("https://api.github.com", githubAPIURL, payload);

        req.headers["X-GitHub-Event"] = eventType;

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
        writefln("Didn't request: %s", apiExpectations.map!(x => x.url));
    }
    assert(apiExpectations.length == 0);
}

void postTrelloHook(string payload,
    void delegate(ref Json j, scope HTTPClientRequest req) postprocess = null,
    int line = __LINE__, string file = __FILE__)
{
    import std.file : readText;
    import std.path : buildPath;
    import dlangbot.trello : getSignature;

    payload = hookDir.buildPath("trello", payload);

    logInfo("Starting test in %s:%d with payload: %s", file, line, payload);

    auto req = requestHTTP(trelloTestHookURL, (scope req) {
        req.method = HTTPMethod.POST;

        auto payload = payload.readText.parseJsonString;

        // localize accessed URLs
        replaceAPIReferences("https://api.trello.com", trelloAPIURL, payload);

        if (postprocess !is null)
            postprocess(payload, req);

        auto respStr = payload.toString;
        req.headers["X-Trello-Webhook"] = getSignature(respStr, trelloHookURL);
        req.writeBody(cast(ubyte[]) respStr);
    });
    scope(failure) {
        if (req.statusCode != 200)
            writeln(req.bodyReader.readAllUTF8);
    }
    assert(req.statusCode == 200);
    assert(req.bodyReader.readAllUTF8 == "handled");
    scope(failure) {
        writefln("Didn't request: %s", apiExpectations.map!(x => x.url));
    }
    assert(apiExpectations.length == 0);
}

void openUrl(string url, string expectedResponse,
    int line = __LINE__, string file = __FILE__)
{
    import std.file : readText;
    import std.path : buildPath;

    logInfo("Starting test in %s:%d with url: %s", file, line, url);

    auto req = requestHTTP(testServerURL ~ url, (scope req) {
        req.method = HTTPMethod.GET;
    });
    scope(failure) {
        if (req.statusCode != 200)
            writeln(req.bodyReader.readAllUTF8);
    }
    assert(req.statusCode == 200);
    scope(failure) {
        writefln("Didn't request: %s", apiExpectations.map!(x => x.url));
    }
    assert(apiExpectations.length == 0);
    assert(req.bodyReader.readAllUTF8 == expectedResponse);
}

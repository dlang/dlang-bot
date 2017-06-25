module utils;

import vibe.d, std.algorithm, std.process, std.range, std.regex, std.stdio;
import std.functional, std.string;

// forward commonly needed imports
public import dlangbot.app;
public import vibe.http.common : HTTPMethod, HTTPStatus;
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

/// Tries to find a free port
ushort getFreePort()
{
    import std.conv : to;
    import std.socket : AddressFamily, InternetAddress, Socket, SocketType;
    auto s = new Socket(AddressFamily.INET, SocketType.STREAM);
    scope(exit) s.close;
    s.bind(new InternetAddress(0));
    return s.localAddress.toPortString.to!ushort;
}

version(unittest)
shared static this()
{
    // overwrite environment configs
    githubAuth = "GH_DUMMY_AUTH_TOKEN";
    hookSecret = "GH_DUMMY_HOOK_SECRET";
    trelloAuth = "key=01234&token=abcde";

    // start our hook server
    auto settings = new HTTPServerSettings;
    settings.port = getFreePort;
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
    fakeSettings.port = getFreePort;
    fakeSettings.bindAddresses = ["0.0.0.0"];
    auto router = new URLRouter;

    listenHTTP(fakeSettings, router);

    auto fakeAPIServerURL = "http://" ~ fakeSettings.bindAddresses[0] ~ ":"
                                      ~ fakeSettings.port.to!string;

    githubAPIURL = fakeAPIServerURL ~ "/github";
    trelloAPIURL = fakeAPIServerURL ~ "/trello";
    bugzillaURL = fakeAPIServerURL ~ "/bugzilla";
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
    /// the called server url
    string url;

    /// implement a custom request handler
    private void delegate(scope HTTPServerRequest req, scope HTTPServerResponse res) reqHandler;

    /// modify the json of the payload before being served
    private void delegate(ref Json j) jsonHandler;

    /// respond with the given status
    HTTPStatus respStatusCode = HTTPStatus.ok;

    this(string url)
    {
        this.url = url;
    }
}

__gshared APIExpectation[] apiExpectations;

void setAPIExpectations(Args...)(Args args)
{
    import std.functional : toDelegate;
    import std.traits :  Parameters;
    synchronized {
    apiExpectations.length = 0;
    foreach (i, arg; args)
    {
        static if (is(Args[i] : string))
        {
            apiExpectations ~= APIExpectation(arg);
        }
        else static if (is(Args[i] : HTTPStatus))
        {
            apiExpectations[$ - 1].respStatusCode = arg;
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
}

void checkAPIExpectations()
{
    scope(failure) {
        writefln("Didn't request: %s", apiExpectations.map!(x => x.url));
    }
    assert(apiExpectations.length == 0);
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
    checkAPIExpectations;
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
    checkAPIExpectations;
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
    checkAPIExpectations;
    assert(req.bodyReader.readAllUTF8 == expectedResponse);
}

void testCronDaily(string[] repositories, int line = __LINE__, string file = __FILE__)
{
    import dlangbot.app : cronDaily;
    import dlangbot.cron : CronConfig;

    logInfo("Starting cron test in %s:%d", file, line);

    CronConfig config = {
        simulate: false,
        waitAfterMergeNullState: 1.msecs,
    };
    cronDaily(repositories, config);
    checkAPIExpectations;
}

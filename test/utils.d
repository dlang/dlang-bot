module utils;

import vibe.d, std.algorithm, std.process, std.range, std.regex, std.stdio;
import std.functional, std.string;

// forward commonly needed imports
public import dlangbot.app;
public import vibe.core.log;
public import vibe.http.common : HTTPMethod, HTTPStatus;
public import vibe.http.client : HTTPClientRequest;
public import vibe.http.server : HTTPServerRequest, HTTPServerResponse;
public import std.functional : toDelegate;
public import vibe.data.json : deserializeJson, serializeToJson, Json;
public import std.datetime.systime : SysTime;
public import std.algorithm;
import std.datetime.timezone : TimeZone, UTC;

// existing dlang bot comment -> update comment

string testServerURL;
string ghTestHookURL;
string trelloTestHookURL;
string buildkiteTestHookURL;

enum payloadDir = "./data/payloads";
enum graphqlDir = payloadDir ~ "/graphql";
enum hookDir = "./data/hooks";

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
    githubHookSecret = "GH_DUMMY_HOOK_SECRET";
    trelloAuth = "key=01234&token=abcde";
    buildkiteAuth = "Bearer abcdef";
    buildkiteHookSecret = "1234567890";
    scalewayAuth = "89f66bbd-f2f0-4f95-9382-56d141c1c09e";
    scalewayOrg = "aa435976-67f1-455c-b988-f4dc04c91f40";
    hcloudAuth = "Bearer BDc2RZCKKvgdyF6Dgex1kg4NGwkScI9xzBZqGJemkR4GopohwatiH0IRD2iTg61o";
    dlangbotAgentAuth = "Bearer fjSL8ITFkOxS5PF9p5lM41mox";

    // start our hook server
    auto settings = new HTTPServerSettings;
    settings.port = getFreePort;
    startServer(settings);
    startFakeAPIServer();

    testServerURL = "http://" ~ settings.bindAddresses[0] ~ ":"
                             ~ settings.port.to!string;
    ghTestHookURL = testServerURL ~ "/github_hook";
    trelloTestHookURL = testServerURL ~ "/trello_hook";
    buildkiteTestHookURL = testServerURL ~ "/buildkite_hook";

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
    router.any("*", &payloadServer);

    listenHTTP(fakeSettings, router);

    auto fakeAPIServerURL = "http://" ~ fakeSettings.bindAddresses[0] ~ ":"
                                      ~ fakeSettings.port.to!string;

    githubAPIURL = fakeAPIServerURL ~ "/github";
    trelloAPIURL = fakeAPIServerURL ~ "/trello";
    buildkiteAPIURL = fakeAPIServerURL ~ "/buildkite";
    scalewayAPIURL = fakeAPIServerURL ~ "/scaleway";
    hcloudAPIURL = fakeAPIServerURL ~ "/hcloud";
    bugzillaURL = fakeAPIServerURL ~ "/bugzilla";
    twitterURL = fakeAPIServerURL ~ "/twitter";
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

    res.statusCode = expectation.respStatusCode;
    // set failure status code exception to suppress false errors
    import dlangbot.utils : _expectedStatusCode;
    if (expectation.respStatusCode / 100 != 2)
        _expectedStatusCode = expectation.respStatusCode;

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
        if (req.requestURL.startsWith("/github", "/trello", "/scaleway", "/buildkite", "/hcloud"))
        {
            auto payloadJson = payload.parseJsonString;
            replaceAPIReferences("https://api.github.com", githubAPIURL, payloadJson);
            replaceAPIReferences("https://api.trello.com", trelloAPIURL, payloadJson);
            replaceAPIReferences("https://dp-par1.scaleway.com", scalewayAPIURL, payloadJson);
            replaceAPIReferences("https://api.buildkite.com/v2", buildkiteAPIURL, payloadJson);

            if (expectation.jsonHandler !is null)
                expectation.jsonHandler(payloadJson);

            return res.writeJsonBody(payloadJson);
        }
        else
        {
            return res.writeBody(payload);
        }
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
                j = v.replace(official, local);
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

void graphQL(string path, alias process=(ref Json){})(scope HTTPServerRequest req, scope HTTPServerResponse res)
{
    import std.file : readText;
    import std.path : buildPath;

    assert(req.method == HTTPMethod.POST);
    assert(req.json["query"].get!string.canFind("query"));

    auto filePath = buildPath(graphqlDir, path);
    logInfo("reading payload: %s", filePath);
    auto json = filePath.readText.parseJsonString;
    process(json);
    res.writeJsonBody(json);
}

void checkAPIExpectations()
{
    if (apiExpectations.length != 0)
        logWarn("Didn't request: %s", apiExpectations.map!(x => x.url));
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

void postBuildkiteHook(string payload,
    void delegate(ref Json j, scope HTTPClientRequest req) postprocess = null,
    int line = __LINE__, string file = __FILE__)
{
    import std.file : readText;
    import std.path : buildPath;
    import dlangbot.trello : getSignature;

    payload = hookDir.buildPath("buildkite", payload);

    logInfo("Starting test in %s:%d with payload: %s", file, line, payload);

    auto req = requestHTTP(buildkiteTestHookURL, (scope req) {
        req.method = HTTPMethod.POST;

        auto payload = payload.readText.parseJsonString;

        // localize accessed URLs
        replaceAPIReferences("https://api.buildkite.com", buildkiteAPIURL, payload);

        req.headers["X-Buildkite-Event"] = payload["event"].get!string;

        if (postprocess !is null)
            postprocess(payload, req);

        auto respStr = payload.toString;
        req.headers["X-Buildkite-Token"] = buildkiteHookSecret;
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

void postAgentShutdownCheck(string hostname, int line = __LINE__, string file = __FILE__)
{
    import vibe.textfilter.urlencode : urlEncode;

    logInfo("Starting test in %s:%d with hostname %s", file, line, hostname);

    auto req = requestHTTP(testServerURL ~ "/agent_shutdown_check", (scope req) {
        req.method = HTTPMethod.POST;
        req.headers["Authentication"] = dlangbotAgentAuth;
        req.writeFormBody(["hostname": hostname]);
    });
    scope(failure) {
        if (req.statusCode != 200)
            writeln(req.bodyReader.readAllUTF8);
    }
    assert(req.statusCode == 200);
    checkAPIExpectations;
    req.dropBody;
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

SysTime now(immutable TimeZone tz = UTC())
{
    import std.datetime.systime : Clock;

    auto now = Clock.currTime(tz);
    now.fracSecs = Duration.zero;
    return now;
}

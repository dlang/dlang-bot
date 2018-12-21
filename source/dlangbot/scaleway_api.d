module dlangbot.scaleway_api;

import std.algorithm;
import std.array : array, empty, front;
import std.datetime.systime;
import std.string : format;

import vibe.core.log : logError, logInfo;
import vibe.data.json : byName, Name = name, deserializeJson, serializeToJson, Json;
import vibe.http.common : enforceHTTP, HTTPMethod, HTTPStatus;
import vibe.stream.operations : readAllUTF8;

import dlangbot.utils : request;

string scalewayAPIURL = "https://cp-par1.scaleway.com";
string scalewayAuth, scalewayOrg;

//==============================================================================
// Scaleway (Bare Metal) servers
//==============================================================================

struct Server
{
    string id, name;
    enum State { starting, running, stopped }
    @byName State state;

    enum Action { poweron, poweroff, terminate }

    void action(Action action)
    {
        import std.conv : to;
        scwPOST("/servers/%s/action".format(id), ["action": action.to!string]).dropBody;
    }

    void decommission()
    {
        logInfo("decommission scaleway server %s", name);
        action(Action.terminate);
    }

    @property bool healthy() const
    {
        import std.range : only;

        with (State)
            return only(starting, running).canFind(state);
    }
}

struct Image
{
    string id, name, organization;
    @Name("creation_date") SysTime creationDate;
}

Server[] servers()
{
    return scwGET("/servers")
        .readJson["servers"]
        .deserializeJson!(typeof(return));
}

Server createServer(string name, string serverType, Image image)
{
    logInfo("provision scaleway %s server %s with image %s", serverType, name, image.name);

    auto payload = serializeToJson([
            "organization": scalewayOrg,
            "name": name,
            "image": image.id,
            "commercial_type": serverType]);
    payload["enable_ipv6"] = true;
    return scwPOST("/servers", payload)
        .readJson["server"]
        .deserializeJson!Server;
}

Image[] images()
{
    return scwGET("/images")
        .readJson["images"]
        .deserializeJson!(typeof(return))
        .sort!((a, b) => a.creationDate > b.creationDate)
        .release;
}

private:

auto scwGET(string path)
{
    return request(scalewayAPIURL ~ path, (scope req) {
        req.headers["X-Auth-Token"] = scalewayAuth;
    });
}

auto scwPOST(T)(string path, T arg)
{
    return request(scalewayAPIURL ~ path, (scope req) {
        req.headers["X-Auth-Token"] = scalewayAuth;
        req.method = HTTPMethod.POST;
        req.writeJsonBody(arg);
    });
}

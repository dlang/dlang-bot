module dlangbot.scaleway_api;

import std.algorithm;
import std.array : array, empty, front;
import std.datetime.systime;
import std.string : format;

import vibe.core.log : logDebug, logError, logInfo;
import vibe.data.json : byName, Name = name, deserializeJson, serializeToJson, Json;
import vibe.http.common : enforceHTTP, HTTPMethod, HTTPStatus;
import vibe.stream.operations : readAllUTF8;

import dlangbot.utils : request;

shared string scalewayAPIURL = "https://cp-par1.scaleway.com";
shared string scalewayAuth, scalewayOrg;

//==============================================================================
// Scaleway (Bare Metal) servers
//==============================================================================

struct Server
{
    string id, name;
    enum State { starting, running, stopped }
    @byName State state;
    SysTime creation_date;
    Volume[string] volumes;

    enum Action { poweron, poweroff, terminate }

    void action(Action action)
    {
        import std.conv : to;
        scwPOST("/servers/%s/action".format(id), ["action": action.to!string]).dropBody;
    }

    void decommission()
    {
        logInfo("decommission scaleway server %s", name);
        if (healthy)
            action(Action.terminate);
        else
        {
            scwDELETE("/servers/%s".format(id)).dropBody;
            volumes.each!(v => v.delete_);
        }
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

struct Volume
{
    string id, name;

    void delete_()
    {
        scwDELETE("/volumes/%s".format(id)).dropBody;
    }
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

auto scwDELETE(string path)
{
    return request(scalewayAPIURL ~ path, (scope req) {
        req.headers["X-Auth-Token"] = scalewayAuth;
        req.method = HTTPMethod.DELETE;
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

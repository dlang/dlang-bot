module dlangbot.hcloud_api;

import std.algorithm;
import std.array : array, empty, front;
import std.datetime.systime;
import std.string : format;
import std.typecons : Nullable;

import vibe.core.log : logError, logInfo;
import vibe.data.json : byName, Name = name, deserializeJson, serializeToJson, Json;
import vibe.http.common : enforceHTTP, HTTPMethod, HTTPStatus;
import vibe.stream.operations : readAllUTF8;

import dlangbot.utils : request;

string hcloudAPIURL = "https://api.hetzner.cloud/v1/";
string hcloudAuth;

//==============================================================================
// Hetzner Cloud (KVM) servers
//==============================================================================

struct Server
{
    ulong id;
    string name;
    enum Status { running, initializing, starting, stopping, off, deleting, migrating, rebuilding, unknown }
    @byName Status status;

    void decommission()
    {
        hcloudDELETE("/servers/%s".format(id));
    }
}

struct Image
{
    enum Type { system, snapshot, backup }
    ulong id;
    string description;
}

Server[] servers()
{
    return hcloudGET("/servers")
        .readJson["servers"]
        .deserializeJson!(typeof(return));
}

Server createServer(string name, string serverType, Image image)
{
    import std.conv : to;

    return hcloudPOST("/servers",
        [
            "name": name,
            "server_type": serverType,
            "image": image.id.to!string,
        ])
        .readJson
        .deserializeJson!(typeof(return));
}

Image[] images()
{
    return hcloudGET("/images")
        .readJson
        .deserializeJson!(typeof(return));
}

Image[] images(Image.Type type)
{
    import std.conv : to;
    import vibe.textfilter.urlencode : urlEncode;

    return hcloudGET("/images?type="~type.to!string.urlEncode)
        .readJson["images"]
        .deserializeJson!(typeof(return));
}

private:

auto hcloudGET(string path)
{
    return request(hcloudAPIURL ~ path, (scope req) {
        req.headers["Authorization"] = hcloudAuth;
    });
}

auto hcloudPOST(T...)(string path, T arg)
    if (T.length <= 1)
{
    return request(hcloudAPIURL ~ path, (scope req) {
        req.headers["Authorization"] = hcloudAuth;
        req.method = HTTPMethod.POST;
        req.writeJsonBody(arg);
    });
}

void hcloudDELETE(string path)
{
    request(hcloudAPIURL ~ path, (scope req) {
        req.headers["Authorization"] = hcloudAuth;
        req.method = HTTPMethod.DELETE;
    }).dropBody;
}

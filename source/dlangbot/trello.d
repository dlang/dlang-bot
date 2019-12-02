module dlangbot.trello;

shared string trelloAPIURL = "https://api.trello.com";
shared string trelloSecret, trelloAuth;

import dlangbot.bugzilla : Issue, IssueRef;
import dlangbot.utils : request;
import std.algorithm, std.range;
import std.format : format;

import vibe.core.log;
import vibe.data.json;
import vibe.http.common : HTTPMethod;
import vibe.stream.operations : readAllUTF8;

//==============================================================================
// Trello cards
//==============================================================================

void trelloSendRequest(T...)(HTTPMethod method, string url, T arg)
    if (T.length <= 1)
{
    request(url, (scope req) {
        req.method = method;
        static if (T.length)
            req.writeJsonBody(arg);
    }, (scope res) {
        if (res.statusCode / 100 == 2)
            logInfo("%s %s: %s\n", method, url.replace(trelloAuth, "key=[hidden]&token=[hidden]")
                    , res.statusPhrase);
        else
            logError("%s %s: %s %s.\n%s", method, url.replace(trelloAuth, "key=[hidden]&token=[hidden]"),
                res.statusPhrase, res.statusCode, res.bodyReader.readAllUTF8);
    });
}

struct TrelloCard { string id; int issueID; }

string trelloAPI(Args...)(string fmt, Args args)
{
    import std.uri : encode;
    return encode(trelloAPIURL ~fmt.format(args)~(fmt.canFind("?") ? "&" : "?")~trelloAuth);
}

string formatTrelloComment(string existingComment, Issue[] issues)
{
    import std.format : formattedWrite;
    import std.stdio : KeepTerminator;
    import std.string : lineSplitter;

    auto app = appender!string();
    foreach (issue; issues)
        app.formattedWrite("- [Issue %1$d - %2$s](https://issues.dlang.org/show_bug.cgi?id=%1$d)\n", issue.id, issue.desc);

    existingComment
        .lineSplitter!(KeepTerminator.yes)
        .filter!(line => !line.canFind("issues.dlang.org"))
        .each!(ln => app.put(ln));
    return app.data;
}

string formatTrelloComment(string existingComment, string pullRequestURL)
{
    import std.format : formattedWrite;
    import std.stdio : KeepTerminator;
    import std.string : lineSplitter;

    auto app = appender!string();

    auto lines = existingComment
        .lineSplitter!(KeepTerminator.yes);
    lines.each!(ln => app.put(ln));
    if (!lines.canFind!(line => line.canFind(pullRequestURL)))
        app.formattedWrite("- %s\n", pullRequestURL);
    return app.data;
}

auto findTrelloCards(int issueID)
{

    return trelloAPI("/1/search?query=name:\"Issue %d\"", issueID)
        .request
        .readJson["cards"][]
        .map!(c => TrelloCard(c["id"].get!string, issueID));
}

struct Comment { string url, body_; }

Comment getTrelloBotComment(string cardID)
{
    auto res = trelloAPI("/1/cards/%s/actions?filter=commentCard", cardID)
        .request
        .readJson[]
        .find!(c => c["memberCreator"]["username"] == "dlangbot");
    if (res.length)
        return Comment(
            trelloAPI("/1/cards/%s/actions/%s/comments", cardID, res[0]["id"].get!string),
            res[0]["data"]["text"].get!string);
    return Comment();
}

void moveCardToList(string cardID, string listName)
{
    auto card = trelloAPI("/1/cards/%s", cardID)
        .request
        .readJson;
    auto lists = trelloAPI("/1/board/%s/lists", card["idBoard"].get!string)
        .request
        .readJson[];

    immutable curListName = lists.find!(c => c["id"].get!string == card["idList"].get!string)
        .front["name"].get!string;
    // don't move cards in done, see #9
    if (curListName.startsWith("Done", listName))
    {
        logInfo("moveCardToList(%s, %s) card already in %s", cardID, listName, curListName);
        return;
    }

    logInfo("moveCardToList(%s, %s)", cardID, listName);
    immutable listID = lists.find!(c => c["name"].get!string.startsWith(listName))
        .front["id"].get!string;
    trelloSendRequest(HTTPMethod.PUT, trelloAPI("/1/cards/%s/idList?value=%s", cardID, listID));
    trelloSendRequest(HTTPMethod.PUT, trelloAPI("/1/cards/%s/pos?value=bottom", cardID));
}

void updateTrelloCard(string action, string pullRequestURL, IssueRef[] refs, Issue[] descs)
{
    foreach (grp; descs.map!(d => findTrelloCards(d.id)).join.chunkBy!((a, b) => a.id == b.id))
    {
        auto cardID = grp.front.id;
        auto comment = getTrelloBotComment(cardID);
        auto issues = descs.filter!(d => grp.canFind!((tc, issueID) => tc.issueID == issueID)(d.id));
        logDebug("%s %s", cardID, issues);
        if (issues.empty)
        {
            if (comment.url.length)
                trelloSendRequest(HTTPMethod.DELETE, comment.url);
            return;
        }

        auto msg = formatTrelloComment(comment.body_, pullRequestURL);
        logDebug("%s", msg);

        if (msg != comment.body_)
        {
            if (comment.url.length)
                trelloSendRequest(HTTPMethod.PUT, comment.url, ["text": msg]);
            else if (action != "closed")
                trelloSendRequest(HTTPMethod.POST, trelloAPI("/1/cards/%s/actions/comments", cardID), ["text": msg]);
        }

        if ((action == "opened" || action == "merged") &&
            grp.all!(tc => refs.find!(r => r.id == tc.issueID).front.fixed))
            moveCardToList(cardID, action == "opened" ? "Testing" : "Done");
    }
}

void updateTrelloCard(string cardID, IssueRef[] refs, Issue[] descs)
{
    auto comment = getTrelloBotComment(cardID);
    auto issues = descs;
    logDebug("%s %s", cardID, issues);
    if (issues.empty)
    {
        if (comment.url.length)
            trelloSendRequest(HTTPMethod.DELETE, comment.url);
        return;
    }

    auto msg = formatTrelloComment(comment.body_, issues);
    logDebug("%s", msg);

    if (msg != comment.body_)
    {
        if (comment.url.length)
            trelloSendRequest(HTTPMethod.PUT, comment.url, ["text": msg]);
        else
            trelloSendRequest(HTTPMethod.POST, trelloAPI("/1/cards/%s/actions/comments", cardID), ["text": msg]);
    }
}

//==============================================================================
// Trello hook
//==============================================================================

import std.string : representation;

private char[28] base64Digest(Range)(Range range)
{
    import std.digest, std.digest.hmac, std.digest.sha;
    import std.base64;

    auto hmac = HMAC!SHA1(trelloSecret.representation);
    foreach (c; range)
        hmac.put(c);
    char[28] buf = void;
    Base64.encode(hmac.finish, buf[]);
    return buf;
}

char[28] getSignature(string body_, string url)
{
    import std.utf : byUTF;

    return base64Digest(body_.byUTF!dchar.map!(c => cast(immutable ubyte) c).chain(url.representation));
}

Json verifyRequest(string signature, string body_, string url)
{
    import std.exception : enforce;

    enforce(getSignature(body_, url) == signature, "signature mismatch");
    return parseJsonString(body_);
}

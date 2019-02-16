module dlangbot.bugzilla;

import vibe.data.json : Json, parseJsonString;
import vibe.inet.webform : urlEncode;

shared string bugzillaURL = "https://issues.dlang.org";

import std.algorithm, std.conv, std.range, std.string;
import std.exception : enforce;
import std.format : format;

//==============================================================================
// Bugzilla
//==============================================================================

auto matchIssueRefs(string message)
{
    import std.regex;

    static auto matchToRefs(M)(M m)
    {
        enum splitRE = regex(`[^\d]+`); // ctRegex throws a weird error in unittest compilation
        auto closed = !m.captures[1].empty;
        return m.captures[5].stripRight.splitter(splitRE)
            .filter!(id => !id.empty) // see #6
            .map!(id => IssueRef(id.to!int, closed));
    }

    // see https://github.com/github/github-services/blob/2e886f407696261bd5adfc99b16d36d5e7b50241/lib/services/bugzilla.rb#L155
    enum issueRE = ctRegex!(`((close|fix|address)e?(s|d)? )?(ticket|bug|tracker item|issue)s?:? *([\d ,\+&#and]+)`, "i");
    return matchToRefs(message.matchFirst(issueRE));
}

unittest
{
    assert(equal(matchIssueRefs("fix issue 16319 and fix std.traits.isInnerClass"), [IssueRef(16319, true)]));
    assert(equal(matchIssueRefs("Fixes issues 17494, 17505, 17506"), [IssueRef(17494, true), IssueRef(17505, true), IssueRef(17506, true)]));
    // only first match considered, see #175
    assert(equal(matchIssueRefs("Fixes Issues 1234 and 2345\nblabla\nFixes Issue 3456"), [IssueRef(1234, true), IssueRef(2345, true)]));
}

struct IssueRef { int id; bool fixed; Json[] commits; }
// get all issues mentioned in a commit
IssueRef[] getIssueRefs(Json[] commits)
{
    return commits
        // Collect all issue references (range of ranges per commit)
        .map!(c => c["commit"]["message"]
            .get!string
            .matchIssueRefs
            .map!((r) { r.commits = [c]; return r; })
        )
        // Join to flat list
        .join
        // Sort and group by issue ID
        .sort!((a, b) => a.id < b.id, SwapStrategy.stable)
        .groupBy
        // Reduce each per-ID group to a single IssueRef
        .map!(g => g
            .reduce!((a, b) =>
                IssueRef(a.id, a.fixed || b.fixed, a.commits ~ b.commits)
            )
        )
        .array;
}

unittest
{
    Json fix(int id) { return ["commit":["message":"Fix Issue %d".format(id).Json].Json].Json; }
    Json mention(int id) { return ["commit":["message":"Issue %d".format(id).Json].Json].Json; }

    assert(getIssueRefs([fix(1)]) == [IssueRef(1, true, [fix(1)])]);
    assert(getIssueRefs([mention(1)]) == [IssueRef(1, false, [mention(1)])]);
    assert(getIssueRefs([fix(1), mention(1)]) == [IssueRef(1, true, [fix(1), mention(1)])]);
    assert(getIssueRefs([mention(1), fix(1)]) == [IssueRef(1, true, [mention(1), fix(1)])]);
    assert(getIssueRefs([mention(1), fix(2), fix(1)]) == [IssueRef(1, true, [mention(1), fix(1)]), IssueRef(2, true, [fix(2)])]);
}

struct Issue
{
    int id;
    string desc;
    string status;
    string resolution;
    string severity;
    string priority;
}

// get pairs of (issue number, short descriptions) from bugzilla
Issue[] getDescriptions(R)(R issueRefs)
{
    import std.csv;
    import vibe.stream.operations : readAllUTF8;
    import dlangbot.utils : request;

    if (issueRefs.empty)
        return null;
    return "%s/buglist.cgi?bug_id=%(%d,%)&ctype=csv&columnlist=short_desc,bug_status,resolution,bug_severity,priority"
        .format(bugzillaURL, issueRefs.map!(r => r.id))
        .request
        .bodyReader.readAllUTF8
        .csvReader!Issue(null)
        .array
        .sort!((a, b) => a.id < b.id)
        .release;
}

shared string bugzillaLogin, bugzillaPassword;

Json apiCall(string method, Json[string] params = null)
{
    import vibe.stream.operations : readAllUTF8;
    import dlangbot.utils : request;

    auto url = bugzillaURL ~ "/jsonrpc.cgi";
    auto jsonText = url.request(
        (scope req) {
            import vibe.http.common : HTTPMethod;
            req.method = HTTPMethod.POST;
            req.headers["Content-Type"] = "application/json-rpc";
            req.writeJsonBody([
                "method" : method.Json,
                "params" : [params.Json].Json,
                "id" : 0.Json, // https://bugzilla.mozilla.org/show_bug.cgi?id=694663
            ].Json);
        }
    ).bodyReader.readAllUTF8;
    auto reply = jsonText.parseJsonString();
    enforce(reply["error"] == null, "Server error: " ~ reply["error"].to!string);
    return reply["result"];
}

Json authenticatedApiCall(string method, Json[string] params)
{
    params["Bugzilla_login"] = bugzillaLogin;
    params["Bugzilla_password"] = bugzillaPassword;
    return apiCall(method, params);
}

void updateBugs(int[] bugIDs, string comment, bool closeAsFixed)
{
    Json[string] params;
    params["ids"] = bugIDs.map!(id => Json(id)).array.Json;

    if (comment)
        params["comment"] = ["body" : comment.Json].Json;
    if (closeAsFixed)
    {
        params["status"] = "RESOLVED".Json;
        params["resolution"] = "FIXED".Json;
    }

    authenticatedApiCall("Bug.update", params);
}

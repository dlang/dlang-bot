module dlangbot.bugzilla;

import vibe.data.json : Json, parseJsonString;
import vibe.inet.webform : urlEncode;

shared string bugzillaURL = "https://issues.dlang.org";

// D projects which use Bugzilla for bug tracking.
static immutable bugzillaProjectSlugs = ["dlang/dmd", "dlang/druntime", "dlang/phobos",
    "dlang/dlang.org", "dlang/tools", "dlang/installer"];


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
        enum splitRE = ctRegex!(`(\d+)`);
        // [1] is the issue numbers that are fixed, [2] are for simple refs
        const bool closed = !m.captures[1].empty;
        return m.captures[2 - closed].matchAll(ctRegex!`\d+`)
            .map!(match => IssueRef(match.hit.to!int, closed));
    }

    enum issueRE = ctRegex!(`(?:^fix(?:es)?(?:\s+bugzilla)(?:\s+(?:issues?|bugs?))?\s+(#?\d+(?:[\s,\+&and]+#?\d+)*))|` ~
                            `(?:bugzilla\s+(?:(?:issues?|bugs?)\s+)?(#?\d+(?:[\s,\+&and]+#?\d+)*))`, "im");
    return matchToRefs(message.matchFirst(issueRE));
}

unittest
{
    assert(equal(matchIssueRefs("fix bugzilla issue 16319 and fix std.traits.isInnerClass"),
                 [IssueRef(16319, true)]));
    assert(equal(matchIssueRefs("Fixes Bugzilla issues 17494, 17505, 17506"),
                 [IssueRef(17494, true),IssueRef(17505, true), IssueRef(17506, true)]));
    assert(equal(matchIssueRefs("Fix bugzilla issues 42, 55, 98: Baguette poisson fraise"),
                 [ IssueRef(42, true), IssueRef(55, true), IssueRef(98, true)  ]));
    // Multi-line
    assert(equal(matchIssueRefs("Bla bla bla\n\nFixes bugzilla issue #123"),
                 [IssueRef(123, true)]));
    // only first match considered, see #175
    assert(equal(matchIssueRefs("Fixes BugZilla Issues 1234 and 2345\nblabla\nFixes BugZilla Issue 3456"),
                 [IssueRef(1234, true), IssueRef(2345, true)]));
    // Related, but not closing
    assert(equal(matchIssueRefs("Bugzilla Issue 242: Refactor prior to fix"),
                 [IssueRef(242, false)]));
    assert(equal(matchIssueRefs("Bugzilla Bug 123: Add a test"),
                 [IssueRef(123, false)]));
    assert(equal(matchIssueRefs("Bugzilla Issue #456: Improve error message"),
                 [IssueRef(456, false)]));

    // Short hand syntax
    assert(equal(matchIssueRefs("Fix Bugzilla 222, 333 and 42000: Baguette poisson fraise"),
                 [ IssueRef(222, true), IssueRef(333, true), IssueRef(42000, true)  ]));
    assert(equal(matchIssueRefs("Fix Bugzilla 4242 & 131 Baguette poisson fraise"),
                 [ IssueRef(4242, true), IssueRef(131, true)  ]));
    // Just a reference, not a fix
    assert(equal(matchIssueRefs("Bugzilla Issue 242: Warn about buggy behavior"),
                 [IssueRef(242, false)]));
    assert(equal(matchIssueRefs("Do not quite fix bugzilla issue 242 but it's a start"),
                 [IssueRef(242, false)]));
    assert(equal(matchIssueRefs("Workaround needed to make bugzilla bug 131415 less deadly"),
                 [IssueRef(131415, false)]));
    assert(equal(matchIssueRefs("Workaround needed to make bugzilla 131415 less deadly"),
                 [IssueRef(131415, false)]));

    // Shouldn't match
    const IssueRef[] empty;
    assert(equal(matchIssueRefs("Will fix 242 and 131 later"), empty));
    assert(equal(matchIssueRefs("Issue with 242 character"), empty));
    // Too ambiguous to match
    assert(equal(matchIssueRefs("#4242: Reduce indentation prior to fix"), empty));

    // Note: This *will match* so just don't use that verb?
    // assert(equal(matchIssueRefs("DMD issues 10 weird error message on shutdown"),
    //              [IssueRef(10, false)]));
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
    Json fix(int id) { return ["commit":["message":"Fix Bugzilla %d".format(id).Json].Json].Json; }
    Json mention(int id) { return ["commit":["message":"Bugzilla %d".format(id).Json].Json].Json; }

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
    string keywords;
}

// get pairs of (issue number, short descriptions) from bugzilla
Issue[] getDescriptions(R)(R issueRefs)
{
    import std.csv;
    import vibe.stream.operations : readAllUTF8;
    import dlangbot.utils : request, expectOK;

    if (issueRefs.empty)
        return null;
    return "%s/buglist.cgi?bug_id=%(%d,%)&ctype=csv&columnlist=short_desc,bug_status,resolution,bug_severity,priority,keywords"
        .format(bugzillaURL, issueRefs.map!(r => r.id))
        .request
        .expectOK
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
    import dlangbot.utils : request, expectOK;

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
    ).expectOK.bodyReader.readAllUTF8;
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

void updateBugs(int[] bugIDs, string comment, bool closeAsFixed, string[] addKeywords = null)
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
    if (addKeywords)
        params["keywords"] = ["add" : addKeywords.map!(k => Json(k)).array.Json].Json;

    authenticatedApiCall("Bug.update", params);
}

Json[][int] getBugComments(int[] ids)
{
    Json[][int] comments;

    foreach (chunk; ids.chunks(1000))
    {
        // Use an authenticated API call to also get users' email addresses
        // (to identify our own comments).
        auto result = authenticatedApiCall("Bug.comments", [
            "ids" : chunk.map!(id => id.Json).array.Json
        ]);
        foreach (string id, Json bugComments; result["bugs"])
            comments[id.to!int] = bugComments["comments"].get!(Json[]);
    }

    return comments;
}

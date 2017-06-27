module dlangbot.bugzilla;

import vibe.data.json : Json;

string bugzillaURL = "https://issues.dlang.org";

import std.algorithm, std.conv, std.range, std.string;
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
    return message.matchAll(issueRE).map!matchToRefs.joiner;
}

unittest
{
    assert(equal(matchIssueRefs("fix issue 16319 and fix std.traits.isInnerClass"), [IssueRef(16319, true)]));
}

struct IssueRef { int id; bool fixed; }
// get all issues mentioned in a commit
IssueRef[] getIssueRefs(Json[] commits)
{
    auto issues = commits
        .map!(c => c["commit"]["message"].get!string.matchIssueRefs)
        .array
        .joiner
        .array;
    issues.multiSort!((a, b) => a.id < b.id, (a, b) => a.fixed > b.fixed);
    issues.length -= issues.uniq!((a, b) => a.id == b.id).copy(issues).length;
    return issues;
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
    import vibe.http.client : requestHTTP;
    import vibe.stream.operations : readAllUTF8;

    if (issueRefs.empty)
        return null;
    return "%s/buglist.cgi?bug_id=%(%d,%)&ctype=csv&columnlist=short_desc,bug_status,resolution,bug_severity,priority"
        .format(bugzillaURL, issueRefs.map!(r => r.id))
        .requestHTTP
        .bodyReader.readAllUTF8
        .csvReader!Issue(null)
        .array
        .sort!((a, b) => a.id < b.id)
        .release;
}

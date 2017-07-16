module dlangbot.warnings;

import dlangbot.bugzilla : Issue, IssueRef;
import dlangbot.github : PullRequest;

import std.algorithm;

struct UserMessage
{
    enum Type { Error, Warning, Info }
    Type type;

    string text;
}


// check diff length
void checkDiff(in ref PullRequest pr, ref UserMessage[] msgs)
{
}


/**
Check bugzilla priority
- enhancement -> changelog entry
- regression/major -> stable
*/
void checkBugzilla(in ref PullRequest pr, ref UserMessage[] msgs,
        in Issue[] bugzillaIssues, in IssueRef[] refs)
{
    // check for stable
    if (pr.base.ref_ != "stable")
    {
        if (bugzillaIssues.any!(i => i.status.among("NEW", "ASSIGNED", "REOPENED") &&
                                     i.severity.among("critical", "major",
                                                      "blocker", "regression") &&
                                     refs.canFind!(r => r.id == i.id && r.fixed)))
        {
            msgs ~= UserMessage(UserMessage.Type.Warning,
                "Regression or critical bug fixes should always target the `stable` branch." ~
                " [Learn more](https://wiki.dlang.org/Starting_as_a_Contributor#Stable_Branch)");
        }
    }
}


UserMessage[] checkForWarnings(in PullRequest pr, in Issue[] bugzillaIssues, in IssueRef[] refs)
{
    UserMessage[] msgs;
    pr.checkDiff(msgs);
    pr.checkBugzilla(msgs, bugzillaIssues, refs);
    return msgs;
}

void printMessages(W)(W app, in UserMessage[] msgs)
{
    foreach (msg; msgs)
    {
        app ~= "- ";
        app ~= msg.text;
        app ~= "\n";
    }
}

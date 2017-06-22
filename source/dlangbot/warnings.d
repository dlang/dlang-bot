module dlangbot.warnings;

import dlangbot.bugzilla : Issue;
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
void checkBugzilla(in ref PullRequest pr, ref UserMessage[] msgs, in Issue[] bugzillaIssues)
{
    // check for stable
    if (pr.base.ref_ != "stable")
    {
        if (bugzillaIssues.any!(i => i.status.among("NEW", "ASSIGNED") &&
                                     i.severity.among("critical", "major",
                                                      "blocker", "regression")))
        {
            msgs ~= UserMessage(UserMessage.Type.Warning,
                "Regression fixes should always target stable");
        }
    }
}


UserMessage[] checkForWarnings(in PullRequest pr, in Issue[] bugzillaIssues)
{
    UserMessage[] msgs;
    pr.checkDiff(msgs);
    pr.checkBugzilla(msgs, bugzillaIssues);
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

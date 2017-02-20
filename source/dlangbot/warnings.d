module dlangbot.warnings;

import dlangbot.github : PullRequest;

struct UserMessage
{
    enum Type { Error, Warning, Info }

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
void checkBugzilla(in ref PullRequest pr, UserMessage[] msgs)
{
}


UserMessage[] checkForWarnings(in PullRequest pr)
{
    UserMessage[] msgs;
    pr.checkDiff(msgs);
    pr.checkBugzilla(msgs);
    return msgs;
}

void printMessages(W)(W app, UserMessage[] msgs)
{
    foreach (msg; msgs)
    {
        app ~= " - ";
        app ~= msg.text;
        app ~= "\n";
    }
}

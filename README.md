# Dlang-Bot

<img alt="dlang-bot" height="200px" src="public/img/dlang_bot.png" />

Features
--------

- [Automated bugzilla, github, and trello references](#automated-references)
- [Auto-merging approved & passing PRs](#auto-merge)
- [Canceling stale Travis-CI builds](#canceling-stale)


<a name="automated-references" />

Automated references
--------------------

For example let's say you fixed [Issue 16582](https://issues.dlang.org/show_bug.cgi?id=16582)
and make a PR for on GitHub.
If one of your commits mentions the issue, e.g. like this Git commit message:

```
fix Issue 16582 - ParameterDefaults fails w/ scope parameter
```

The Dlang-Bot will do all the hard work of linking and referencing
between Bugzilla, GitHub and Trello do for you.

### GitHub

It would comment on GitHub with list of all mentioned issues and link them to Bugzilla:

<img alt="dlang-bot-github" height="120px" src="public/img/dlang_bot_github_comment.png" />

The first column of the table is the current status of the referenced issue.

### Bugzilla

Once a PR has been merged (i.e. the commits got pushed to master or stable), the Dlang-Bot
will automatically comment to Bugzilla with the regarding commit:

<img alt="dlang-bot-bugzilla" height="120px" src="public/img/dlang_bot_bugzilla_comment.png" />

Of course it will also automatically close the references issues (at least if either
"fix", "close" or "address" occurs before the issue id).

Using this syntax is also very important because for the changelog generation, the
git history will be used. Thus _only_ if the Dlang-Bot has detected an issue
and commented on your PR it can become part of the changelog.

### Trello

For the [Trello board](https://trello.com/b/XoFjxiqG/active) it will also provide a
reference:

<img alt="dlang-bot-trello" height="120px" src="public/img/dlang_bot_trello_comment.png" />

And once a PR gets merged, the bot moves the linked Trello card to "Testing / Review".

### Nerdy details

- one can mention multiple issues in one commit and/or multiple commits
- the exact RegEx is:

```
((close|fix|address)e?(s|d)? )?(ticket|bug|tracker item|issue)s?:? *([\d ,\+&#and]+)
```

<a name="auto-merge" />

Auto-merge (WIP)
---------------

At the moment the Dlang-Bot support merging via special `auto-merge` and
`auto-merge-squash` labels. The later will perform a squashed merge of all commits
in the PR into a single one.

A reviewer can toggle a PR for "auto-merge" by simply adding the `auto-merge` label
(`auto-merge-squash` respectively).


### Nerdy details

- this relies on the "restricted branches" feature of GitHub (the Dlang-Bot will
send the attempt to merge to the GitHub API)
- once a new commit event occurs (push, synchronization) the Dlang-Bot will
automatically remove set all auto-merge labels from the PR
- for status events the GitHub API doesn't allow to get an information about the
- the Dlang-Bot will then try to restart the PR on every new event.
- concerning PR of the commit (thus all potential auto-merge PRs are checked)

_Note_: at the moment the Dlang-Bot doesn't store _any_ authentication token, so
it can't perform actions on behalf of others.

<a name="canceling-state" />

Canceling stale Travis-CI builds
--------------------------------

To avoid wasteful resource consumption with Travis CI,
the Dlang-Bot will automatically cancel the previous, possibly running build of
a PR on a new commit event (push or synchronization by a user).

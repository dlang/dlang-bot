/**
Implements a database to store the total number
of bugs fixed by a github account and their
associated severity.
*/
module dlangbot.database;

import ae.sys.database : Database;

private Database db;
private string[] severities = ["enhancement", "trivial", "minor",
            "normal", "major", "critical", "blocker", "regression"];
enum BugzillaFixedIssues_schema = q"SQL
CREATE TABLE [BugzillaFixedIssues] (
[IssueNumber]  INTEGER PRIMARY KEY NOT NULL,
[Severity] TEXT NOT NULL,
[GithubId] INTEGER NOT NULL,
[Time] INTEGER NOT NULL
);
CREATE TABLE [GithubNickname] (
[GithubId] INTEGER PRIMARY KEY NOT NULL,
[Name] TEXT NOT NULL
);
SQL";

/**
Checks whether a database file already exists.
If that is the case, it returns the database,
otherwise it creates it.
*/
private Database initDatabase(string databasePath)
{
    import std.file : exists;
    import ae.sys.file : ensurePathExists;

    version(unittest)
    {
        if (databasePath == ":memory:")
            return Database(databasePath, [BugzillaFixedIssues_schema,]);
    }

    if (databasePath.exists)
        return Database(databasePath, [BugzillaFixedIssues_schema,]);

    ensurePathExists(databasePath);
    return Database(databasePath, [BugzillaFixedIssues_schema,]);
}

Database getDatabase()
{
    return db;
}

void updateBugzillaFixedIssuesTable(string userName, ulong userId, int issueNumber, string severity)
{

    // Github usernames may change, therefore make sure that the most
    // recent nickname is inserted into the database. This will make
    // it easier to print the leaderboard.
    db.stmt!"
    INSERT OR REPLACE INTO [GithubNickname] ([GithubId], [Name]) VALUES (?, ?)"
    .exec(userId, userName);

    // Insert actual event - if an issue is reopened, the original author loses
    // the points. This should, normally, not happen, since the policy is to open
    // a new bug report in case an issue was partially fixed.
    db.stmt!"
    INSERT OR REPLACE INTO [BugzillaFixedIssues] ([IssueNumber], [Severity], [GithubId], [Time])
    VALUES (?, ?, ?, strftime('%s','now'))"
    .exec(issueNumber, severity, userId);
}

static this()
{
    version(unittest)
    {
        enum databasePath = ":memory:";
    }
    else
    {
        enum databasePath = "var/db.s3db";
    }
    db = initDatabase(databasePath);
}

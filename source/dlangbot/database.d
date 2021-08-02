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

/**
Inserts a new entry in the database for a fixed issue
*/
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

/**
Returns a string table that contains the contributor name
and its total points. The records are sorted by total points.
A sample of how the string matrix will look like:
[["John", "23"], ["Gigi", "12"], ["Mimi", "5"]].
*/
string[][] getContributorsStats()
{
    import std.conv : to;

    string[][] ret;

    // first, sum the points of each individual github id
    foreach(int gid, int points; db.stmt!"
            SELECT [GithubId], SUM(Points) AS [TotalPoints]
            FROM
            (SELECT [GithubId], CASE [Severity]
                WHEN \"enhancement\" THEN 10
                WHEN \"trivial\" THEN 10
                WHEN \"minor\" THEN 15
                WHEN \"normal\" THEN 20
                WHEN \"major\" THEN 50
                WHEN \"critical\" THEN 75
                WHEN \"blocker\" THEN 75
                WHEN \"regression\" THEN 100
            END AS [Points]
            FROM [BugzillaFixedIssues]
            )
            GROUP BY [GithubId]
            ORDER BY [TotalPoints] DESC;".iterate())
    {
        // then, get the human readable name of each github account
        // and construct the string table.
        string username;
        foreach(string name; db.stmt!"
                SELECT [Name] FROM [GithubNickname]
                WHERE [GithubId]=?".iterate(gid))
            username = name;

        ret ~= [username, to!string(points)];
    }

    return ret;
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

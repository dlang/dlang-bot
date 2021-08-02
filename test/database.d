import dlangbot.database;

@("database")
unittest
{
    auto db = getDatabase();

    auto user1 = "user1";
    auto user1_id = 1;
    auto user1_alias = "user1_alias";

    auto user2 = "user2";
    auto user2_id = 2;

    // simple insert
    updateBugzillaFixedIssuesTable(user1, user1_id, 1, "critical");
    foreach (int iss, string sev; db.stmt!"SELECT [IssueNumber], [Severity] FROM [BugzillaFixedIssues]
                                WHERE [GithubId]=?".iterate(user1_id))
    {
        assert(iss == 1);
        assert(sev == "critical");
    }

    // override issue
    updateBugzillaFixedIssuesTable(user1, user1_id, 1, "blocker");
    foreach (int iss, string sev; db.stmt!"SELECT [IssueNumber], [Severity] FROM [BugzillaFixedIssues]
                                WHERE [GithubId]=?".iterate(user1_id))
    {
        assert(iss == 1);
        assert(sev == "blocker");
    }

    // same user, different issue
    string[int] issues;
    updateBugzillaFixedIssuesTable(user1, user1_id, 2, "trivial");
    foreach (int iss, string sev; db.stmt!"SELECT [IssueNumber], [Severity] FROM [BugzillaFixedIssues]
                                WHERE [GithubId]=?".iterate(user1_id))
    {
        issues[iss] = sev;
    }
    assert(issues[1] == "blocker");
    assert(issues[2] == "trivial");
    issues.clear;

    // same user, different name
    updateBugzillaFixedIssuesTable(user1_alias, user1_id, 3, "major");
    foreach (int iss, string sev; db.stmt!"SELECT [IssueNumber], [Severity] FROM [BugzillaFixedIssues]
                                WHERE [GithubId]=?".iterate(user1_id))
    {
        issues[iss] = sev;
    }
    assert(issues[1] == "blocker");
    assert(issues[2] == "trivial");
    assert(issues[3] == "major");
    issues.clear;

    foreach (string name; db.stmt!"SELECT [Name] FROM [GithubNickname] WHERE [GithubId]=?".iterate(user1_id))
    {
        assert(name == user1_alias);
    }

    // different user, new issue
    int[int] issueAuthors;
    updateBugzillaFixedIssuesTable(user2, user2_id, 4, "regression");
    foreach (int iss, string sev, int user; db.stmt!"SELECT [IssueNumber], [Severity], [GithubId]
                                    FROM [BugzillaFixedIssues]".iterate())
    {
        issues[iss] = sev;
        issueAuthors[iss] = user;
    }
    assert(issues[1] == "blocker");
    assert(issues[2] == "trivial");
    assert(issues[3] == "major");
    assert(issues[4] == "regression");

    assert(issueAuthors[1] == user1_id);
    assert(issueAuthors[2] == user1_id);
    assert(issueAuthors[3] == user1_id);
    assert(issueAuthors[4] == user2_id);
    issues.clear;
    issueAuthors.clear;

    auto totalPoints = getContributorsStats();
    assert(totalPoints[0] == [user1_alias, "135"]);
    assert(totalPoints[1] == [user2, "100"]);
}

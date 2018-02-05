import utils;
import std.uri : encodeComponent;

@("tweet-on-a-merged-pr")
unittest
{
    twitterEnabled = true;
    scope(exit) twitterEnabled = false;

    string message = `dlang/phobos: PR #4963 "[DEMO for DIP1005] Converted imports to selective imports in std.array" from @andralex has been merged - https://github.com/dlang/phobos/pull/4963`.encodeComponent;
    setAPIExpectations(
        "/github/repos/dlang/phobos/pulls/4963/commits",
        "/github/repos/dlang/phobos/issues/4963/comments",
        "/twitter/statuses/update.json?status=" ~ message, (scope HTTPServerRequest req, scope HTTPServerResponse res) {
            auto auth = req.headers["Authorization"];
            assert(auth.startsWith("OAuth "));
        }
    );

    postGitHubHook("dlang_phobos_merged_4963.json");
}

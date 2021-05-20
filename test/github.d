import utils;

import dlangbot.github_api;

@("github-cache")
unittest
{
    setAPIExpectations(
		"/github/test",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
			res.headers["ETag"] = "pretty";
			res.headers["Last-Modified"] = "Fri, 13 Feb 2009 23:31:30 +0000";
            res.writeJsonBody("hello".Json);
        },
		"/github/test",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
			assert(req.headers["If-None-Match"] == "pretty");
			assert(req.headers["If-Modified-Since"] == "Fri, 13 Feb 2009 23:31:30 +0000");
            res.statusCode = 304;
        },
	);

    assert(ghGetRequest(githubAPIURL ~ "/test").body == "hello");
    assert(ghGetRequest(githubAPIURL ~ "/test").body == "hello");
}

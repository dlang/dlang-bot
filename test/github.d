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

@("github-multipage")
unittest
{
    setAPIExpectations(
        "/github/multipage-test",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            res.headers["Link"] =
				`<` ~ githubAPIURL ~ `/multipage-test?page=2>; rel="next", ` ~
				`<` ~ githubAPIURL ~ `/multipage-test?page=3>; rel="last"`;
            res.writeJsonBody("D".Json);
        },
        "/github/multipage-test?page=2",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            res.headers["Link"] =
				`<` ~ githubAPIURL ~ `/multipage-test?page=1>; rel="prev", ` ~
				`<` ~ githubAPIURL ~ `/multipage-test?page=3>; rel="next", ` ~
				`<` ~ githubAPIURL ~ `/multipage-test?page=3>; rel="last", ` ~
				`<` ~ githubAPIURL ~ `/multipage-test?page=1>; rel="first"`;
            res.writeJsonBody("is".Json);
        },
        "/github/multipage-test?page=3",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
            res.headers["Link"] =
				`<` ~ githubAPIURL ~ `/multipage-test?page=2>; rel="prev", ` ~
				`<` ~ githubAPIURL ~ `/multipage-test?page=1>; rel="first"`;
            res.writeJsonBody("awesome".Json);
        },
	);

    auto pages = ghGetAllPages(githubAPIURL ~ "/multipage-test");
	string result;
    foreach (page; pages)
		result ~= page.get!string;
	assert(result == "D" ~ "is" ~ "awesome");
}

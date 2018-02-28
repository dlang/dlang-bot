module dlangbot.twitter;

import vibe.core.log;
import vibe.http.common : HTTPMethod;

string twitterURL = "https://api.twitter.com/1.1";
bool twitterEnabled;

// send a tweet
void tweet(string message)
{
    OAuth.Parameters parameters;
    parameters["status"] = message;
    logInfo("Sending tweet: %s", message);
    scope res = twitterRequest("/statuses/update.json", parameters);
    //logInfo("Tweet sent: %d, %s", res.statusCode, res.statusPhrase);
}

// send a signed request with the Twitter API
auto twitterRequest(string path, OAuth.Parameters parameters, HTTPMethod method = HTTPMethod.POST)
{
    import vibe.http.client : requestHTTP;
    import vibe.stream.operations : readAllUTF8;
    import std.conv : to;

    string url = twitterURL ~ path;
    string queryString = oAuth.queryString(parameters);
    logDebug("Sending request to TwitterAPI: %s", queryString);

    scope res = requestHTTP(url ~ "?" ~ queryString, (scope req) {
        req.method = method;
        req.headers["Authorization"] = oAuth.requestHeader(url, method.to!string, parameters);
    });
    logInfo("%s %s, %s - %s\n", method, url, res.statusPhrase, res.bodyReader.readAllUTF8);
    return res;
}

OAuth oAuth;

// See: https://developer.twitter.com/en/docs/basics/authentication/guides/creating-a-signature
struct OAuth
{
    import vibe.utils.dictionarylist : DictionaryList;
    alias Parameters = DictionaryList!(string, true, 8);

    @("multi-value-sortedness-of-parameters")
    unittest
    {
        import std.array : array;
        import std.algorithm.sorting : sort;
        import std.algorithm.iteration : map;
        import std.typecons : tuple;

        Parameters params;
        params["foo"] = "bar";
        params.addField("foo", "1bar");
        params.addField("foo", "bar2");
        assert(params.byKeyValue.array.sort.release == [
            tuple("foo", "1bar"),
            tuple("foo", "bar"),
            tuple("foo", "bar2")
        ]);
    }

    struct Config
    {
        string consumerKey;
        string consumerKeySecret;
        string accessToken;
        string accessTokenSecret;
    }
    Config config;

    auto prepare(string url, string method, Parameters parameters)
    {
        import std.conv : to;
        import std.datetime.systime : Clock;
        Parameters oauthParams;
        oauthParams["oauth_consumer_key"] = config.consumerKey;
        oauthParams["oauth_token"] = config.accessToken;
        oauthParams["oauth_timestamp"] = Clock.currTime.toUnixTime.to!string;
        oauthParams["oauth_nonce"] = Clock.currTime.toUnixTime.to!string;
        oauthParams["oauth_version"] = "1.0";
        oauthParams["oauth_signature_method"] = "HMAC-SHA1";
        oauthParams["oauth_signature"] = sign(method, url, parameters,  oauthParams);
        return oauthParams;
    }

    // https://developer.twitter.com/en/docs/basics/authentication/guides/creating-a-signature
    string sign(string method, string requestUrl, Parameters[] parameters...)
    {
        import std.array : array;
        import std.algorithm.iteration : joiner, map;
        import std.algorithm.sorting : sort;
        import std.base64 : Base64;
        import std.conv : text;
        import std.digest.hmac : hmac;
        import std.digest.sha : SHA1;
        import std.range : chain;
        import std.string : representation;

        auto query = parameters.map!(a => a.byKeyValue.array)
                        .joiner
                        .array
                        .sort
                        .map!(a => chain(a.key.asEncoded, "=", a.value.asEncoded))
                        .joiner("&");

        auto url = text(method.asEncoded, "&", requestUrl.asEncoded, "&", query.asEncoded);
        auto key = text(config.consumerKeySecret.asEncoded, "&", config.accessTokenSecret.asEncoded);
        auto digest = hmac!SHA1(url.representation, key.representation);
        return Base64.encode(digest);
    }

    @("oauth-signature-check")
    unittest
    {
        // Example from https://dev.twitter.com/oauth/overview/creating-signatures
        OAuth session;
        session.config.consumerKeySecret = "kAcSOqF21Fu85e7zjz7ZN2U4ZRhfV3WpwPAoE3Z7kBw";
        session.config.accessTokenSecret = "LswwdoUaIvS8ltyTt5jkRh4J50vUPVVHtR2YPi5kE";

        Parameters pathParams, queryParams, oauthConfig;
        pathParams["include_entities"] = "true";
        queryParams["status"] = "Hello Ladies + Gentlemen, a signed OAuth request!";

        oauthConfig["oauth_consumer_key"] = "xvz1evFS4wEEPTGEFPHBog";
        oauthConfig["oauth_nonce"] = "kYjzVBB8Y0ZFabxSWbWovY3uYSQ2pTgmZeNu2VS4cg";
        oauthConfig["oauth_signature_method"] = "HMAC-SHA1";
        oauthConfig["oauth_timestamp"] = "1318622958";
        oauthConfig["oauth_token"] = "370773112-GmHxMAgYyLbNEtIKZeRNFsMKPR9EyMZeS9weJAEb";
        oauthConfig["oauth_version"] = "1.0";

        auto signature = session.sign("POST", "https://api.twitter.com/1/statuses/update.json", pathParams, queryParams, oauthConfig);
        assert(signature == "tnnArxj06cWHq44gCs1OSKk/jLY=");
    }

    // Converts OAuth parameters into a string suitable for the "Authorization" header.
    string makeHeader(Parameters oauthParams)
    {
        import std.algorithm.iteration : joiner, map;
        import std.conv : text;
        import std.range : chain;

        auto r = oauthParams.byKeyValue
                            .map!(a => chain(a.key, `="`, a.value.asEncoded, `"`))
                            .joiner(",");
        return "OAuth ".text(r);
    }

    auto requestHeader(string requestUrl, string method, Parameters parameters)
    {
        return makeHeader(prepare(requestUrl, method, parameters));
    }

    string queryString(Parameters params)
    {
        import std.array : join;
        import std.algorithm.iteration : map;
        return params.byKeyValue.map!(p => encode(p.key) ~ "=" ~ encode(p.value)).join("&");
    }
}

// https://developer.twitter.com/en/docs/basics/authentication/guides/percent-encoding-parameters.html
static string encode(S)(S s)
{
    import std.conv : to;
    return asEncoded(s).to!string;
}

static auto asEncoded(S)(S s)
{
    import std.ascii : isAlphaNum;
    import std.algorithm.comparison : among;
    import std.format : format;
    import std.algorithm.iteration : joiner, map;
    import std.range : choose, only;
    import std.utf : byCodeUnit;

    return s.byCodeUnit
            .map!(c => choose(c.isAlphaNum || c.among('-', '.', '_', '~'), c.only, format("%%%2X", c)))
            .joiner;
}

@("check-percentage-uri-encoding")
unittest
{
    assert(encode("Ladies + Gentlemen") == "Ladies%20%2B%20Gentlemen");
    assert(encode("An encoded string!") == "An%20encoded%20string%21");
    assert(encode("Dogs, Cats & Mice") == "Dogs%2C%20Cats%20%26%20Mice");
    assert(encode("☃") == "%E2%98%83");
}

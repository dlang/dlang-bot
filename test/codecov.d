import utils;

unittest
{
    setAPIExpectations(
        "/github/repos/dlang/druntime/statuses/d4015f4d403bd22ecee8b81bb61378d33e7df7df",
        (scope HTTPServerRequest req, scope HTTPServerResponse res){
        import std.stdio;
            assert(req.json["message"].get!string == "Total coverage: increased (+0.08)");
            assert(req.json["context"].get!string == "dlangbot/codecov");
            assert(req.json["state"].get!string == "success");
        }
    );
    postCodeCovHook("dlang_druntime_1877.json");
}

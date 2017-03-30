module dlangbot.utils;

import dlangbot.app : runAsync;

import std.datetime : Duration;

auto runTaskHelper(Fun, Args...)(Fun fun, auto ref Args args)
{
    import std.functional : toDelegate;
    import vibe.core.core : runTask;

    if (runAsync)
        runTask(fun.toDelegate, args);
    else
        return fun(args);
}

/**
Thottles subsequent calls to one per `throttleTime`.

-----
call(); // direct execution
call(); // will be executed in `throttleTime` (all further request will be ignored)
call(); // ignored
<wait>
call(); // direct execution
...
-----

*/
struct Throttler(Fun)
{
import std.typecons : Tuple;
import vibe.core.core : setTimer, Timer;
import std.datetime : Clock, SysTime;

private:
    import std.traits : Parameters;

    alias Args = Parameters!Fun;
    static struct ThrottleEntry
    {
        SysTime startedTime;
        Timer timer;
    }

    ThrottleEntry[Tuple!Args] timersPerArgs;

    Fun fun;
    Duration throttleTime;

public:
    this(Fun fun, Duration throttleTime)
    {
        this.fun = fun;
        this.throttleTime = throttleTime;
    }

    void reset()
    {
        foreach (entry; timersPerArgs)
            if (entry.timer)
                entry.timer.stop;

        // can't use clear due to 2.070 support
        timersPerArgs = null;
    }

    void opCall(Args args)
    {
        auto key = Tuple!Args(args);
        auto entry = key in timersPerArgs;

        // the first access fires directly
        if (entry is null)
        {
            ThrottleEntry ep = {
                startedTime: Clock.currTime,
            };
            timersPerArgs[key] = ep;
            return runTaskHelper(fun, args);
        }
        else
        {
            // stop if there's a pending timer -> ignore request
            if (entry.timer && entry.timer.pending)
                return;

            // depending on the time stamp of the last run,
            // run directly or start a timer
            if (entry.startedTime + throttleTime <= Clock.currTime)
                runTaskHelper(fun, args);
            else
                entry.timer = setTimer(throttleTime, { fun(args); });

            entry.startedTime = Clock.currTime;
        }
    }
}

unittest
{
    int[string] cDict;
    void count(string key)
    {
        cDict[key]++;
    }

    import core.thread : Thread;
    import std.datetime : msecs;
    import vibe.core.core : setTimer;

    auto throttleTime = 1.msecs;
    auto throttler = Throttler!(typeof(&count))(&count, throttleTime);

    // now no timers are running -> immediate call
    throttler("A");
    throttler("B");

    // there was a call before -> timer set
    throttler("A");
    throttler("B");

    // now timers are running -> ignored
    throttler("A");
    throttler("B");

    // we got throttled and need to wait
    assert(cDict == ["A": 1, "B": 1]);
    setTimer(throttleTime * 2, () {
        assert(cDict == ["A": 2, "B": 2]);

        // now no timers are running -> immediate call
        throttler("A");
        throttler("B");
        assert(cDict == ["A": 3, "B": 3]);

        // now timers are running -> delayed
        throttler("A");
        throttler("B");
        assert(cDict == ["A": 3, "B": 3]);
    });
}

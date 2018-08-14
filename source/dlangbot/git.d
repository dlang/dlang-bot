module dlangbot.git;

import std.conv, std.file, std.path, std.string, std.uuid;
import std.format, std.stdio;

import dlangbot.github;
import vibe.core.log;

string gitURL = "http://0.0.0.0:9006";

import std.process : Pid, ProcessPipes;

auto asyncWait(ProcessPipes p)
{
    import core.sys.posix.fcntl;
    import core.time : seconds;
    import std.process : tryWait;
    import vibe.core.core : createFileDescriptorEvent, FileDescriptorEvent;

    fcntl(p.stdout.fileno, F_SETFL, O_NONBLOCK);
    scope readEvt = createFileDescriptorEvent(p.stdout.fileno, FileDescriptorEvent.Trigger.read);
    while (readEvt.wait(5.seconds, FileDescriptorEvent.Trigger.read))
    {
        auto rc = tryWait(p.pid);
        if (rc.terminated)
            break;
    }
}

auto asyncWait(Pid pid)
{
    import core.time : msecs;
    import std.process : tryWait;
    import vibe.core.core : sleep;

    for (auto rc = pid.tryWait; !rc.terminated; rc = pid.tryWait)
        5.msecs.sleep;
}

void rebase(PullRequest* pr)
{
    import std.process;
    auto uniqDir = tempDir.buildPath("dlang-bot-git", randomUUID.to!string.replace("-", ""));
    uniqDir.mkdirRecurse;
    scope(exit) uniqDir.rmdirRecurse;
    const git = "git -C %s ".format(uniqDir);

    auto targetBranch = pr.base.ref_;
    auto remoteDir = pr.repoURL;

    logInfo("[git/%s]: cloning branch %s...", pr.repoSlug, targetBranch);
    auto pid = spawnShell("git clone -b %s %s %s".format(targetBranch, remoteDir, uniqDir));
    pid.asyncWait;

    logInfo("[git/%s]: fetching repo...", pr.repoSlug);
    pid = spawnShell(git ~ "fetch origin pull/%s/head:pr-%1$s".format(pr.number));
    pid.asyncWait;
    logInfo("[git/%s]: switching to PR branch...", pr.repoSlug);
    pid = spawnShell(git ~ "checkout pr-%s".format(pr.number));
    pid.asyncWait;
    logInfo("[git/%s]: rebasing...", pr.repoSlug);
    pid = spawnShell(git ~ "rebase " ~ targetBranch);
    pid.asyncWait;

    auto headSlug = pr.head.repo.fullName;
    auto headRef = pr.head.ref_;
    auto sep = gitURL.startsWith("http") ? "/" : ":";
    logInfo("[git/%s]: pushing... to %s", pr.repoSlug, gitURL);

    // TODO: use --force here
    auto cmd = "git push -vv %s%s%s HEAD:%s".format(gitURL, sep, headSlug, headRef);
    pid = spawnShell(cmd);
    pid.asyncWait;
}

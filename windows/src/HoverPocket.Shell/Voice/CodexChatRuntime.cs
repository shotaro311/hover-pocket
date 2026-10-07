namespace HoverPocket.Shell.Voice;

internal static class CodexChatRuntime
{
    public static CodexChatCoordinator Create(string profileRoot, ICodexVoiceDynamicToolRuntime tools) => new(
        async token =>
        {
            var identity = CodexExecutableResolver.Resolve() ?? throw new CodexAppServerProtocolException("codex_executable_missing");
            await CodexVoiceToolRouteProbe.VerifyAsync(identity, tools.Definitions, Path.Combine(profileRoot, "RouteChecks"), token);
            var profile = CodexVoiceProfile.Prepare(profileRoot, reuseExistingLogin: false);
            using var executableLease = identity.OpenValidated();
            return await CodexAppServerClient.StartProcessAsync(identity.Path, ["app-server", "--stdio"],
                TimeSpan.FromSeconds(25), token, profile.Environment, profile.Root);
        }, tools, new CodexChatHistory(profileRoot));
}

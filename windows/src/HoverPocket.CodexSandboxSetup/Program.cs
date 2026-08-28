namespace HoverPocket.CodexSandboxSetup;

internal static class Program
{
    private const int ContractFailureExitCode = 20;
    private const int SetupUnavailableExitCode = 21;

    private static int Main(string[] args)
    {
        try
        {
            if (args.Length == 1
                && string.Equals(args[0], "--contract-self-test", StringComparison.Ordinal))
            {
                ContractSelfTest.Run();
                Console.WriteLine("PASS Codex sandbox helper contract");
                return 0;
            }

            if (args.Length == 2
                && string.Equals(args[0], "--verify-vendor-closure", StringComparison.Ordinal))
            {
                VendorClosureVerifier.Verify(args[1]);
                Console.WriteLine("PASS Codex 0.145.0 vendor closure");
                return 0;
            }

            if (args.Length == 6
                && string.Equals(args[0], "--admission-readback", StringComparison.Ordinal)
                && string.Equals(args[2], "--request-sha256", StringComparison.Ordinal)
                && string.Equals(args[4], "--nonce", StringComparison.Ordinal))
            {
                using var admitted = SetupRequestAdmission.Admit(
                    args[1],
                    args[3],
                    args[5],
                    DateTimeOffset.UtcNow);
                Console.WriteLine("PASS Codex sandbox setup request admission");
                return 0;
            }

            Console.Error.WriteLine("HP_CODEX_SANDBOX_HELPER_NOT_ACTIVATED");
            return SetupUnavailableExitCode;
        }
        catch (Exception exception)
        {
            var code = exception.Message.StartsWith(
                "HP_CODEX_SANDBOX_",
                StringComparison.Ordinal)
                ? exception.Message
                : "HP_CODEX_SANDBOX_HELPER_CONTRACT_FAILED";
            Console.Error.WriteLine(code);
            return ContractFailureExitCode;
        }
    }
}

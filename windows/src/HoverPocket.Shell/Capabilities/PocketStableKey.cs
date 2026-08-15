using System.Text;
using System.Text.RegularExpressions;

namespace HoverPocket.Shell.Capabilities;

internal static partial class PocketStableKey
{
    public const int MaximumScalars = 96;

    [GeneratedRegex("\\A[a-z][a-z0-9-]{0,31}\\z", RegexOptions.CultureInvariant)]
    private static partial Regex NamespacePattern();

    [GeneratedRegex("\\A[A-Za-z0-9][A-Za-z0-9._-]{0,62}\\z", RegexOptions.CultureInvariant)]
    private static partial Regex KeyPattern();

    public static string Validate(string value)
    {
        if (value.EnumerateRunes().Count() > MaximumScalars
            || value.Any(character => character > 0x7f))
        {
            throw new CapabilityBrokerException("CAPABILITY_PLAN_INVALID", "stable_key");
        }

        var separator = value.IndexOf(':');
        if (separator <= 0 || separator != value.LastIndexOf(':') || separator == value.Length - 1)
        {
            throw new CapabilityBrokerException("CAPABILITY_PLAN_INVALID", "stable_key");
        }

        var @namespace = value[..separator];
        var key = value[(separator + 1)..];
        if (!NamespacePattern().IsMatch(@namespace) || !KeyPattern().IsMatch(key))
        {
            throw new CapabilityBrokerException("CAPABILITY_PLAN_INVALID", "stable_key");
        }
        return value;
    }

    public static string Namespace(string value)
    {
        _ = Validate(value);
        return value[..value.IndexOf(':')];
    }
}

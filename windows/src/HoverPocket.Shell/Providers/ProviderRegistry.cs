namespace HoverPocket.Shell.Providers;

internal sealed class ProviderRegistry
{
    private readonly IReadOnlyList<ProviderDescriptor> _providers;

    private ProviderRegistry(IReadOnlyList<ProviderDescriptor> providers)
    {
        _providers = providers;
    }

    public IReadOnlyList<ProviderDescriptor> Providers => _providers;

    public IReadOnlyList<string> ProviderIds => _providers.Select(provider => provider.Id).ToArray();

    public static ProviderRegistry CreateDefault()
    {
        return new ProviderRegistry(
        [
            new ProviderDescriptor(
                "calculator",
                "Calculator",
                "calculator",
                "Placeholder provider",
                "Calculator UI is reserved for W5. The bridge already switches this provider state."),
            new ProviderDescriptor(
                "timer",
                "Timer",
                "timer",
                "Placeholder provider",
                "Timer UI is reserved for W5. Settings and provider switching already persist through C#."),
            new ProviderDescriptor(
                "sticky",
                "Sticky Notes",
                "note",
                "Placeholder provider",
                "Sticky Notes UI is reserved for W6. This slot proves the shared WebView shell.")
        ]);
    }

    public ProviderDescriptor? Find(string id)
    {
        return _providers.FirstOrDefault(provider => string.Equals(provider.Id, id, StringComparison.OrdinalIgnoreCase));
    }
}

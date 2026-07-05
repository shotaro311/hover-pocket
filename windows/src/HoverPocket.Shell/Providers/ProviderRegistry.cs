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
                "Decimal calculator",
                "Four operations, decimal input, percent, sign toggle, backspace, AC, and copy."),
            new ProviderDescriptor(
                "timer",
                "Timer",
                "timer",
                "Timer and Pomodoro",
                "Run up to two timers, pin up to four presets, pause, resume, stop, and restore state."),
            new ProviderDescriptor(
                "sticky",
                "Sticky Notes",
                "note",
                "Board grid provider",
                "Create, edit, color, reorder, archive, delete, undo, and drag notes.")
        ]);
    }

    public ProviderDescriptor? Find(string id)
    {
        return _providers.FirstOrDefault(provider => string.Equals(provider.Id, id, StringComparison.OrdinalIgnoreCase));
    }
}

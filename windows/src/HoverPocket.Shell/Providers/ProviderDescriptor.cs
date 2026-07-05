namespace HoverPocket.Shell.Providers;

internal sealed record ProviderDescriptor(
    string Id,
    string Title,
    string Icon,
    string Summary,
    string Body,
    bool DefaultVisible = true);

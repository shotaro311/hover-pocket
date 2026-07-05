namespace HoverPocket.Shell.Settings;

internal sealed class InMemoryStartupRegistrationService : IStartupRegistrationService
{
    public bool Registered { get; private set; }

    public bool IsRegistered()
    {
        return Registered;
    }

    public void SetRegistered(bool enabled)
    {
        Registered = enabled;
    }
}

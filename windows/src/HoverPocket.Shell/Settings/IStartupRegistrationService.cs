namespace HoverPocket.Shell.Settings;

internal interface IStartupRegistrationService
{
    bool IsRegistered();

    void SetRegistered(bool enabled);
}

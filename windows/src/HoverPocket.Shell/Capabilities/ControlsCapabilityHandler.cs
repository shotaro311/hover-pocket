using System.Text.Json;
using HoverPocket.Shell.Providers.Controls;

namespace HoverPocket.Shell.Capabilities;

internal interface IControlsCapabilityDataSource
{
    Task<ControlsSnapshot> GetSnapshotAsync(CancellationToken cancellationToken);
    Task<ControlsSnapshot> SetVolumeAsync(int value, CancellationToken cancellationToken);
    Task<ControlsSnapshot> SetMutedAsync(bool muted, CancellationToken cancellationToken);
    Task<ControlsSnapshot> SetBrightnessAsync(string displayId, int value, CancellationToken cancellationToken);
    Task<ControlsSnapshot> ExecuteMediaCommandAsync(string command, CancellationToken cancellationToken);
}

internal sealed class UnavailableControlsCapabilityDataSource : IControlsCapabilityDataSource
{
    private static ControlsSnapshot Snapshot() => new(
        [],
        new VolumeState(false, 0, false),
        MediaSessionState.Empty(),
        MediaPreviewState.Inactive,
        DateTimeOffset.UtcNow);

    public Task<ControlsSnapshot> GetSnapshotAsync(CancellationToken cancellationToken) =>
        Task.FromResult(Snapshot());

    public Task<ControlsSnapshot> SetVolumeAsync(int value, CancellationToken cancellationToken) =>
        Task.FromResult(Snapshot());

    public Task<ControlsSnapshot> SetMutedAsync(bool muted, CancellationToken cancellationToken) =>
        Task.FromResult(Snapshot());

    public Task<ControlsSnapshot> SetBrightnessAsync(string displayId, int value, CancellationToken cancellationToken) =>
        Task.FromResult(Snapshot());

    public Task<ControlsSnapshot> ExecuteMediaCommandAsync(string command, CancellationToken cancellationToken) =>
        Task.FromResult(Snapshot());
}

internal sealed class LiveControlsCapabilityDataSource(ControlsBridgeController controller) : IControlsCapabilityDataSource
{
    public Task<ControlsSnapshot> GetSnapshotAsync(CancellationToken cancellationToken) =>
        controller.GetSnapshotAsync(cancellationToken);

    public Task<ControlsSnapshot> SetVolumeAsync(int value, CancellationToken cancellationToken) =>
        controller.SetVolumeAsync(value, cancellationToken);

    public async Task<ControlsSnapshot> SetMutedAsync(bool muted, CancellationToken cancellationToken)
        => await controller.SetMutedAsync(muted, cancellationToken);

    public Task<ControlsSnapshot> SetBrightnessAsync(string displayId, int value, CancellationToken cancellationToken) =>
        controller.SetBrightnessAsync(displayId, value, cancellationToken);

    public Task<ControlsSnapshot> ExecuteMediaCommandAsync(string command, CancellationToken cancellationToken) =>
        controller.ExecuteMediaCommandAsync(command switch
        {
            "play_pause" => "playPause",
            "next" => "next",
            "previous" => "previous",
            _ => throw new CapabilityHandlerException("CAPABILITY_ARGUMENT_INVALID", "command")
        }, null, cancellationToken);
}

internal enum ControlsCapabilityOperation
{
    Availability,
    VolumeGet,
    VolumeSet,
    MuteSet,
    BrightnessSet,
    MediaCommand
}

internal sealed class ControlsCapabilityHandler(
    ControlsCapabilityOperation operation,
    IControlsCapabilityDataSource dataSource) : IPocketCapabilityHandler
{
    public PocketCapabilityKey Key => operation switch
    {
        ControlsCapabilityOperation.Availability => CapabilityIds.ControlsAvailability,
        ControlsCapabilityOperation.VolumeGet => CapabilityIds.ControlsVolumeGet,
        ControlsCapabilityOperation.VolumeSet => CapabilityIds.ControlsVolumeSet,
        ControlsCapabilityOperation.MuteSet => CapabilityIds.ControlsMuteSet,
        ControlsCapabilityOperation.BrightnessSet => CapabilityIds.ControlsBrightnessSet,
        ControlsCapabilityOperation.MediaCommand => CapabilityIds.ControlsMediaCommand,
        _ => throw new InvalidOperationException("Unknown Controls Capability operation.")
    };

    public async Task<JsonElement> HandleAsync(
        JsonElement arguments,
        CapabilityHandlerContext context,
        CancellationToken cancellationToken = default)
    {
        if (operation is not (ControlsCapabilityOperation.Availability or ControlsCapabilityOperation.VolumeGet))
        {
            _ = context.RequireIdempotencyKey();
        }

        switch (operation)
        {
            case ControlsCapabilityOperation.Availability:
                RequireEmpty(arguments);
                return AvailabilityOutput(await dataSource.GetSnapshotAsync(cancellationToken));
            case ControlsCapabilityOperation.VolumeGet:
                RequireEmpty(arguments);
                return VolumeOutput(RequireVolume(await dataSource.GetSnapshotAsync(cancellationToken)));
            case ControlsCapabilityOperation.VolumeSet:
            {
                var target = CapabilityJson.RequiredNumber(arguments, "level", 0, 1);
                var before = RequireVolume(await dataSource.GetSnapshotAsync(cancellationToken));
                var snapshot = await dataSource.SetVolumeAsync(
                    (int)Math.Round(target * 100, MidpointRounding.AwayFromZero),
                    cancellationToken);
                var observed = RequireVolume(snapshot);
                if (Math.Abs(observed.Value / 100d - target) > 0.02 || observed.Muted != before.Muted)
                {
                    throw new CapabilityHandlerException("CAPABILITY_READBACK_MISMATCH", "controls.volume");
                }
                return VolumeOutput(observed);
            }
            case ControlsCapabilityOperation.MuteSet:
            {
                var muted = CapabilityJson.RequiredBool(arguments, "muted");
                var observed = RequireVolume(await dataSource.SetMutedAsync(muted, cancellationToken));
                if (observed.Muted != muted)
                {
                    throw new CapabilityHandlerException("CAPABILITY_READBACK_MISMATCH", "controls.mute");
                }
                return VolumeOutput(observed);
            }
            case ControlsCapabilityOperation.BrightnessSet:
            {
                var displayId = CapabilityJson.RequiredString(arguments, "displayId", 128);
                var target = CapabilityJson.RequiredNumber(arguments, "level", 0.05, 1);
                var snapshot = await dataSource.SetBrightnessAsync(
                    displayId,
                    (int)Math.Round(target * 100, MidpointRounding.AwayFromZero),
                    cancellationToken);
                var observed = snapshot.Displays.FirstOrDefault(display =>
                    string.Equals(display.Id, displayId, StringComparison.Ordinal));
                if (observed is null || !observed.Supported || observed.Value is null)
                {
                    throw new CapabilityHandlerException("CAPABILITY_UNAVAILABLE", "controls.display");
                }
                if (observed.WriteVerified != true || Math.Abs(observed.Value.Value / 100d - target) > 0.03)
                {
                    throw new CapabilityHandlerException("CAPABILITY_READBACK_MISMATCH", "controls.brightness");
                }
                return BrightnessOutput(observed);
            }
            case ControlsCapabilityOperation.MediaCommand:
            {
                var command = CapabilityJson.RequiredString(arguments, "command", 16);
                if (command is not ("play_pause" or "next" or "previous"))
                {
                    throw CapabilityJson.Invalid("command");
                }
                var before = await dataSource.GetSnapshotAsync(cancellationToken);
                if (!before.Media.Available)
                {
                    throw new CapabilityHandlerException("CAPABILITY_UNAVAILABLE", "controls.media");
                }
                var observed = await dataSource.ExecuteMediaCommandAsync(command, cancellationToken);
                if (!observed.Media.Available || !MediaChanged(command, before.Media, observed.Media))
                {
                    throw new CapabilityHandlerException("CAPABILITY_READBACK_MISMATCH", "controls.media");
                }
                return MediaOutput(command, observed.Media);
            }
            default:
                throw new CapabilityHandlerException("CAPABILITY_UNAVAILABLE", "controls.operation");
        }
    }

    private static void RequireEmpty(JsonElement arguments)
    {
        if (arguments.ValueKind != JsonValueKind.Object || arguments.EnumerateObject().Any())
        {
            throw CapabilityJson.Invalid("arguments");
        }
    }

    private static VolumeState RequireVolume(ControlsSnapshot snapshot) =>
        snapshot.Volume.Available
            ? snapshot.Volume
            : throw new CapabilityHandlerException("CAPABILITY_UNAVAILABLE", "controls.volume");

    private static bool MediaChanged(string command, MediaSessionState before, MediaSessionState observed) =>
        command == "play_pause"
            ? observed.IsPlaying != before.IsPlaying
            : !string.Equals(observed.Title, before.Title, StringComparison.Ordinal);

    private static JsonElement AvailabilityOutput(ControlsSnapshot snapshot) => CapabilityJson.From(new
    {
        volumeAvailable = snapshot.Volume.Available,
        brightnessAvailable = snapshot.Displays.Any(display => display.Supported && display.Value is not null),
        mediaAvailable = snapshot.Media.Available,
        displayIds = snapshot.Displays
            .Where(display => display.Supported && display.Value is not null)
            .Select(display => CapabilityJson.OutputString(display.Id, 128, "controls.displayId"))
            .Take(16)
            .ToArray()
    });

    private static JsonElement VolumeOutput(VolumeState state) => CapabilityJson.From(new
    {
        level = Math.Clamp(state.Value / 100d, 0, 1),
        muted = state.Muted
    });

    private static JsonElement BrightnessOutput(DisplayBrightnessState display) => CapabilityJson.From(new
    {
        displayId = CapabilityJson.OutputString(display.Id, 128, "controls.displayId"),
        level = Math.Clamp((display.Value ?? 0) / 100d, 0, 1),
        controllable = display.Supported
    });

    private static JsonElement MediaOutput(string command, MediaSessionState media) => CapabilityJson.From(new
    {
        command,
        available = media.Available,
        isPlaying = media.IsPlaying,
        safeTitle = CapabilityJson.OutputString(media.Title, 160, "controls.title", allowEmpty: true),
        safeSource = CapabilityJson.OutputString(media.Source, 120, "controls.source", allowEmpty: true)
    });
}

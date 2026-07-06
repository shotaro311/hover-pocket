using System.Text.Json;
using System.Windows;
using HoverPocket.Shell.Bridge;
using HoverPocket.Shell.Configuration;
using WpfDragDrop = System.Windows.DragDrop;
using WpfDragDropEffects = System.Windows.DragDropEffects;

namespace HoverPocket.Shell.Providers.Clipboard;

internal sealed class ClipboardBridgeController : IDisposable
{
    private readonly ClipboardHistoryStore _store;
    private readonly IClipboardMonitor _monitor;
    private readonly Func<UserSettings> _settingsProvider;
    private readonly Func<bool, CancellationToken, Task<object?>> _setPrivateModeAsync;
    private readonly Func<bool> _providerVisibleProvider;
    private bool _disposed;
    private bool _providerVisible;
    private bool _privateMode;

    public ClipboardBridgeController(
        ClipboardHistoryStore store,
        IClipboardMonitor monitor,
        Func<UserSettings> settingsProvider,
        Func<bool, CancellationToken, Task<object?>> setPrivateModeAsync,
        Func<bool> providerVisibleProvider)
    {
        _store = store;
        _monitor = monitor;
        _settingsProvider = settingsProvider;
        _setPrivateModeAsync = setPrivateModeAsync;
        _providerVisibleProvider = providerVisibleProvider;
        _monitor.ClipboardUpdated += OnClipboardUpdated;
    }

    public event EventHandler? ExternalDragStarted;

    public void Attach(BridgeDispatcher dispatcher)
    {
        dispatcher.Register("clipboard.getState", (_, _) => Task.FromResult<object?>(BuildState()));
        dispatcher.Register("clipboard.copyText", CopyTextAsync);
        dispatcher.Register("clipboard.copyImage", CopyImageAsync);
        dispatcher.Register("clipboard.clear", ClearAsync);
        dispatcher.Register("clipboard.toggleFavorite", ToggleFavoriteAsync);
        dispatcher.Register("clipboard.deleteItem", DeleteItemAsync);
        dispatcher.Register("clipboard.setPrivateMode", SetPrivateModeAsync);
        dispatcher.Register("clipboard.startExternalDrag", StartExternalDragAsync);
    }

    public void ApplySettings(UserSettings settings, bool providerVisible)
    {
        _providerVisible = providerVisible;
        _privateMode = settings.ClipboardPrivateMode;
        if (_providerVisible && !_privateMode)
        {
            try
            {
                _monitor.Start();
                _store.CaptureCurrentClipboard("monitor-start");
            }
            catch (InvalidOperationException)
            {
                _store.SetLastError("Clipboard listener could not be started.");
                _monitor.Stop();
            }

            return;
        }

        _monitor.Stop();
    }

    public object BuildState()
    {
        return _store.BuildState(
            _monitor.IsListening,
            _settingsProvider().ClipboardPrivateMode,
            _providerVisibleProvider());
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _monitor.ClipboardUpdated -= OnClipboardUpdated;
        _monitor.Dispose();
    }

    private Task<object?> CopyTextAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult<object?>(new
        {
            copied = _store.CopyText(ReadRequiredGuid(parameters, "id")),
            state = BuildState()
        });
    }

    private Task<object?> CopyImageAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult<object?>(new
        {
            copied = _store.CopyImage(ReadRequiredGuid(parameters, "id")),
            state = BuildState()
        });
    }

    private Task<object?> ClearAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        _ = parameters;
        cancellationToken.ThrowIfCancellationRequested();
        _store.Clear();
        return Task.FromResult<object?>(BuildState());
    }

    private Task<object?> ToggleFavoriteAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult<object?>(new
        {
            updated = _store.ToggleFavorite(
                ParseKind(ReadRequiredString(parameters, "kind")),
                ReadRequiredGuid(parameters, "id")),
            state = BuildState()
        });
    }

    private Task<object?> DeleteItemAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult<object?>(new
        {
            deleted = _store.DeleteItem(
                ParseKind(ReadRequiredString(parameters, "kind")),
                ReadRequiredGuid(parameters, "id")),
            state = BuildState()
        });
    }

    private Task<object?> SetPrivateModeAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        return SetPrivateModeAndReturnClipboardStateAsync(ReadRequiredBool(parameters, "enabled"), cancellationToken);
    }

    private async Task<object?> SetPrivateModeAndReturnClipboardStateAsync(bool enabled, CancellationToken cancellationToken)
    {
        await _setPrivateModeAsync(enabled, cancellationToken);
        return BuildState();
    }

    private Task<object?> StartExternalDragAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var kind = ParseKind(ReadRequiredString(parameters, "kind"));
        var id = ReadRequiredGuid(parameters, "id");
        var data = _store.BuildDragDataObject(kind, id);
        if (data is null)
        {
            return Task.FromResult<object?>(new { started = false, reason = "missing-item" });
        }

        var effect = StartDrag(data);
        return Task.FromResult<object?>(new
        {
            started = effect != WpfDragDropEffects.None,
            effect = effect.ToString()
        });
    }

    private WpfDragDropEffects StartDrag(System.Windows.DataObject data)
    {
        var app = System.Windows.Application.Current;
        if (app is null)
        {
            return WpfDragDropEffects.None;
        }

        if (!app.Dispatcher.CheckAccess())
        {
            return app.Dispatcher.Invoke(() => StartDrag(data));
        }

        var source = ResolveDragSource(app);
        if (source is null)
        {
            return WpfDragDropEffects.None;
        }

        ExternalDragStarted?.Invoke(this, EventArgs.Empty);
        return WpfDragDrop.DoDragDrop(source, data, WpfDragDropEffects.Copy);
    }

    private static DependencyObject? ResolveDragSource(System.Windows.Application app)
    {
        return app.Windows
            .OfType<Window>()
            .FirstOrDefault(window => window.IsVisible)
            ?? app.MainWindow;
    }

    private void OnClipboardUpdated(object? sender, EventArgs e)
    {
        _ = sender;
        _ = e;
        if (_disposed || !_providerVisible || _privateMode)
        {
            return;
        }

        _store.CaptureCurrentClipboard("WM_CLIPBOARDUPDATE");
    }

    private static ClipboardHistoryItemKind ParseKind(string value)
    {
        return value.Equals("image", StringComparison.OrdinalIgnoreCase)
            ? ClipboardHistoryItemKind.Image
            : ClipboardHistoryItemKind.Text;
    }

    private static Guid ReadRequiredGuid(JsonElement? parameters, string propertyName)
    {
        var value = ReadRequiredString(parameters, propertyName);
        if (Guid.TryParse(value, out var parsed))
        {
            return parsed;
        }

        throw new InvalidOperationException($"Missing guid parameter: {propertyName}");
    }

    private static string ReadRequiredString(JsonElement? parameters, string propertyName)
    {
        if (parameters is null
            || !parameters.Value.TryGetProperty(propertyName, out var property)
            || property.ValueKind != JsonValueKind.String)
        {
            throw new InvalidOperationException($"Missing string parameter: {propertyName}");
        }

        return property.GetString() ?? string.Empty;
    }

    private static bool ReadRequiredBool(JsonElement? parameters, string propertyName)
    {
        if (parameters is null
            || !parameters.Value.TryGetProperty(propertyName, out var property)
            || property.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
        {
            throw new InvalidOperationException($"Missing bool parameter: {propertyName}");
        }

        return property.GetBoolean();
    }
}

namespace HoverPocket.Shell.Providers.Assets;

internal sealed class AssetPlaybackOwner
{
    private AssetPaneController? _active;
    public void Claim(AssetPaneController pane)
    {
        if (_active is { } previous && !ReferenceEquals(previous, pane)) previous.EndPreview();
        _active = pane;
    }
    public void Release(AssetPaneController pane) { if (ReferenceEquals(_active, pane)) _active = null; }
}

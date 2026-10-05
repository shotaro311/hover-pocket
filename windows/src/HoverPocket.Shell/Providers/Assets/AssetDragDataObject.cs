using HoverPocket.Assets;
using DataFormats = System.Windows.DataFormats;
using IDataObject = System.Windows.IDataObject;

namespace HoverPocket.Shell.Providers.Assets;

// OLE asks for file paths only when an external consumer needs them. Internal targets use the marker.
internal sealed class AssetDragDataObject(AssetStore store, string[] ids, string token) : IDataObject
{
    internal const string Marker = "HoverPocket.AssetDrag";
    private string[]? _copies;
    public object GetData(string format, bool autoConvert)
    {
        if (format == Marker) return token;
        if (format == DataFormats.FileDrop)
            return _copies ??= Task.Run(async () =>
            {
                var paths = new List<string>();
                foreach (var id in ids) paths.Add(await store.CopyOutAsync(id));
                return paths.ToArray();
            }).GetAwaiter().GetResult();
        return null!;
    }
    public object GetData(string format) => GetData(format, false);
    public object GetData(Type format) => GetData(format.FullName!);
    public bool GetDataPresent(string format, bool autoConvert) => format == Marker || format == DataFormats.FileDrop;
    public bool GetDataPresent(string format) => GetDataPresent(format, false);
    public bool GetDataPresent(Type format) => GetDataPresent(format.FullName!);
    public string[] GetFormats(bool autoConvert) => [Marker, DataFormats.FileDrop];
    public string[] GetFormats() => GetFormats(false);
    public void SetData(string format, object data, bool autoConvert) => throw new NotSupportedException();
    public void SetData(string format, object data) => throw new NotSupportedException();
    public void SetData(Type format, object data) => throw new NotSupportedException();
    public void SetData(object data) => throw new NotSupportedException();
}

using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using HoverPocket.Shell.Providers.Assets;

namespace HoverPocket.Shell.Verification;

[ComVisible(true), ClassInterface(ClassInterfaceType.None)]
internal sealed class VirtualFileDropFixture : System.Runtime.InteropServices.ComTypes.IDataObject
{
    internal readonly (string Name, byte[] Bytes)[] Files = [("仮想ファイル1.txt", Encoding.UTF8.GetBytes("Generated virtual first")), ("仮想ファイル2.txt", Encoding.UTF8.GetBytes("Generated virtual second"))];
    public void GetData(ref FORMATETC format, out STGMEDIUM medium)
    {
        byte[] bytes;
        if (format.cfFormat == AssetDropPayload.Format("FileGroupDescriptorW").cfFormat)
        {
            bytes = new byte[4 + Files.Length * 592]; BitConverter.GetBytes(Files.Length).CopyTo(bytes, 0);
            for (var i = 0; i < Files.Length; i++) { var start = 4 + i * 592; BitConverter.GetBytes(0x44u).CopyTo(bytes, start); BitConverter.GetBytes(0x80u).CopyTo(bytes, start + 36); BitConverter.GetBytes(Files[i].Bytes.Length).CopyTo(bytes, start + 68); Encoding.Unicode.GetBytes(Files[i].Name).CopyTo(bytes, start + 72); }
        }
        else if (format.cfFormat == AssetDropPayload.Format("FileContents").cfFormat && format.lindex >= 0 && format.lindex < Files.Length) bytes = Files[format.lindex].Bytes;
        else throw new COMException("unsupported fixture format", unchecked((int)0x80040064));
        var handle = GlobalAlloc(2, (nuint)bytes.Length); if (handle == 0) throw new OutOfMemoryException();
        var pointer = GlobalLock(handle); Marshal.Copy(bytes, 0, pointer, bytes.Length); GlobalUnlock(handle);
        medium = new STGMEDIUM { tymed = TYMED.TYMED_HGLOBAL, unionmember = handle, pUnkForRelease = null };
    }
    public int QueryGetData(ref FORMATETC format) => format.cfFormat == AssetDropPayload.Format("FileGroupDescriptorW").cfFormat || format.cfFormat == AssetDropPayload.Format("FileContents").cfFormat ? 0 : unchecked((int)0x80040064);
    public IEnumFORMATETC EnumFormatEtc(DATADIR direction) => new Formats([AssetDropPayload.Format("FileGroupDescriptorW"), AssetDropPayload.Format("FileContents")]);
    public void GetDataHere(ref FORMATETC format, ref STGMEDIUM medium) => throw new NotSupportedException();
    public int GetCanonicalFormatEtc(ref FORMATETC input, out FORMATETC output) { output = input; return 0x40130; }
    public void SetData(ref FORMATETC format, ref STGMEDIUM medium, bool release) => throw new NotSupportedException();
    public int DAdvise(ref FORMATETC format, ADVF flags, IAdviseSink sink, out int connection) { connection = 0; return unchecked((int)0x80040003); }
    public void DUnadvise(int connection) => throw new NotSupportedException();
    public int EnumDAdvise(out IEnumSTATDATA enumerator) { enumerator = null!; return unchecked((int)0x80040003); }
    private sealed class Formats(FORMATETC[] formats) : IEnumFORMATETC
    {
        private int _index;
        public int Next(int count, FORMATETC[] values, int[]? fetched)
        { var copied = 0; while (copied < count && _index < formats.Length) values[copied++] = formats[_index++]; if (fetched is { Length: > 0 }) fetched[0] = copied; return copied == count ? 0 : 1; }
        public int Skip(int count) { _index = Math.Min(_index + count, formats.Length); return _index < formats.Length ? 0 : 1; }
        public int Reset() { _index = 0; return 0; }
        public void Clone(out IEnumFORMATETC value) { value = new Formats(formats) { _index = _index }; }
    }
    [DllImport("kernel32.dll")] private static extern nint GlobalAlloc(uint flags, nuint bytes);
    [DllImport("kernel32.dll")] private static extern nint GlobalLock(nint handle);
    [DllImport("kernel32.dll")] private static extern bool GlobalUnlock(nint handle);
}

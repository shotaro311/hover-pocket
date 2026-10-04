using System.Runtime.InteropServices;

namespace HoverPocket.Shell.Providers.Assets;

internal static class AssetRecycle
{
    public static Task<bool> MoveAsync(string path)
    {
        var completion = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            object? instance = null; IntPtr item = IntPtr.Zero; var moved = false;
            try
            {
                instance = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("3AD05575-8857-4850-9277-11B85BDB8E09"))!)!;
                var operation = (IFileOperation)instance;
                // RECYCLEONDELETE forbids permanent deletion. EARLYFAILURE avoids ignoring a failed recycle operation.
                operation.SetOperationFlags(0x00080000 | 0x00100000 | 0x00000400 | 0x00000004 | 0x00000010 | 0x20000000);
                var iid = new Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE");
                Marshal.ThrowExceptionForHR(SHCreateItemFromParsingName(path, IntPtr.Zero, ref iid, out item));
                operation.DeleteItem(item, IntPtr.Zero); operation.PerformOperations(); operation.GetAnyOperationsAborted(out var aborted);
                moved = !aborted && !File.Exists(path) && !Directory.Exists(path);
            }
            catch (Exception ex) when (ex is COMException or UnauthorizedAccessException or IOException) { }
            finally { if (item != IntPtr.Zero) Marshal.Release(item); if (instance is not null && Marshal.IsComObject(instance)) Marshal.FinalReleaseComObject(instance); }
            completion.TrySetResult(moved);
        }) { Name = "HoverPocket recycle" };
        // Keep the apartment alive through native cleanup, including during application shutdown.
        thread.SetApartmentState(ApartmentState.STA); thread.Start(); return completion.Task;
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SHCreateItemFromParsingName(string path, IntPtr bindContext, ref Guid iid, out IntPtr item);
    [ComImport, Guid("947AAB5F-0A5C-4C13-B4D6-4BF7836FC9F8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFileOperation
    {
        void Advise(IntPtr sink, out uint cookie); void Unadvise(uint cookie); void SetOperationFlags(uint flags);
        void SetProgressMessage([MarshalAs(UnmanagedType.LPWStr)] string message); void SetProgressDialog(IntPtr dialog);
        void SetProperties(IntPtr changes); void SetOwnerWindow(IntPtr owner); void ApplyPropertiesToItem(IntPtr item); void ApplyPropertiesToItems(IntPtr items);
        void RenameItem(IntPtr item, [MarshalAs(UnmanagedType.LPWStr)] string name, IntPtr sink); void RenameItems(IntPtr items, [MarshalAs(UnmanagedType.LPWStr)] string name);
        void MoveItem(IntPtr item, IntPtr folder, [MarshalAs(UnmanagedType.LPWStr)] string? name, IntPtr sink); void MoveItems(IntPtr items, IntPtr folder);
        void CopyItem(IntPtr item, IntPtr folder, [MarshalAs(UnmanagedType.LPWStr)] string? name, IntPtr sink); void CopyItems(IntPtr items, IntPtr folder);
        void DeleteItem(IntPtr item, IntPtr sink); void DeleteItems(IntPtr items);
        void NewItem(IntPtr folder, uint attributes, [MarshalAs(UnmanagedType.LPWStr)] string name, [MarshalAs(UnmanagedType.LPWStr)] string? template, IntPtr sink);
        void PerformOperations(); void GetAnyOperationsAborted([MarshalAs(UnmanagedType.Bool)] out bool aborted);
    }
}

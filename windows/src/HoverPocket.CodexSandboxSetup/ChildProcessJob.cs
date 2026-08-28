using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace HoverPocket.CodexSandboxSetup;

internal sealed class ChildProcessJob : IDisposable
{
    private const uint JobObjectLimitKillOnJobClose = 0x00002000;
    private const int JobObjectExtendedLimitInformationClass = 9;
    private readonly SafeFileHandle _jobHandle;

    private ChildProcessJob(SafeFileHandle jobHandle)
    {
        _jobHandle = jobHandle;
    }

    internal static ChildProcessJob CreateAndAssign(Process process)
    {
        var job = CreateJobObject(IntPtr.Zero, null);
        if (job.IsInvalid)
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_CHILD_JOB_CREATE_FAILED");
        }
        try
        {
            var information = new JobObjectExtendedLimitInformation
            {
                BasicLimitInformation = new JobObjectBasicLimitInformation
                {
                    LimitFlags = JobObjectLimitKillOnJobClose,
                },
            };
            var size = Marshal.SizeOf<JobObjectExtendedLimitInformation>();
            var pointer = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(information, pointer, false);
                if (!SetInformationJobObject(
                    job,
                    JobObjectExtendedLimitInformationClass,
                    pointer,
                    (uint)size))
                {
                    throw new InvalidOperationException("HP_CODEX_SANDBOX_CHILD_JOB_CONFIG_FAILED");
                }
            }
            finally
            {
                Marshal.FreeHGlobal(pointer);
            }

            if (!AssignProcessToJobObject(job, process.SafeHandle))
            {
                throw new InvalidOperationException("HP_CODEX_SANDBOX_CHILD_JOB_ASSIGN_FAILED");
            }
            return new ChildProcessJob(job);
        }
        catch
        {
            job.Dispose();
            throw;
        }
    }

    public void Dispose() => _jobHandle.Dispose();

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateJobObject(
        IntPtr jobAttributes,
        string? name);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetInformationJobObject(
        SafeFileHandle jobHandle,
        int informationClass,
        IntPtr jobObjectInformation,
        uint jobObjectInformationLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AssignProcessToJobObject(
        SafeFileHandle jobHandle,
        SafeProcessHandle processHandle);

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectBasicLimitInformation
    {
        internal long PerProcessUserTimeLimit;
        internal long PerJobUserTimeLimit;
        internal uint LimitFlags;
        internal UIntPtr MinimumWorkingSetSize;
        internal UIntPtr MaximumWorkingSetSize;
        internal uint ActiveProcessLimit;
        internal UIntPtr Affinity;
        internal uint PriorityClass;
        internal uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters
    {
        internal ulong ReadOperationCount;
        internal ulong WriteOperationCount;
        internal ulong OtherOperationCount;
        internal ulong ReadTransferCount;
        internal ulong WriteTransferCount;
        internal ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectExtendedLimitInformation
    {
        internal JobObjectBasicLimitInformation BasicLimitInformation;
        internal IoCounters IoInfo;
        internal UIntPtr ProcessMemoryLimit;
        internal UIntPtr JobMemoryLimit;
        internal UIntPtr PeakProcessMemoryUsed;
        internal UIntPtr PeakJobMemoryUsed;
    }
}

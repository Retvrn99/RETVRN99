# SPDX-License-Identifier: GPL-3.0-only

Set-StrictMode -Version Latest

function Initialize-Vkd3dEvidenceNative {
    if (-not [OperatingSystem]::IsWindows()) {
        throw 'Native vkd3d evidence isolation requires Windows.'
    }
    if ($null -ne ('Retvrn99.Vkd3dEvidenceNative' -as [type])) { return }

    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Retvrn99
{
    public static class Vkd3dEvidenceNative
    {
        const uint GENERIC_READ = 0x80000000;
        const uint GENERIC_WRITE = 0x40000000;
        const uint DELETE = 0x00010000;
        const uint SYNCHRONIZE = 0x00100000;
        const uint FILE_READ_ATTRIBUTES = 0x00000080;
        const uint FILE_SHARE_READ = 0x00000001;
        const uint FILE_SHARE_WRITE = 0x00000002;
        const uint FILE_SHARE_DELETE = 0x00000004;
        const uint CREATE_NEW = 1;
        const uint FILE_CREATE = 2;
        const uint OPEN_EXISTING = 3;
        const uint FILE_DIRECTORY_FILE = 0x00000001;
        const uint FILE_SYNCHRONOUS_IO_NONALERT = 0x00000020;
        const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
        const uint FILE_ATTRIBUTE_DIRECTORY = 0x00000010;
        const uint FILE_ATTRIBUTE_DEVICE = 0x00000040;
        const uint FILE_ATTRIBUTE_REPARSE_POINT = 0x00000400;
        const uint STARTF_USESTDHANDLES = 0x00000100;
        const uint CREATE_SUSPENDED = 0x00000004;
        const uint CREATE_NO_WINDOW = 0x08000000;
        const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
        const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
        const uint HANDLE_FLAG_INHERIT = 0x00000001;
        const uint JOB_OBJECT_LIMIT_ACTIVE_PROCESS = 0x00000008;
        const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
        const uint INVALID_FILE_ATTRIBUTES = 0xFFFFFFFF;
        const int ERROR_FILE_NOT_FOUND = 2;
        const int ERROR_PATH_NOT_FOUND = 3;
        const int ERROR_INSUFFICIENT_BUFFER = 122;
        const int JobObjectBasicAccountingInformation = 1;
        const int JobObjectExtendedLimitInformation = 9;
        const int FileAttributeTagInfo = 9;
        const int FileDispositionInfo = 4;
        const uint OBJ_CASE_INSENSITIVE = 0x00000040;
        const ulong FILE_CREATED = 2;
        static readonly IntPtr PROC_THREAD_ATTRIBUTE_HANDLE_LIST =
            new IntPtr(0x00020002);

        [StructLayout(LayoutKind.Sequential)]
        struct SECURITY_ATTRIBUTES
        {
            public int nLength;
            public IntPtr lpSecurityDescriptor;
            [MarshalAs(UnmanagedType.Bool)] public bool bInheritHandle;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct STARTUPINFO
        {
            public int cb;
            public string lpReserved;
            public string lpDesktop;
            public string lpTitle;
            public uint dwX;
            public uint dwY;
            public uint dwXSize;
            public uint dwYSize;
            public uint dwXCountChars;
            public uint dwYCountChars;
            public uint dwFillAttribute;
            public uint dwFlags;
            public short wShowWindow;
            public short cbReserved2;
            public IntPtr lpReserved2;
            public IntPtr hStdInput;
            public IntPtr hStdOutput;
            public IntPtr hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct STARTUPINFOEX
        {
            public STARTUPINFO StartupInfo;
            public IntPtr lpAttributeList;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct PROCESS_INFORMATION
        {
            public IntPtr hProcess;
            public IntPtr hThread;
            public uint dwProcessId;
            public uint dwThreadId;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct IO_COUNTERS
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct JOBOBJECT_BASIC_ACCOUNTING_INFORMATION
        {
            public long TotalUserTime;
            public long TotalKernelTime;
            public long ThisPeriodTotalUserTime;
            public long ThisPeriodTotalKernelTime;
            public uint TotalPageFaultCount;
            public uint TotalProcesses;
            public uint ActiveProcesses;
            public uint TotalTerminatedProcesses;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct FILE_ATTRIBUTE_TAG_INFO
        {
            public uint FileAttributes;
            public uint ReparseTag;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct FILE_DISPOSITION_INFO
        {
            [MarshalAs(UnmanagedType.Bool)] public bool DeleteFile;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct BY_HANDLE_FILE_INFORMATION
        {
            public uint FileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME
                CreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME
                LastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME
                LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct UNICODE_STRING
        {
            public ushort Length;
            public ushort MaximumLength;
            public IntPtr Buffer;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct OBJECT_ATTRIBUTES
        {
            public int Length;
            public IntPtr RootDirectory;
            public IntPtr ObjectName;
            public uint Attributes;
            public IntPtr SecurityDescriptor;
            public IntPtr SecurityQualityOfService;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct IO_STATUS_BLOCK
        {
            public IntPtr Status;
            public UIntPtr Information;
        }

        [DllImport("ntdll.dll")]
        static extern int NtCreateFile(out IntPtr fileHandle,
            uint desiredAccess, ref OBJECT_ATTRIBUTES objectAttributes,
            out IO_STATUS_BLOCK ioStatusBlock, IntPtr allocationSize,
            uint fileAttributes, uint shareAccess, uint createDisposition,
            uint createOptions, IntPtr eaBuffer, uint eaLength);

        [DllImport("ntdll.dll")]
        static extern uint RtlNtStatusToDosError(int status);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode,
            SetLastError = true)]
        static extern SafeFileHandle CreateFileW(string path,
            uint desiredAccess, uint shareMode, IntPtr securityAttributes,
            uint creationDisposition, uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode,
            SetLastError = true)]
        static extern uint GetFileAttributesW(string path);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode,
            SetLastError = true)]
        static extern uint GetFinalPathNameByHandleW(SafeFileHandle file,
            StringBuilder path, uint capacity, uint flags);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetFileInformationByHandleEx(
            SafeFileHandle file, int informationClass,
            out FILE_ATTRIBUTE_TAG_INFO information, uint size);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetFileInformationByHandle(
            SafeFileHandle file,
            out BY_HANDLE_FILE_INFORMATION information);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetFileInformationByHandle(
            SafeFileHandle file, int informationClass,
            ref FILE_DISPOSITION_INFO information, uint size);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetFileSizeEx(SafeFileHandle file,
            out long size);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetFilePointerEx(SafeFileHandle file,
            long distance, out long newPosition, uint moveMethod);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool ReadFile(SafeFileHandle file, byte[] buffer,
            uint bytesToRead, out uint bytesRead, IntPtr overlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool WriteFile(SafeFileHandle file, byte[] buffer,
            uint bytesToWrite, out uint bytesWritten, IntPtr overlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetEndOfFile(SafeFileHandle file);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool FlushFileBuffers(SafeFileHandle file);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool DuplicateHandle(IntPtr sourceProcess,
            SafeFileHandle sourceHandle, IntPtr targetProcess,
            out SafeFileHandle targetHandle, uint desiredAccess,
            bool inheritHandle, uint options);

        [DllImport("kernel32.dll")]
        static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern SafeFileHandle CreateJobObjectW(
            IntPtr jobAttributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetInformationJobObject(SafeFileHandle job,
            int informationClass,
            ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION information,
            uint size);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool QueryInformationJobObject(SafeFileHandle job,
            int informationClass,
            out JOBOBJECT_BASIC_ACCOUNTING_INFORMATION information,
            uint size, IntPtr returnLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool AssignProcessToJobObject(SafeFileHandle job,
            IntPtr process);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool TerminateJobObject(SafeFileHandle job,
            uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool TerminateProcess(IntPtr process, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CreatePipe(out SafeFileHandle readPipe,
            out SafeFileHandle writePipe,
            ref SECURITY_ATTRIBUTES pipeAttributes, uint size);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetHandleInformation(SafeFileHandle handle,
            uint mask, uint flags);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode,
            SetLastError = true)]
        static extern bool CreateProcessW(string applicationName,
            StringBuilder commandLine, IntPtr processAttributes,
            IntPtr threadAttributes, bool inheritHandles,
            uint creationFlags, IntPtr environment,
            string currentDirectory, ref STARTUPINFOEX startupInfo,
            out PROCESS_INFORMATION processInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool InitializeProcThreadAttributeList(
            IntPtr attributeList, int attributeCount, int flags,
            ref IntPtr size);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool UpdateProcThreadAttribute(
            IntPtr attributeList, uint flags, IntPtr attribute,
            IntPtr value, IntPtr size, IntPtr previousValue,
            IntPtr returnSize);

        [DllImport("kernel32.dll")]
        static extern void DeleteProcThreadAttributeList(
            IntPtr attributeList);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern uint ResumeThread(IntPtr thread);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern uint WaitForSingleObject(IntPtr handle,
            uint milliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetExitCodeProcess(IntPtr process,
            out uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CloseHandle(IntPtr handle);

        static InvalidOperationException NativeFailure(
            string operation, int error)
        {
            return new InvalidOperationException(
                operation + " failed with Windows error " + error + ".");
        }

        static Exception CleanupCreatedDirectory(
            SafeFileHandle handle, string path)
        {
            List<Exception> failures = new List<Exception>();
            try { MarkDelete(handle); }
            catch (Exception failure) { failures.Add(failure); }
            finally { handle.Dispose(); }
            try
            {
                if (!IsPathAbsent(path))
                    throw new InvalidOperationException(
                        "Atomic directory cleanup was incomplete.");
            }
            catch (Exception failure) { failures.Add(failure); }
            if (failures.Count == 0) return null;
            if (failures.Count == 1) return failures[0];
            return new AggregateException(
                "Atomic directory cleanup failed.", failures);
        }

        public static SafeFileHandle CreateExclusiveDirectoryAt(
            SafeFileHandle parent, string leaf)
        {
            if (parent == null || parent.IsInvalid || parent.IsClosed)
                throw new InvalidOperationException(
                    "Atomic directory parent handle is invalid.");
            if (String.IsNullOrWhiteSpace(leaf) || leaf.Length > 255 ||
                leaf == "." || leaf == ".." ||
                leaf.IndexOfAny(new char[] { '\\', '/', ':', '\0' }) >= 0)
                throw new InvalidOperationException(
                    "Atomic directory leaf is invalid.");

            string parentPath = GetFinalPath(parent);
            string expectedPath = Path.GetFullPath(
                Path.Combine(parentPath, leaf));
            IntPtr textBuffer = IntPtr.Zero;
            IntPtr unicodeBuffer = IntPtr.Zero;
            IntPtr rawHandle = IntPtr.Zero;
            bool parentAdded = false;
            try
            {
                textBuffer = Marshal.StringToHGlobalUni(leaf);
                UNICODE_STRING name = new UNICODE_STRING();
                name.Length = checked((ushort)(leaf.Length * 2));
                name.MaximumLength = name.Length;
                name.Buffer = textBuffer;
                unicodeBuffer = Marshal.AllocHGlobal(
                    Marshal.SizeOf<UNICODE_STRING>());
                Marshal.StructureToPtr(name, unicodeBuffer, false);
                OBJECT_ATTRIBUTES attributes = new OBJECT_ATTRIBUTES();
                attributes.Length = Marshal.SizeOf<OBJECT_ATTRIBUTES>();
                parent.DangerousAddRef(ref parentAdded);
                attributes.RootDirectory = parent.DangerousGetHandle();
                attributes.ObjectName = unicodeBuffer;
                attributes.Attributes = OBJ_CASE_INSENSITIVE;
                IO_STATUS_BLOCK statusBlock;
                int status = NtCreateFile(out rawHandle,
                    GENERIC_READ | DELETE | SYNCHRONIZE |
                        FILE_READ_ATTRIBUTES,
                    ref attributes, out statusBlock, IntPtr.Zero, 0,
                    FILE_SHARE_READ | FILE_SHARE_WRITE, FILE_CREATE,
                    FILE_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT |
                        FILE_FLAG_OPEN_REPARSE_POINT,
                    IntPtr.Zero, 0);
                if (status < 0)
                {
                    if (rawHandle != IntPtr.Zero &&
                        rawHandle != new IntPtr(-1))
                        CloseHandle(rawHandle);
                    rawHandle = IntPtr.Zero;
                    throw NativeFailure("Atomic directory creation",
                        unchecked((int)RtlNtStatusToDosError(status)));
                }
                SafeFileHandle handle = new SafeFileHandle(rawHandle, true);
                rawHandle = IntPtr.Zero;
                try
                {
                    if (statusBlock.Information.ToUInt64() != FILE_CREATED ||
                        !GetFinalPath(handle).Equals(expectedPath,
                            StringComparison.OrdinalIgnoreCase))
                        throw new InvalidOperationException(
                            "Atomic directory creation identity changed.");
                    uint observed = GetAttributes(handle);
                    if ((observed & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
                        (observed & (FILE_ATTRIBUTE_REPARSE_POINT |
                            FILE_ATTRIBUTE_DEVICE)) != 0)
                        throw new InvalidOperationException(
                            "Atomic directory is not one ordinary directory.");
                    return handle;
                }
                catch (Exception primary)
                {
                    Exception cleanup = CleanupCreatedDirectory(
                        handle, expectedPath);
                    if (cleanup != null)
                        throw new AggregateException(
                            "Atomic directory validation and cleanup both failed.",
                            primary, cleanup);
                    throw;
                }
            }
            finally
            {
                if (rawHandle != IntPtr.Zero && rawHandle != new IntPtr(-1))
                    CloseHandle(rawHandle);
                if (parentAdded) parent.DangerousRelease();
                if (unicodeBuffer != IntPtr.Zero)
                    Marshal.FreeHGlobal(unicodeBuffer);
                if (textBuffer != IntPtr.Zero)
                    Marshal.FreeHGlobal(textBuffer);
            }
        }

        public static SafeFileHandle CreateExclusiveDirectory(string path)
        {
            string full = Path.GetFullPath(path).TrimEnd(
                Path.DirectorySeparatorChar,
                Path.AltDirectorySeparatorChar);
            string parentPath = Path.GetDirectoryName(full);
            string leaf = Path.GetFileName(full);
            if (String.IsNullOrWhiteSpace(parentPath))
                throw new InvalidOperationException(
                    "Atomic directory parent is invalid.");
            using (SafeFileHandle parent = OpenDirectoryForRelativeCreate(
                parentPath))
            {
                if (!GetFinalPath(parent).Equals(
                        Path.GetFullPath(parentPath),
                        StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException(
                        "Atomic directory parent identity changed.");
                SafeFileHandle handle = CreateExclusiveDirectoryAt(
                    parent, leaf);
                try
                {
                    if (!GetFinalPath(parent).Equals(
                            Path.GetFullPath(parentPath),
                            StringComparison.OrdinalIgnoreCase) ||
                        !GetFinalPath(handle).Equals(
                            full,
                            StringComparison.OrdinalIgnoreCase))
                        throw new InvalidOperationException(
                            "Atomic directory namespace changed.");
                    return handle;
                }
                catch (Exception primary)
                {
                    Exception cleanup = CleanupCreatedDirectory(
                        handle, full);
                    if (cleanup != null)
                        throw new AggregateException(
                            "Atomic directory namespace validation and cleanup both failed.",
                            primary, cleanup);
                    throw;
                }
            }
        }

        public static SafeFileHandle CreateOwnedFile(string path)
        {
            SafeFileHandle handle = CreateFileW(path,
                GENERIC_READ | GENERIC_WRITE | DELETE | SYNCHRONIZE |
                    FILE_READ_ATTRIBUTES,
                FILE_SHARE_READ, IntPtr.Zero,
                CREATE_NEW, FILE_FLAG_OPEN_REPARSE_POINT, IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw NativeFailure("Exclusive owner-file creation", error);
            }
            return handle;
        }

        public static SafeFileHandle OpenDeleteHandle(string path)
        {
            SafeFileHandle handle = CreateFileW(path,
                GENERIC_READ | DELETE | SYNCHRONIZE |
                    FILE_READ_ATTRIBUTES,
                FILE_SHARE_READ, IntPtr.Zero,
                OPEN_EXISTING,
                FILE_FLAG_BACKUP_SEMANTICS |
                    FILE_FLAG_OPEN_REPARSE_POINT,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw NativeFailure("Cleanup handle open", error);
            }
            return handle;
        }

        public static SafeFileHandle OpenStableFile(string path)
        {
            SafeFileHandle handle = CreateFileW(path,
                GENERIC_READ | SYNCHRONIZE | FILE_READ_ATTRIBUTES,
                FILE_SHARE_READ, IntPtr.Zero, OPEN_EXISTING,
                FILE_FLAG_OPEN_REPARSE_POINT, IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw NativeFailure("Stable file handle open", error);
            }
            return handle;
        }

        public static SafeFileHandle OpenStableDirectory(string path)
        {
            SafeFileHandle handle = CreateFileW(path,
                GENERIC_READ | SYNCHRONIZE | FILE_READ_ATTRIBUTES,
                FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero,
                OPEN_EXISTING,
                FILE_FLAG_BACKUP_SEMANTICS |
                    FILE_FLAG_OPEN_REPARSE_POINT,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw NativeFailure("Stable directory handle open", error);
            }
            try
            {
                uint attributes = GetAttributes(handle);
                if ((attributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
                    (attributes & (FILE_ATTRIBUTE_REPARSE_POINT |
                        FILE_ATTRIBUTE_DEVICE)) != 0)
                    throw new InvalidOperationException(
                        "Stable directory is not one ordinary directory.");
                return handle;
            }
            catch
            {
                handle.Dispose();
                throw;
            }
        }

        static SafeFileHandle OpenDirectoryForRelativeCreate(string path)
        {
            SafeFileHandle handle = CreateFileW(path,
                GENERIC_READ | SYNCHRONIZE | FILE_READ_ATTRIBUTES,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                IntPtr.Zero, OPEN_EXISTING,
                FILE_FLAG_BACKUP_SEMANTICS |
                    FILE_FLAG_OPEN_REPARSE_POINT,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw NativeFailure(
                    "Atomic directory parent handle open", error);
            }
            try
            {
                uint attributes = GetAttributes(handle);
                if ((attributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
                    (attributes & (FILE_ATTRIBUTE_REPARSE_POINT |
                        FILE_ATTRIBUTE_DEVICE)) != 0)
                    throw new InvalidOperationException(
                        "Atomic directory parent is not one ordinary directory.");
                return handle;
            }
            catch
            {
                handle.Dispose();
                throw;
            }
        }

        public static SafeFileHandle DuplicateStableHandle(
            SafeFileHandle source)
        {
            SafeFileHandle duplicate;
            IntPtr process = GetCurrentProcess();
            if (!DuplicateHandle(process, source, process, out duplicate,
                    0, false, 2))
                throw NativeFailure("Stable handle duplication",
                    Marshal.GetLastWin32Error());
            return duplicate;
        }

        public static uint GetAttributes(SafeFileHandle handle)
        {
            FILE_ATTRIBUTE_TAG_INFO information;
            if (!GetFileInformationByHandleEx(handle, FileAttributeTagInfo,
                    out information,
                    (uint)Marshal.SizeOf<FILE_ATTRIBUTE_TAG_INFO>()))
                throw NativeFailure("Handle attribute query",
                    Marshal.GetLastWin32Error());
            return information.FileAttributes;
        }

        public static string GetFileIdentity(SafeFileHandle handle)
        {
            BY_HANDLE_FILE_INFORMATION information;
            if (!GetFileInformationByHandle(handle, out information))
                throw NativeFailure("Stable file identity query",
                    Marshal.GetLastWin32Error());
            return information.VolumeSerialNumber.ToString("x8") + ":" +
                information.FileIndexHigh.ToString("x8") + ":" +
                information.FileIndexLow.ToString("x8");
        }

        public static string GetFinalPath(SafeFileHandle handle)
        {
            const int capacity = 32768;
            StringBuilder path = new StringBuilder(capacity);
            uint length = GetFinalPathNameByHandleW(handle, path,
                capacity, 0);
            if (length == 0)
                throw NativeFailure("Final handle-path query",
                    Marshal.GetLastWin32Error());
            if (length >= capacity)
                throw new InvalidOperationException(
                    "Final handle path exceeds its bound.");
            string value = path.ToString();
            if (value.StartsWith(@"\\?\UNC\",
                    StringComparison.OrdinalIgnoreCase))
                value = @"\\" + value.Substring(8);
            else if (value.StartsWith(@"\\?\",
                    StringComparison.OrdinalIgnoreCase))
                value = value.Substring(4);
            return Path.GetFullPath(value);
        }

        public static bool IsPathAbsent(string path)
        {
            if (GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES)
                return false;
            int error = Marshal.GetLastWin32Error();
            if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND)
                return true;
            throw NativeFailure("Namespace absence query", error);
        }

        public static byte[] ReadAll(SafeFileHandle handle, ulong maximum)
        {
            long length;
            if (!GetFileSizeEx(handle, out length) || length < 0 ||
                (ulong)length > maximum || length > Int32.MaxValue)
                throw new InvalidOperationException(
                    "Handle content exceeds its byte bound.");
            long ignored;
            if (!SetFilePointerEx(handle, 0, out ignored, 0))
                throw NativeFailure("Handle seek", Marshal.GetLastWin32Error());
            byte[] bytes = new byte[(int)length];
            int offset = 0;
            while (offset < bytes.Length)
            {
                uint read;
                uint request = (uint)Math.Min(65536,
                    bytes.Length - offset);
                byte[] buffer = new byte[request];
                if (!ReadFile(handle, buffer, request, out read, IntPtr.Zero))
                    throw NativeFailure("Handle read",
                        Marshal.GetLastWin32Error());
                if (read == 0)
                    throw new InvalidOperationException(
                        "Handle content ended before its opened length.");
                Buffer.BlockCopy(buffer, 0, bytes, offset, (int)read);
                offset += (int)read;
            }
            if (!GetFileSizeEx(handle, out length) || length != bytes.Length)
                throw new InvalidOperationException(
                    "Handle content changed during its read.");
            return bytes;
        }

        public static void WriteAll(SafeFileHandle handle, byte[] bytes)
        {
            long ignored;
            if (!SetFilePointerEx(handle, 0, out ignored, 0))
                throw NativeFailure("Handle seek", Marshal.GetLastWin32Error());
            int offset = 0;
            while (offset < bytes.Length)
            {
                uint written;
                byte[] part = new byte[bytes.Length - offset];
                Buffer.BlockCopy(bytes, offset, part, 0, part.Length);
                if (!WriteFile(handle, part, (uint)part.Length,
                        out written, IntPtr.Zero) || written == 0)
                    throw NativeFailure("Handle write",
                        Marshal.GetLastWin32Error());
                offset += (int)written;
            }
            if (!SetEndOfFile(handle) || !FlushFileBuffers(handle))
                throw NativeFailure("Handle flush", Marshal.GetLastWin32Error());
        }

        public static void MarkDelete(SafeFileHandle handle)
        {
            FILE_DISPOSITION_INFO information =
                new FILE_DISPOSITION_INFO { DeleteFile = true };
            if (!SetFileInformationByHandle(handle, FileDispositionInfo,
                    ref information,
                    (uint)Marshal.SizeOf<FILE_DISPOSITION_INFO>()))
                throw NativeFailure("Handle-gated deletion",
                    Marshal.GetLastWin32Error());
        }

        static string QuoteArgument(string argument)
        {
            if (argument.Length != 0 && argument.IndexOfAny(
                    new char[] { ' ', '\t', '\n', '\v', '"' }) < 0)
                return argument;
            StringBuilder result = new StringBuilder();
            result.Append('"');
            int slashes = 0;
            foreach (char value in argument)
            {
                if (value == '\\')
                {
                    slashes++;
                    continue;
                }
                if (value == '"')
                {
                    result.Append('\\', slashes * 2 + 1);
                    result.Append('"');
                    slashes = 0;
                    continue;
                }
                result.Append('\\', slashes);
                slashes = 0;
                result.Append(value);
            }
            result.Append('\\', slashes * 2);
            result.Append('"');
            return result.ToString();
        }

        static IntPtr BuildEnvironment(string[] rows)
        {
            string[] ordered = (string[])rows.Clone();
            Array.Sort(ordered, StringComparer.OrdinalIgnoreCase);
            StringBuilder block = new StringBuilder();
            foreach (string row in ordered)
            {
                if (String.IsNullOrEmpty(row) || row.IndexOf('\0') >= 0 ||
                    row.IndexOf('=') <= 0)
                    throw new InvalidOperationException(
                        "Child environment contains an invalid row.");
                block.Append(row);
                block.Append('\0');
            }
            block.Append('\0');
            return Marshal.StringToHGlobalUni(block.ToString());
        }

        public static BoundedProcess StartBoundedProcess(string file,
            string[] arguments, string workingDirectory,
            string[] environment, uint activeProcessLimit)
        {
            if (activeProcessLimit == 0 || activeProcessLimit > 8)
                throw new InvalidOperationException(
                    "The active-process limit is invalid.");
            SafeFileHandle job = null;
            SafeFileHandle stdoutRead = null;
            SafeFileHandle stdoutWrite = null;
            SafeFileHandle stderrRead = null;
            SafeFileHandle stderrWrite = null;
            SafeFileHandle stdinRead = null;
            SafeFileHandle stdinWrite = null;
            IntPtr attributes = IntPtr.Zero;
            IntPtr handleList = IntPtr.Zero;
            IntPtr environmentBlock = IntPtr.Zero;
            PROCESS_INFORMATION process = new PROCESS_INFORMATION();
            bool processCreated = false;
            bool processAssigned = false;
            bool attributeListInitialized = false;
            try
            {
                job = CreateJobObjectW(IntPtr.Zero, null);
                if (job.IsInvalid)
                    throw NativeFailure("Job creation",
                        Marshal.GetLastWin32Error());
                JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits =
                    new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
                limits.BasicLimitInformation.LimitFlags =
                    JOB_OBJECT_LIMIT_ACTIVE_PROCESS |
                    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
                limits.BasicLimitInformation.ActiveProcessLimit =
                    activeProcessLimit;
                if (!SetInformationJobObject(job,
                        JobObjectExtendedLimitInformation, ref limits,
                        (uint)Marshal.SizeOf<
                            JOBOBJECT_EXTENDED_LIMIT_INFORMATION>()))
                    throw NativeFailure("Job limit assignment",
                        Marshal.GetLastWin32Error());

                SECURITY_ATTRIBUTES pipeSecurity = new SECURITY_ATTRIBUTES {
                    nLength = Marshal.SizeOf<SECURITY_ATTRIBUTES>(),
                    bInheritHandle = true
                };
                if (!CreatePipe(out stdoutRead, out stdoutWrite,
                        ref pipeSecurity, 0) ||
                    !CreatePipe(out stderrRead, out stderrWrite,
                        ref pipeSecurity, 0) ||
                    !CreatePipe(out stdinRead, out stdinWrite,
                        ref pipeSecurity, 0))
                    throw NativeFailure("Child pipe creation",
                        Marshal.GetLastWin32Error());
                if (!SetHandleInformation(stdoutRead, HANDLE_FLAG_INHERIT, 0) ||
                    !SetHandleInformation(stderrRead, HANDLE_FLAG_INHERIT, 0) ||
                    !SetHandleInformation(stdinWrite, HANDLE_FLAG_INHERIT, 0))
                    throw NativeFailure("Child pipe isolation",
                        Marshal.GetLastWin32Error());

                IntPtr attributeSize = IntPtr.Zero;
                bool sizingResult = InitializeProcThreadAttributeList(
                    IntPtr.Zero, 1, 0, ref attributeSize);
                int sizingError = Marshal.GetLastWin32Error();
                if (sizingResult || sizingError != ERROR_INSUFFICIENT_BUFFER ||
                    attributeSize.ToInt64() <= 0 ||
                    attributeSize.ToInt64() > 1048576)
                    throw new InvalidOperationException(
                        "Process attribute sizing contract failed.");
                attributes = Marshal.AllocHGlobal(attributeSize);
                if (!InitializeProcThreadAttributeList(attributes, 1, 0,
                        ref attributeSize))
                    throw NativeFailure("Process attribute initialization",
                        Marshal.GetLastWin32Error());
                attributeListInitialized = true;
                handleList = Marshal.AllocHGlobal(IntPtr.Size * 3);
                Marshal.WriteIntPtr(handleList, 0,
                    stdoutWrite.DangerousGetHandle());
                Marshal.WriteIntPtr(handleList, IntPtr.Size,
                    stderrWrite.DangerousGetHandle());
                Marshal.WriteIntPtr(handleList, IntPtr.Size * 2,
                    stdinRead.DangerousGetHandle());
                if (!UpdateProcThreadAttribute(attributes, 0,
                        PROC_THREAD_ATTRIBUTE_HANDLE_LIST, handleList,
                        new IntPtr(IntPtr.Size * 3), IntPtr.Zero, IntPtr.Zero))
                    throw NativeFailure("Process handle-list isolation",
                        Marshal.GetLastWin32Error());

                STARTUPINFOEX startup = new STARTUPINFOEX();
                startup.StartupInfo.cb = Marshal.SizeOf<STARTUPINFOEX>();
                startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
                startup.StartupInfo.hStdInput =
                    stdinRead.DangerousGetHandle();
                startup.StartupInfo.hStdOutput =
                    stdoutWrite.DangerousGetHandle();
                startup.StartupInfo.hStdError =
                    stderrWrite.DangerousGetHandle();
                startup.lpAttributeList = attributes;

                StringBuilder command = new StringBuilder();
                command.Append(QuoteArgument(file));
                foreach (string argument in arguments)
                {
                    command.Append(' ');
                    command.Append(QuoteArgument(argument));
                }
                environmentBlock = BuildEnvironment(environment);
                uint creationFlags = CREATE_SUSPENDED | CREATE_NO_WINDOW |
                    CREATE_UNICODE_ENVIRONMENT |
                    EXTENDED_STARTUPINFO_PRESENT;
                if (!CreateProcessW(file, command, IntPtr.Zero, IntPtr.Zero,
                        true, creationFlags, environmentBlock,
                        workingDirectory, ref startup, out process))
                    throw NativeFailure("Suspended child creation",
                        Marshal.GetLastWin32Error());
                processCreated = true;
                if (!AssignProcessToJobObject(job, process.hProcess))
                    throw NativeFailure("Suspended child job assignment",
                        Marshal.GetLastWin32Error());
                processAssigned = true;
                if (ResumeThread(process.hThread) == UInt32.MaxValue)
                    throw NativeFailure("Bounded child resume",
                        Marshal.GetLastWin32Error());
                CloseHandle(process.hThread);
                process.hThread = IntPtr.Zero;
                stdoutWrite.Dispose();
                stdoutWrite = null;
                stderrWrite.Dispose();
                stderrWrite = null;
                stdinRead.Dispose();
                stdinRead = null;
                stdinWrite.Dispose();
                stdinWrite = null;
                BoundedProcess result = new BoundedProcess(job,
                    new SafeFileHandle(process.hProcess, true),
                    new FileStream(stdoutRead, FileAccess.Read, 8192, false),
                    new FileStream(stderrRead, FileAccess.Read, 8192, false),
                    process.dwProcessId, activeProcessLimit);
                process.hProcess = IntPtr.Zero;
                stdoutRead = null;
                stderrRead = null;
                job = null;
                return result;
            }
            catch (Exception primary)
            {
                List<Exception> cleanup = new List<Exception>();
                if (processCreated && process.hProcess != IntPtr.Zero)
                {
                    try
                    {
                        if (processAssigned)
                        {
                            if (!TerminateJobObject(job, 0xC000013A))
                                throw NativeFailure("Created child job termination",
                                    Marshal.GetLastWin32Error());
                        }
                        else if (!TerminateProcess(process.hProcess,
                                0xC000013A))
                            throw NativeFailure("Unassigned child termination",
                                Marshal.GetLastWin32Error());
                        uint wait = WaitForSingleObject(process.hProcess, 5000);
                        if (wait == 258)
                            throw new InvalidOperationException(
                                "Created child did not terminate within its bound.");
                        if (wait != 0)
                            throw NativeFailure("Created child termination wait",
                                Marshal.GetLastWin32Error());
                    }
                    catch (Exception failure) { cleanup.Add(failure); }
                }
                if (cleanup.Count != 0)
                {
                    cleanup.Insert(0, primary);
                    throw new AggregateException(
                        "Bounded child creation and cleanup both failed.",
                        cleanup);
                }
                throw;
            }
            finally
            {
                if (process.hThread != IntPtr.Zero)
                    CloseHandle(process.hThread);
                if (process.hProcess != IntPtr.Zero)
                    CloseHandle(process.hProcess);
                if (attributes != IntPtr.Zero)
                {
                    if (attributeListInitialized)
                        DeleteProcThreadAttributeList(attributes);
                    Marshal.FreeHGlobal(attributes);
                }
                if (handleList != IntPtr.Zero)
                    Marshal.FreeHGlobal(handleList);
                if (environmentBlock != IntPtr.Zero)
                    Marshal.FreeHGlobal(environmentBlock);
                if (stdoutRead != null) stdoutRead.Dispose();
                if (stdoutWrite != null) stdoutWrite.Dispose();
                if (stderrRead != null) stderrRead.Dispose();
                if (stderrWrite != null) stderrWrite.Dispose();
                if (stdinRead != null) stdinRead.Dispose();
                if (stdinWrite != null) stdinWrite.Dispose();
                if (job != null) job.Dispose();
            }
        }

        public sealed class BoundedProcess : IDisposable
        {
            SafeFileHandle job;
            SafeFileHandle process;
            public FileStream Stdout { get; private set; }
            public FileStream Stderr { get; private set; }
            public uint ProcessId { get; private set; }
            public uint ActiveProcessLimit { get; private set; }

            internal BoundedProcess(SafeFileHandle jobHandle,
                SafeFileHandle processHandle, FileStream stdout,
                FileStream stderr, uint processId, uint activeProcessLimit)
            {
                job = jobHandle;
                process = processHandle;
                Stdout = stdout;
                Stderr = stderr;
                ProcessId = processId;
                ActiveProcessLimit = activeProcessLimit;
            }

            public bool WaitForExit(int milliseconds)
            {
                uint result = WaitForSingleObject(process.DangerousGetHandle(),
                    milliseconds < 0 ? UInt32.MaxValue : (uint)milliseconds);
                if (result == 0) return true;
                if (result == 258) return false;
                throw NativeFailure("Bounded child wait",
                    Marshal.GetLastWin32Error());
            }

            public int ExitCode
            {
                get
                {
                    uint value;
                    if (!GetExitCodeProcess(process.DangerousGetHandle(),
                            out value))
                        throw NativeFailure("Bounded child exit-code query",
                            Marshal.GetLastWin32Error());
                    return unchecked((int)value);
                }
            }

            public uint ActiveProcesses
            {
                get
                {
                    JOBOBJECT_BASIC_ACCOUNTING_INFORMATION information;
                    if (!QueryInformationJobObject(job,
                            JobObjectBasicAccountingInformation,
                            out information,
                            (uint)Marshal.SizeOf<
                                JOBOBJECT_BASIC_ACCOUNTING_INFORMATION>(),
                            IntPtr.Zero))
                        throw NativeFailure("Job accounting query",
                            Marshal.GetLastWin32Error());
                    if (information.ActiveProcesses > ActiveProcessLimit)
                        throw new InvalidOperationException(
                            "The job exceeded its active-process limit.");
                    return information.ActiveProcesses;
                }
            }

            public void Terminate()
            {
                if (job == null || job.IsClosed) return;
                if (!TerminateJobObject(job, 0xC000013A))
                    throw NativeFailure("Job termination",
                        Marshal.GetLastWin32Error());
            }

            public void Dispose()
            {
                List<Exception> failures = new List<Exception>();
                try
                {
                    if (job != null && !job.IsClosed &&
                        ActiveProcesses != 0) Terminate();
                }
                catch (Exception failure) { failures.Add(failure); }
                finally
                {
                    try { if (job != null) job.Dispose(); }
                    catch (Exception failure) { failures.Add(failure); }
                    job = null;
                }
                try { if (Stdout != null) Stdout.Dispose(); }
                catch (Exception failure) { failures.Add(failure); }
                finally { Stdout = null; }
                try { if (Stderr != null) Stderr.Dispose(); }
                catch (Exception failure) { failures.Add(failure); }
                finally { Stderr = null; }
                try { if (process != null) process.Dispose(); }
                catch (Exception failure) { failures.Add(failure); }
                finally { process = null; }
                if (failures.Count != 0)
                    throw new AggregateException(
                        "Bounded process disposal failed.", failures);
            }
        }
    }
}
'@
}

function Assert-Vkd3dEvidenceSafeHandle {
    param(
        [Parameter(Mandatory = $true)]
        [Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Handle.IsInvalid -or $Handle.IsClosed) {
        throw "$Name is not one open stable handle."
    }
}

function New-Vkd3dEvidenceExclusiveDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Initialize-Vkd3dEvidenceNative
    $full = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($full)
    $handle = $null
    try {
        Assert-Vkd3dEvidenceNoReparseAncestor $parent "$Name parent"
        Assert-Vkd3dEvidenceDirectory $parent "$Name parent"
        $handle = [Retvrn99.Vkd3dEvidenceNative]::CreateExclusiveDirectory(
            $full
        )
        Assert-Vkd3dEvidenceNoReparseAncestor $full $Name
        return $handle
    }
    catch {
        if ($null -ne $handle) { $handle.Dispose() }
        throw [InvalidOperationException]::new(
            "$Name could not be created with exclusive ownership."
        )
    }
}

function Open-Vkd3dEvidenceStableHandle {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Initialize-Vkd3dEvidenceNative
    $full = [IO.Path]::GetFullPath($Path)
    $handle = $null
    try {
        Assert-Vkd3dEvidenceNoReparseAncestor $full $Name
        $handle = [Retvrn99.Vkd3dEvidenceNative]::OpenStableFile($full)
        [UInt32]$attributes = [Retvrn99.Vkd3dEvidenceNative]::GetAttributes(
            $handle
        )
        if (($attributes -band [IO.FileAttributes]::Directory) -ne 0 -or
            ($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($attributes -band [IO.FileAttributes]::Device) -ne 0) {
            throw "$Name is not one ordinary stable file."
        }
        Assert-Vkd3dEvidenceNoReparseAncestor $full $Name
        return $handle
    }
    catch {
        if ($null -ne $handle) { $handle.Dispose() }
        throw [InvalidOperationException]::new(
            "$Name could not be locked as one ordinary stable file."
        )
    }
}

function Open-Vkd3dEvidenceDeleteHandle {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Initialize-Vkd3dEvidenceNative
    $full = [IO.Path]::GetFullPath($Path)
    try {
        Assert-Vkd3dEvidenceNoReparseAncestor $full $Name
        return [Retvrn99.Vkd3dEvidenceNative]::OpenDeleteHandle($full)
    }
    catch {
        throw [InvalidOperationException]::new(
            "$Name could not be locked for identity-gated cleanup."
        )
    }
}

function Assert-Vkd3dEvidenceBoundDeleteHandle {
    param(
        [Parameter(Mandatory = $true)]
        [Microsoft.Win32.SafeHandles.SafeFileHandle]$RootHandle,
        [Parameter(Mandatory = $true)]
        [Microsoft.Win32.SafeHandles.SafeFileHandle]$TargetHandle,
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Assert-Vkd3dEvidenceSafeHandle $RootHandle "$Name root"
    Assert-Vkd3dEvidenceSafeHandle $TargetHandle "$Name target"
    $rootExpected = [IO.Path]::GetFullPath($RootPath)
    $targetExpected = [IO.Path]::GetFullPath($TargetPath)
    $rootObserved = [Retvrn99.Vkd3dEvidenceNative]::GetFinalPath(
        $RootHandle
    )
    $targetObserved = [Retvrn99.Vkd3dEvidenceNative]::GetFinalPath(
        $TargetHandle
    )
    if (-not $rootObserved.Equals(
            $rootExpected,
            [StringComparison]::OrdinalIgnoreCase
        ) -or -not $targetObserved.Equals(
            $targetExpected,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "$Name changed its held namespace binding."
    }
    $rootPrefix = $rootObserved.TrimEnd([char[]]'\/') +
        [IO.Path]::DirectorySeparatorChar
    if (-not $targetObserved.Equals(
            $rootObserved,
            [StringComparison]::OrdinalIgnoreCase
        ) -and -not $targetObserved.StartsWith(
            $rootPrefix,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "$Name is outside its held root namespace."
    }
}

function Set-Vkd3dEvidenceBoundHandleDelete {
    param(
        [Parameter(Mandatory = $true)]
        [Microsoft.Win32.SafeHandles.SafeFileHandle]$RootHandle,
        [Parameter(Mandatory = $true)]
        [Microsoft.Win32.SafeHandles.SafeFileHandle]$TargetHandle,
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Assert-Vkd3dEvidenceBoundDeleteHandle $RootHandle $TargetHandle `
        $RootPath $TargetPath "$Name pre-delete"
    [Retvrn99.Vkd3dEvidenceNative]::MarkDelete($TargetHandle)
    Assert-Vkd3dEvidenceBoundDeleteHandle $RootHandle $TargetHandle `
        $RootPath $TargetPath "$Name post-delete"
}

function Test-Vkd3dEvidencePathAbsent {
    param([Parameter(Mandatory = $true)][string]$Path)

    Initialize-Vkd3dEvidenceNative
    return [Retvrn99.Vkd3dEvidenceNative]::IsPathAbsent(
        [IO.Path]::GetFullPath($Path)
    )
}

function Assert-Vkd3dEvidencePathAbsent {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not (Test-Vkd3dEvidencePathAbsent $Path)) {
        throw "$Name survived cleanup or was replaced."
    }
}

function Copy-Vkd3dEvidenceStableHandle {
    param(
        [Parameter(Mandatory = $true)]
        [Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle
    )

    Assert-Vkd3dEvidenceSafeHandle $Handle 'stable handle'
    Initialize-Vkd3dEvidenceNative
    return [Retvrn99.Vkd3dEvidenceNative]::DuplicateStableHandle($Handle)
}

function Get-Vkd3dEvidenceHandleIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle,
        [Parameter(Mandatory = $true)][string]$Name,
        [UInt64]$MaximumBytes = [UInt64]67108864
    )

    Assert-Vkd3dEvidenceSafeHandle $Handle $Name
    [UInt32]$attributes = [Retvrn99.Vkd3dEvidenceNative]::GetAttributes(
        $Handle
    )
    if (($attributes -band [IO.FileAttributes]::Directory) -ne 0 -or
        ($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ($attributes -band [IO.FileAttributes]::Device) -ne 0) {
        throw "$Name is not one ordinary stable file."
    }
    [byte[]]$first = [Retvrn99.Vkd3dEvidenceNative]::ReadAll(
        $Handle, $MaximumBytes
    )
    [byte[]]$second = [Retvrn99.Vkd3dEvidenceNative]::ReadAll(
        $Handle, $MaximumBytes
    )
    $firstHash = Get-Vkd3dEvidenceSha256 $first
    $secondHash = Get-Vkd3dEvidenceSha256 $second
    if ($first.Length -ne $second.Length -or $firstHash -cne $secondHash) {
        throw "$Name changed during its stable-handle read."
    }
    return [pscustomobject][ordered]@{
        bytes = [UInt64]$first.Length
        sha256 = $firstHash
        file_identity = [Retvrn99.Vkd3dEvidenceNative]::GetFileIdentity(
            $Handle
        )
    }
}

function Set-Vkd3dEvidenceHandleBytes {
    param(
        [Parameter(Mandatory = $true)]
        [Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Assert-Vkd3dEvidenceSafeHandle $Handle $Name
    [Retvrn99.Vkd3dEvidenceNative]::WriteAll($Handle, $Bytes)
    [byte[]]$observed = [Retvrn99.Vkd3dEvidenceNative]::ReadAll(
        $Handle, [UInt64][Math]::Max(1, $Bytes.Length)
    )
    if ($observed.Length -ne $Bytes.Length -or
        (Get-Vkd3dEvidenceSha256 $observed) -cne
            (Get-Vkd3dEvidenceSha256 $Bytes)) {
        throw "$Name failed exact handle-gated writeback."
    }
}

function New-Vkd3dEvidenceOwnedDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $rootHandle = $null
    $markerHandle = $null
    $markerCreated = $false
    $ownerToken = [Guid]::NewGuid().ToString('N')
    try {
        $rootHandle = New-Vkd3dEvidenceExclusiveDirectory $Path $Name
        $marker = Join-Path $Path '.retvrn99-vkd3d-proof-owner'
        $markerHandle = [Retvrn99.Vkd3dEvidenceNative]::CreateOwnedFile(
            [IO.Path]::GetFullPath($marker)
        )
        $markerCreated = $true
        [byte[]]$ownerBytes = $script:Vkd3dEvidenceUtf8.GetBytes(
            $ownerToken
        )
        Set-Vkd3dEvidenceHandleBytes $markerHandle $ownerBytes `
            "$Name ownership marker"
        return [pscustomobject]@{
            Path = [IO.Path]::GetFullPath($Path)
            OwnerToken = $ownerToken
            RootHandle = $rootHandle
            OwnerMarkerHandle = $markerHandle
        }
    }
    catch {
        $primary = $_.Exception
        $cleanup = [Collections.Generic.List[Exception]]::new()
        if ($null -ne $rootHandle) {
            try {
                Remove-Vkd3dEvidenceBootstrapTree $Path $markerCreated `
                    -RootHandle $rootHandle `
                    -OwnerMarkerHandle $markerHandle
                $rootHandle = $null
                $markerHandle = $null
            }
            catch { $cleanup.Add($_.Exception) }
        }
        if ($null -ne $markerHandle) { $markerHandle.Dispose() }
        if ($null -ne $rootHandle) { $rootHandle.Dispose() }
        if ($cleanup.Count -gt 0) {
            throw (New-Vkd3dEvidenceCombinedFailure $primary `
                ([Exception[]]$cleanup.ToArray()) @($Path))
        }
        throw
    }
}

function Invoke-Vkd3dEvidenceProcess {
    param(
        [Parameter(Mandatory = $true)][string]$File,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string[]]$PathDirectories,
        [Parameter(Mandatory = $true)][string]$PrivateTemp,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ref]$ChildCount,
        [hashtable]$Environment = @{},
        [Microsoft.Win32.SafeHandles.SafeFileHandle]$PinnedExecutableHandle,
        [ValidateSet(2, 3, 5)][int]$MaximumProcessTreeWidth = 5,
        [ValidateRange(1, 30)][int]$TimeoutSeconds = 30,
        [ValidateRange(1, 1048576)][int]$MaximumOutputBytes = 1048576
    )

    Initialize-Vkd3dEvidenceNative
    $ownedExecutableHandle = $null
    Assert-Vkd3dEvidenceDirectory $WorkingDirectory "$Name working directory"
    Assert-Vkd3dEvidenceDirectory $PrivateTemp "$Name private TEMP"
    if ($PathDirectories.Count -lt 1 -or $PathDirectories.Count -gt 8) {
        throw "$Name has an invalid PATH directory count."
    }
    $pathSet = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($directory in $PathDirectories) {
        Assert-Vkd3dEvidenceDirectory $directory "$Name PATH directory"
        if (-not $pathSet.Add([IO.Path]::GetFullPath($directory))) {
            throw "$Name repeats a PATH directory."
        }
    }
    $allowedEnvironment = @(
        'BISON_PKGDATADIR', 'M4', 'PERL5LIB',
        'GIT_CONFIG_NOSYSTEM', 'GIT_CONFIG_GLOBAL',
        'GIT_OPTIONAL_LOCKS', 'GIT_TERMINAL_PROMPT'
    )
    foreach ($key in $Environment.Keys) {
        if ($key -isnot [string] -or $allowedEnvironment -cnotcontains $key -or
            $Environment[$key] -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string]$Environment[$key]) -or
            ([string]$Environment[$key]).Length -gt 32768 -or
            ([string]$Environment[$key]).Contains([char]0)) {
            throw "$Name has an unsupported environment override."
        }
    }
    foreach ($binding in @(
        @('GIT_CONFIG_NOSYSTEM', '1'),
        @('GIT_CONFIG_GLOBAL', 'NUL'),
        @('GIT_OPTIONAL_LOCKS', '0'),
        @('GIT_TERMINAL_PROMPT', '0')
    )) {
        if ($Environment.ContainsKey($binding[0]) -and
            [string]$Environment[$binding[0]] -cne $binding[1]) {
            throw "$Name has an unsupported environment override."
        }
    }
    $windows = [Environment]::GetFolderPath('Windows')
    $system = [Environment]::GetFolderPath('System')
    Assert-Vkd3dEvidenceDirectory $windows "$Name Windows directory"
    Assert-Vkd3dEvidenceDirectory $system "$Name system directory"
    $childEnvironment = [ordered]@{
        SystemRoot = $windows
        WINDIR = $windows
        PATH = (@($PathDirectories + $system) | Select-Object -Unique) -join ';'
        TEMP = $PrivateTemp
        TMP = $PrivateTemp
        LC_ALL = 'C'
        LANG = 'C'
        TZ = 'UTC'
        SOURCE_DATE_EPOCH = '0'
        PERL_JSON_BACKEND = 'JSON::PP'
    }
    foreach ($key in $Environment.Keys) {
        $childEnvironment[[string]$key] = [string]$Environment[$key]
    }
    [string[]]$environmentRows = @(
        foreach ($key in $childEnvironment.Keys) {
            "$key=$($childEnvironment[$key])"
        }
    )

    $process = $null
    $started = $false
    $primaryFailure = $null
    $result = $null
    $cleanupFailures = [Collections.Generic.List[Exception]]::new()
    try {
        if ($null -eq $PinnedExecutableHandle) {
            $ownedExecutableHandle = Open-Vkd3dEvidenceStableHandle $File `
                "$Name executable"
            $executableHandle = $ownedExecutableHandle
        }
        else {
            Assert-Vkd3dEvidenceSafeHandle $PinnedExecutableHandle `
                "$Name executable"
            $executableHandle = $PinnedExecutableHandle
        }
        $executableBefore = Get-Vkd3dEvidenceHandleIdentity `
            $executableHandle "$Name executable"
        $pathHandle = Open-Vkd3dEvidenceStableHandle $File `
            "$Name executable path"
        try {
            $pathIdentity = Get-Vkd3dEvidenceHandleIdentity $pathHandle `
                "$Name executable path"
            if ($pathIdentity.file_identity -cne
                    $executableBefore.file_identity -or
                $pathIdentity.sha256 -cne $executableBefore.sha256 -or
                $pathIdentity.bytes -cne $executableBefore.bytes) {
                throw "$Name executable path changed before launch."
            }
        }
        finally { $pathHandle.Dispose() }
        try {
            $process = [Retvrn99.Vkd3dEvidenceNative]::StartBoundedProcess(
                [IO.Path]::GetFullPath($File),
                [string[]]$Arguments,
                [IO.Path]::GetFullPath($WorkingDirectory),
                $environmentRows,
                [UInt32]$MaximumProcessTreeWidth
            )
            $started = $true
        }
        catch { throw "$Name did not start." }
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        $streams = Read-Vkd3dEvidenceProcessStreams -Process $process `
            -Stopwatch $stopwatch -Name $Name -TimeoutSeconds $TimeoutSeconds `
            -MaximumOutputBytes $MaximumOutputBytes
        [byte[]]$stdoutBytes = $streams.stdout
        [byte[]]$stderrBytes = $streams.stderr
        if ($process.ExitCode -ne 0) {
            throw "$Name failed with exit code $($process.ExitCode)."
        }
        $executableAfter = Get-Vkd3dEvidenceHandleIdentity `
            $executableHandle "$Name executable"
        if ($executableAfter.file_identity -cne
                $executableBefore.file_identity -or
            $executableAfter.bytes -cne $executableBefore.bytes -or
            $executableAfter.sha256 -cne $executableBefore.sha256) {
            throw "$Name executable changed across its bounded run."
        }
        $result = [pscustomobject][ordered]@{
            stdout = $stdoutBytes
            stderr = $stderrBytes
            exit_code = [int]$process.ExitCode
        }
    }
    catch { $primaryFailure = $_.Exception }
    finally {
        try {
            if ($started) {
                try {
                    if ([UInt32]$process.ActiveProcesses -ne 0) {
                        Stop-Vkd3dEvidenceProcessTree $process
                    }
                }
                catch { $cleanupFailures.Add($_.Exception) }
                try {
                    $ChildCount.Value = [int]$ChildCount.Value + 1
                    if (($ChildCount.Value %
                            $script:Vkd3dEvidenceBatchSize) -eq 0) {
                        Start-Sleep -Milliseconds `
                            $script:Vkd3dEvidenceQuiescenceMilliseconds
                    }
                }
                catch { $cleanupFailures.Add($_.Exception) }
            }
        }
        finally {
            try {
                if ($null -ne $process) { $process.Dispose() }
            }
            catch { $cleanupFailures.Add($_.Exception) }
            finally {
                try {
                    if ($null -ne $ownedExecutableHandle) {
                        $ownedExecutableHandle.Dispose()
                    }
                }
                catch { $cleanupFailures.Add($_.Exception) }
            }
        }
    }
    if ($null -ne $primaryFailure) {
        if ($cleanupFailures.Count -eq 0) { throw $primaryFailure }
        $failures = [Collections.Generic.List[Exception]]::new()
        $failures.Add($primaryFailure)
        foreach ($failure in $cleanupFailures) { $failures.Add($failure) }
        throw [AggregateException]::new(
            'Bounded process execution and cleanup both failed.',
            [Exception[]]$failures.ToArray()
        )
    }
    if ($cleanupFailures.Count -ne 0) {
        throw [AggregateException]::new(
            'Bounded process cleanup failed.',
            [Exception[]]$cleanupFailures.ToArray()
        )
    }
    return $result
}

// ProcessNative.cs
// Native (P/Invoke) helper for ProcessSampler.ps1.
//
// Target: Windows PowerShell 5.1 / .NET Framework 4.x, therefore C# 5 syntax only
//         (no string interpolation, no nameof, no out-var, no expression-bodied members,
//          no auto-property initializers, no pattern matching).
//
// The helper is strictly read-only: it opens handles with query rights only, reads
// counters and closes every handle it opens. It never writes to, injects into or
// controls the sampled process.
//
// Metrics exposed (one ReadSample call per sampling tick):
//   * GetProcessTimes        -> kernel + user CPU time, 100 ns units
//   * GetProcessMemoryInfo   -> PROCESS_MEMORY_COUNTERS_EX (WS, peak WS, commit/pagefile,
//                               peak commit, page faults, PrivateUsage)
//   * QueryWorkingSet        -> private working set = non-shared working-set pages * page size
//   * GetProcessHandleCount  -> handle count
//   * GetGuiResources        -> GDI + USER object counts
//   * GetProcessIoCounters   -> cumulative I/O byte + operation counters
//   * NtQuerySystemInformation -> live thread count and per-thread CPU (Toolhelp fallback)
//   * GetThreadTimes         -> per-thread CPU time for top-N attribution
//
// Note on QueryWorkingSet: the buffer is a PSAPI_WORKING_SET_INFORMATION, i.e. a
// ULONG_PTR NumberOfEntries header followed by one PSAPI_WORKING_SET_BLOCK (ULONG_PTR)
// per page. Every returned block is a present (valid) page; the block has no Valid bit.
// Bit 8 of the block flags is the "Shared" bit, so private pages = entries minus
// entries with Shared=1, multiplied by the system page size.

using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace RiotSwitchPerf
{
    /// <summary>Raw snapshot of one external process at one point in time.</summary>
    public sealed class ProcessSample
    {
        public bool TimesValid;
        public long Kernel100ns;
        public long User100ns;

        public bool MemoryValid;
        public long WorkingSetBytes;
        public long PeakWorkingSetBytes;
        public long CommitBytes;        // PROCESS_MEMORY_COUNTERS_EX.PagefileUsage
        public long PeakCommitBytes;    // PROCESS_MEMORY_COUNTERS_EX.PeakPagefileUsage
        public long PrivateUsageBytes;  // PROCESS_MEMORY_COUNTERS_EX.PrivateUsage
        public long PageFaultCount;     // cumulative, 32-bit counter

        public bool PrivateWorkingSetValid;
        public long PrivateWorkingSetBytes;
        public long ValidPages;
        public long SharedPages;

        public bool HandleCountValid;
        public long HandleCount;

        public bool GuiResourcesValid;
        public long GdiObjects;
        public long UserObjects;

        public bool IoValid;
        public long IoReadBytes;
        public long IoWriteBytes;
        public long IoOtherBytes;
        public long IoReadOperations;
        public long IoWriteOperations;
        public long IoOtherOperations;

        public int ThreadCount;
        public int[] ThreadIds;
        // Flattened [tid, cpu100ns, tid, cpu100ns, ...] when readThreadCpu was requested.
        // Filled from NtQuerySystemInformation(SystemProcessInformation) : une seule
        // requete noyau pour compter ET attribuer le CPU des threads (Toolhelp32 est
        // trop lent : enumeration de tous les threads systeme, ~32 ms sur cette machine).
        public long[] ThreadCpuPairs;
    }

    public static class ProcessNative
    {
        // ---- access rights -------------------------------------------------
        public const uint PROCESS_QUERY_INFORMATION = 0x0400;
        public const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
        public const uint PROCESS_VM_READ = 0x0010;

        public const uint THREAD_QUERY_INFORMATION = 0x0040;
        public const uint THREAD_QUERY_LIMITED_INFORMATION = 0x0800;

        private const uint TH32CS_SNAPTHREAD = 0x00000004;
        private const uint GR_GDIOBJECTS = 0;
        private const uint GR_USEROBJECTS = 1;
        private const int ERROR_BAD_LENGTH = 24;

        // Working set buffer bounds (entries are one ULONG_PTR each).
        private const long MAX_WORKING_SET_ENTRIES = 33554432L; // 32M pages = 128 GB at 4 KB pages

        // Buffer reutilise entre les echantillons pour QueryWorkingSet : sans ce cache,
        // chaque tick allouait ~550 Ko sur le tas des grands objets (sources de GC et de
        // surcout). Le sampler est mono-thread ; le verrou protege un usage accidentel.
        private static readonly object WorkingSetBufferLock = new object();
        private static byte[] workingSetBuffer;

        // Buffer reutilise entre les echantillons pour NtQuerySystemInformation : le
        // systeme renvoie un instantane de tous les processus/threads (~1 Mo). Sans ce
        // cache, chaque tick allouait et liberait 1 Mo (cout eleve quand le processus a
        // dormi depuis le tick precedent : pages froides). Le sampler est mono-thread ;
        // le verrou protege un usage accidentel.
        private static readonly object SystemInfoBufferLock = new object();
        private static IntPtr systemInfoBuffer = IntPtr.Zero;
        private static int systemInfoBufferBytes;

        // ---- native structures ---------------------------------------------
        [StructLayout(LayoutKind.Sequential)]
        private struct FILETIME_STRUCT
        {
            public uint dwLowDateTime;
            public uint dwHighDateTime;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct PROCESS_MEMORY_COUNTERS_EX
        {
            public uint cb;
            public uint PageFaultCount;
            public UIntPtr PeakWorkingSetSize;
            public UIntPtr WorkingSetSize;
            public UIntPtr QuotaPeakPagedPoolUsage;
            public UIntPtr QuotaPagedPoolUsage;
            public UIntPtr QuotaPeakNonPagedPoolUsage;
            public UIntPtr QuotaNonPagedPoolUsage;
            public UIntPtr PagefileUsage;
            public UIntPtr PeakPagefileUsage;
            public UIntPtr PrivateUsage;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct IO_COUNTERS
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct THREADENTRY32
        {
            public uint dwSize;
            public uint cntUsage;
            public uint th32ThreadID;
            public uint th32OwnerProcessID;
            public int tpBasePri;
            public int tpDeltaPri;
            public uint dwFlags;
        }

        // ---- P/Invoke -------------------------------------------------------
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetProcessTimes(
            IntPtr hProcess,
            out FILETIME_STRUCT lpCreationTime,
            out FILETIME_STRUCT lpExitTime,
            out FILETIME_STRUCT lpKernelTime,
            out FILETIME_STRUCT lpUserTime);

        [DllImport("psapi.dll", SetLastError = true)]
        private static extern bool GetProcessMemoryInfo(
            IntPtr hProcess,
            out PROCESS_MEMORY_COUNTERS_EX ppsmemCounters,
            uint cb);

        [DllImport("psapi.dll", SetLastError = true)]
        private static extern bool QueryWorkingSet(IntPtr hProcess, IntPtr pv, uint cb);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetProcessHandleCount(IntPtr hProcess, out uint pdwHandleCount);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint GetGuiResources(IntPtr hProcess, uint uiFlags);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetProcessIoCounters(IntPtr hProcess, out IO_COUNTERS lpIoCounters);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr CreateToolhelp32Snapshot(uint dwFlags, uint th32ProcessID);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool Thread32First(IntPtr hSnapshot, ref THREADENTRY32 lpte);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool Thread32Next(IntPtr hSnapshot, ref THREADENTRY32 lpte);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenThread(uint dwDesiredAccess, bool bInheritHandle, uint dwThreadId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetThreadTimes(
            IntPtr hThread,
            out FILETIME_STRUCT lpCreationTime,
            out FILETIME_STRUCT lpExitTime,
            out FILETIME_STRUCT lpKernelTime,
            out FILETIME_STRUCT lpUserTime);

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetCurrentProcess();

        // ---- NtQuerySystemInformation : lecture economique du nombre/CPU des threads
        // (equivalent d'une seule requete noyau, utilisee par le Gestionnaire des taches)
        private const int SystemProcessInformation = 5;
        private const int STATUS_INFO_LENGTH_MISMATCH = unchecked((int)0xC0000004);
        private const int SYSTEM_PROCESS_INFORMATION_THREADS_OFFSET_X64 = 256;
        private const int SYSTEM_THREAD_INFORMATION_SIZE_X64 = 80;
        private const int SYSTEM_PROCESS_INFORMATION_THREAD_COUNT_OFFSET_X64 = 4;
        private const int SYSTEM_PROCESS_INFORMATION_PID_OFFSET_X64 = 80;
        private const int SYSTEM_THREAD_INFORMATION_TID_OFFSET_X64 = 48;
        private const int SYSTEM_THREAD_INFORMATION_KERNEL_OFFSET_X64 = 0;
        private const int SYSTEM_THREAD_INFORMATION_USER_OFFSET_X64 = 8;

        [DllImport("ntdll.dll")]
        private static extern int NtQuerySystemInformation(
            int systemInformationClass,
            IntPtr systemInformation,
            int systemInformationLength,
            out int returnLength);

        // ---- helpers --------------------------------------------------------
        private static long FileTimeToTicks(FILETIME_STRUCT ft)
        {
            return ((long)ft.dwHighDateTime << 32) | (long)ft.dwLowDateTime;
        }

        /// <summary>
        /// Reused byte buffer for QueryWorkingSet (see workingSetBuffer). The buffer must
        /// be pinned by the caller only for the duration of the native call.
        /// </summary>
        private static byte[] GetWorkingSetBuffer(int requiredBytes)
        {
            lock (WorkingSetBufferLock)
            {
                if (workingSetBuffer == null || workingSetBuffer.Length < requiredBytes)
                {
                    int newSize = requiredBytes;
                    if (workingSetBuffer != null && workingSetBuffer.Length * 2 > newSize)
                    {
                        newSize = workingSetBuffer.Length * 2;
                    }
                    workingSetBuffer = new byte[newSize];
                }
                return workingSetBuffer;
            }
        }

        public static int SystemPageSize
        {
            get { return Environment.SystemPageSize; }
        }

        /// <summary>Open a query-only handle, degrading access rights if needed.</summary>
        public static IntPtr OpenSamplingHandle(int pid, out uint grantedAccess)
        {
            grantedAccess = 0;
            uint[] accessLevels = new uint[]
            {
                PROCESS_QUERY_INFORMATION | PROCESS_VM_READ,
                PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ,
                PROCESS_QUERY_LIMITED_INFORMATION
            };
            for (int i = 0; i < accessLevels.Length; i++)
            {
                IntPtr h = OpenProcess(accessLevels[i], false, (uint)pid);
                if (h != IntPtr.Zero)
                {
                    grantedAccess = accessLevels[i];
                    return h;
                }
            }
            return IntPtr.Zero;
        }

        public static void CloseSamplingHandle(IntPtr hProcess)
        {
            if (hProcess != IntPtr.Zero)
            {
                CloseHandle(hProcess);
            }
        }

        public static bool TryGetProcessTimes(IntPtr hProcess, out long kernel100ns, out long user100ns)
        {
            FILETIME_STRUCT created;
            FILETIME_STRUCT exited;
            FILETIME_STRUCT kernel;
            FILETIME_STRUCT user;
            kernel100ns = 0;
            user100ns = 0;
            if (!GetProcessTimes(hProcess, out created, out exited, out kernel, out user))
            {
                return false;
            }
            kernel100ns = FileTimeToTicks(kernel);
            user100ns = FileTimeToTicks(user);
            return true;
        }

        /// <summary>
        /// Process creation time as 100 ns FILETIME (UTC). Used to compute the process
        /// uptime without relying on System.Diagnostics.Process.
        /// </summary>
        public static bool TryGetCreationTime100ns(IntPtr hProcess, out long creation100ns)
        {
            creation100ns = 0;
            FILETIME_STRUCT created;
            FILETIME_STRUCT exited;
            FILETIME_STRUCT kernel;
            FILETIME_STRUCT user;
            if (!GetProcessTimes(hProcess, out created, out exited, out kernel, out user))
            {
                return false;
            }
            creation100ns = FileTimeToTicks(created);
            return true;
        }

        public static bool TryGetMemoryInfo(IntPtr hProcess, out PROCESS_MEMORY_COUNTERS_EX counters)
        {
            counters = new PROCESS_MEMORY_COUNTERS_EX();
            counters.cb = (uint)Marshal.SizeOf(typeof(PROCESS_MEMORY_COUNTERS_EX));
            return GetProcessMemoryInfo(hProcess, out counters, counters.cb);
        }

        /// <summary>
        /// Private working set = working-set pages that are not shared, multiplied by the
        /// page size. The buffer layout is PSAPI_WORKING_SET_INFORMATION: a ULONG_PTR
        /// NumberOfEntries header followed by one PSAPI_WORKING_SET_BLOCK (ULONG_PTR) per
        /// page. For QueryWorkingSet (non-Ex) blocks there is no Valid bit: every returned
        /// entry is a valid, present page; Shared is bit 8 of the block flags.
        /// </summary>
        public static bool TryGetPrivateWorkingSet(
            IntPtr hProcess,
            long workingSetBytes,
            out long privateBytes,
            out long validPages,
            out long sharedPages)
        {
            privateBytes = 0;
            validPages = 0;
            sharedPages = 0;

            int pageSize = Environment.SystemPageSize;
            if (pageSize <= 0)
            {
                return false;
            }

            long pagesUsed = 0;
            if (workingSetBytes > 0)
            {
                pagesUsed = workingSetBytes / pageSize;
            }
            if (pagesUsed < 1)
            {
                pagesUsed = 1;
            }

            int entrySize = IntPtr.Size;
            long capacity = pagesUsed;

            for (int attempt = 0; attempt < 4; attempt++)
            {
                // 25 percent headroom + one slot for the NumberOfEntries header: the
                // working set can grow between the memory query and the native call.
                long requested = capacity + (capacity / 4) + 4096;
                if (requested > MAX_WORKING_SET_ENTRIES)
                {
                    requested = MAX_WORKING_SET_ENTRIES;
                }
                long byteCount64 = (requested + 1) * (long)entrySize;
                if (byteCount64 > Int32.MaxValue)
                {
                    return false;
                }

                int bufferBytes = (int)byteCount64;
                byte[] buffer = GetWorkingSetBuffer(bufferBytes);
                GCHandle pin = default(GCHandle);
                bool ok = false;
                try
                {
                    pin = GCHandle.Alloc(buffer, GCHandleType.Pinned);
                    ok = QueryWorkingSet(hProcess, pin.AddrOfPinnedObject(), (uint)bufferBytes);
                }
                finally
                {
                    if (pin.IsAllocated)
                    {
                        pin.Free();
                    }
                }

                if (ok)
                {
                    // First ULONG_PTR = number of entries actually written.
                    long count;
                    int entryOffset;
                    if (entrySize == 8)
                    {
                        count = BitConverter.ToInt64(buffer, 0);
                        entryOffset = 8;
                    }
                    else
                    {
                        count = BitConverter.ToInt32(buffer, 0);
                        entryOffset = 4;
                    }

                    if (count < 0)
                    {
                        count = 0;
                    }
                    if (count > requested)
                    {
                        count = requested;
                    }

                    // PSAPI_WORKING_SET_BLOCK: Protection:5, ShareCount:3, Shared:1,
                    // Node:3, VirtualPage:52 -> Shared is bit 8.
                    const long SHARED_BIT = 1L << 8;
                    long valid = count;
                    long shared = 0;
                    for (long i = 0; i < count; i++)
                    {
                        int offset = entryOffset + (int)(i * (long)entrySize);
                        long flags;
                        if (entrySize == 8)
                        {
                            flags = BitConverter.ToInt64(buffer, offset);
                        }
                        else
                        {
                            flags = BitConverter.ToInt32(buffer, offset);
                        }
                        if ((flags & SHARED_BIT) != 0)
                        {
                            shared++;
                        }
                    }

                    validPages = valid;
                    sharedPages = shared;
                    privateBytes = (valid - shared) * (long)pageSize;
                    return true;
                }

                int error = Marshal.GetLastWin32Error();
                if (error != ERROR_BAD_LENGTH)
                {
                    return false;
                }

                capacity = capacity * 2;
                if (capacity > MAX_WORKING_SET_ENTRIES)
                {
                    capacity = MAX_WORKING_SET_ENTRIES;
                }
            }

            return false;
        }
        public static bool TryGetHandleCount(IntPtr hProcess, out long handleCount)
        {
            uint count;
            handleCount = 0;
            if (!GetProcessHandleCount(hProcess, out count))
            {
                return false;
            }
            handleCount = (long)count;
            return true;
        }

        public static bool TryGetGuiResources(IntPtr hProcess, out long gdiObjects, out long userObjects)
        {
            gdiObjects = -1;
            userObjects = -1;
            bool gdiOk = false;
            bool userOk = false;

            uint gdi = GetGuiResources(hProcess, GR_GDIOBJECTS);
            int gdiError = Marshal.GetLastWin32Error();
            if (!(gdi == 0 && gdiError != 0))
            {
                gdiObjects = (long)gdi;
                gdiOk = true;
            }

            uint user = GetGuiResources(hProcess, GR_USEROBJECTS);
            int userError = Marshal.GetLastWin32Error();
            if (!(user == 0 && userError != 0))
            {
                userObjects = (long)user;
                userOk = true;
            }

            return gdiOk && userOk;
        }

        public static bool TryGetIoCounters(IntPtr hProcess, out IO_COUNTERS io)
        {
            return GetProcessIoCounters(hProcess, out io);
        }

        /// <summary>Thread IDs of a process, via a Toolhelp snapshot.</summary>
        public static int[] GetThreadIds(int pid)
        {
            IntPtr snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
            if (snapshot == IntPtr.Zero || snapshot == new IntPtr(-1))
            {
                return new int[0];
            }

            List<int> ids = new List<int>();
            try
            {
                THREADENTRY32 entry = new THREADENTRY32();
                entry.dwSize = (uint)Marshal.SizeOf(typeof(THREADENTRY32));
                bool ok = Thread32First(snapshot, ref entry);
                while (ok)
                {
                    if ((int)entry.th32OwnerProcessID == pid)
                    {
                        ids.Add((int)entry.th32ThreadID);
                    }
                    ok = Thread32Next(snapshot, ref entry);
                }
            }
            finally
            {
                CloseHandle(snapshot);
            }
            return ids.ToArray();
        }

        public static bool TryGetThreadTimes(uint threadId, out long kernel100ns, out long user100ns)
        {
            kernel100ns = 0;
            user100ns = 0;
            IntPtr hThread = OpenThread(THREAD_QUERY_LIMITED_INFORMATION, false, threadId);
            if (hThread == IntPtr.Zero)
            {
                hThread = OpenThread(THREAD_QUERY_INFORMATION, false, threadId);
            }
            if (hThread == IntPtr.Zero)
            {
                return false;
            }
            try
            {
                FILETIME_STRUCT created;
                FILETIME_STRUCT exited;
                FILETIME_STRUCT kernel;
                FILETIME_STRUCT user;
                // GetThreadTimes (et non GetProcessTimes) : un handle de thread n'accepte
                // pas GetProcessTimes, qui echouerait avec ERROR_INVALID_HANDLE.
                if (!GetThreadTimes(hThread, out created, out exited, out kernel, out user))
                {
                    return false;
                }
                kernel100ns = FileTimeToTicks(kernel);
                user100ns = FileTimeToTicks(user);
                return true;
            }
            finally
            {
                CloseHandle(hThread);
            }
        }

        public static bool TryGetCurrentProcessTimes(out long kernel100ns, out long user100ns)
        {
            return TryGetProcessTimes(GetCurrentProcess(), out kernel100ns, out user100ns);
        }

        /// <summary>
        /// Flattened [tid, cpu100ns, tid, cpu100ns, ...] list of per-thread cumulative CPU
        /// times. cpu100ns is -1 when the thread could not be opened/read.
        /// </summary>
        public static long[] ReadThreadCpu100ns(int pid)
        {
            int[] ids = GetThreadIds(pid);
            long[] pairs = new long[ids.Length * 2];
            for (int i = 0; i < ids.Length; i++)
            {
                long kernel;
                long user;
                bool ok = TryGetThreadTimes((uint)ids[i], out kernel, out user);
                pairs[i * 2] = (long)ids[i];
                pairs[i * 2 + 1] = ok ? (kernel + user) : -1L;
            }
            return pairs;
        }

        /// <summary>
        /// Thread count and per-thread cumulative CPU times in a single kernel query.
        /// Layout offsets below are for 64-bit Windows (the sampler's target platform);
        /// on a 32-bit host the method returns false and the caller falls back to
        /// Toolhelp32. cpu100ns is the sum of kernel + user time of the live thread.
        /// </summary>
        public static bool TryReadProcessThreads(int pid, out int threadCount, out long[] pairs)
        {
            threadCount = -1;
            pairs = null;
            if (IntPtr.Size != 8)
            {
                return false;
            }

            IntPtr buffer = IntPtr.Zero;
            int bufferBytes = 0;
            int returnedLength = 0;
            int status = 0;
            int requestedBytes = 1 << 20;

            for (int attempt = 0; attempt < 8; attempt++)
            {
                // Buffer persistant (voir systemInfoBuffer) : evite une allocation de
                // 1 Mo par echantillon et garde les pages chaudes entre deux ticks.
                buffer = GetSystemInfoBuffer(requestedBytes, out bufferBytes);
                status = NtQuerySystemInformation(
                    SystemProcessInformation,
                    buffer,
                    bufferBytes,
                    out returnedLength);
                if (status == 0)
                {
                    break;
                }
                if (status != STATUS_INFO_LENGTH_MISMATCH)
                {
                    return false;
                }
                requestedBytes = Math.Max(requestedBytes * 2, returnedLength + 65536);
            }
            if (status != 0)
            {
                return false;
            }

            int offset = 0;
            while (true)
            {
                int nextEntryOffset = Marshal.ReadInt32(buffer, offset);
                uint ownerPid = unchecked((uint)Marshal.ReadInt32(
                    buffer,
                    offset + SYSTEM_PROCESS_INFORMATION_PID_OFFSET_X64));
                if (unchecked((int)ownerPid) == pid)
                {
                    int count = Marshal.ReadInt32(
                        buffer,
                        offset + SYSTEM_PROCESS_INFORMATION_THREAD_COUNT_OFFSET_X64);
                    long[] result = new long[count * 2];
                    int threadBase = offset + SYSTEM_PROCESS_INFORMATION_THREADS_OFFSET_X64;
                    for (int i = 0; i < count; i++)
                    {
                        int entry = threadBase + i * SYSTEM_THREAD_INFORMATION_SIZE_X64;
                        int tid = Marshal.ReadInt32(
                            buffer,
                            entry + SYSTEM_THREAD_INFORMATION_TID_OFFSET_X64);
                        long kernel = Marshal.ReadInt64(
                            buffer,
                            entry + SYSTEM_THREAD_INFORMATION_KERNEL_OFFSET_X64);
                        long user = Marshal.ReadInt64(
                            buffer,
                            entry + SYSTEM_THREAD_INFORMATION_USER_OFFSET_X64);
                        result[i * 2] = (long)tid;
                        result[i * 2 + 1] = kernel + user;
                    }
                    threadCount = count;
                    pairs = result;
                    return true;
                }
                if (nextEntryOffset == 0)
                {
                    return false;
                }
                offset += nextEntryOffset;
            }
        }

        /// <summary>
        /// Persistent system-information buffer (see systemInfoBuffer). Grows on demand
        /// and is freed only when a larger buffer is needed; the OS reclaims it at exit.
        /// </summary>
        private static IntPtr GetSystemInfoBuffer(int requiredBytes, out int actualBytes)
        {
            lock (SystemInfoBufferLock)
            {
                if (systemInfoBuffer == IntPtr.Zero || systemInfoBufferBytes < requiredBytes)
                {
                    if (systemInfoBuffer != IntPtr.Zero)
                    {
                        Marshal.FreeHGlobal(systemInfoBuffer);
                    }
                    systemInfoBuffer = Marshal.AllocHGlobal(requiredBytes);
                    systemInfoBufferBytes = requiredBytes;
                }
                actualBytes = systemInfoBufferBytes;
                return systemInfoBuffer;
            }
        }

        /// <summary>Single read-only snapshot of all metrics.</summary>
        public static ProcessSample ReadSample(IntPtr hProcess, int pid, bool readPrivateWorkingSet)
        {
            return ReadSample(hProcess, pid, readPrivateWorkingSet, false);
        }

        /// <summary>
        /// Single read-only snapshot of all metrics. When readThreadCpu is true, the
        /// per-thread CPU times are collected in the same pass (ThreadCpuPairs).
        /// </summary>
        public static ProcessSample ReadSample(
            IntPtr hProcess,
            int pid,
            bool readPrivateWorkingSet,
            bool readThreadCpu)
        {
            ProcessSample sample = new ProcessSample();

            long kernel;
            long user;
            sample.TimesValid = TryGetProcessTimes(hProcess, out kernel, out user);
            sample.Kernel100ns = kernel;
            sample.User100ns = user;

            PROCESS_MEMORY_COUNTERS_EX memory;
            sample.MemoryValid = TryGetMemoryInfo(hProcess, out memory);
            if (sample.MemoryValid)
            {
                sample.WorkingSetBytes = (long)memory.WorkingSetSize.ToUInt64();
                sample.PeakWorkingSetBytes = (long)memory.PeakWorkingSetSize.ToUInt64();
                sample.CommitBytes = (long)memory.PagefileUsage.ToUInt64();
                sample.PeakCommitBytes = (long)memory.PeakPagefileUsage.ToUInt64();
                sample.PrivateUsageBytes = (long)memory.PrivateUsage.ToUInt64();
                sample.PageFaultCount = (long)memory.PageFaultCount;
            }

            if (readPrivateWorkingSet)
            {
                long privateBytes;
                long validPages;
                long sharedPages;
                sample.PrivateWorkingSetValid = TryGetPrivateWorkingSet(
                    hProcess,
                    sample.MemoryValid ? sample.WorkingSetBytes : 0,
                    out privateBytes,
                    out validPages,
                    out sharedPages);
                sample.PrivateWorkingSetBytes = privateBytes;
                sample.ValidPages = validPages;
                sample.SharedPages = sharedPages;
            }

            long handles;
            sample.HandleCountValid = TryGetHandleCount(hProcess, out handles);
            sample.HandleCount = handles;

            long gdi;
            long userObjects;
            sample.GuiResourcesValid = TryGetGuiResources(hProcess, out gdi, out userObjects);
            sample.GdiObjects = gdi;
            sample.UserObjects = userObjects;

            IO_COUNTERS io;
            sample.IoValid = TryGetIoCounters(hProcess, out io);
            if (sample.IoValid)
            {
                sample.IoReadBytes = (long)io.ReadTransferCount;
                sample.IoWriteBytes = (long)io.WriteTransferCount;
                sample.IoOtherBytes = (long)io.OtherTransferCount;
                sample.IoReadOperations = (long)io.ReadOperationCount;
                sample.IoWriteOperations = (long)io.WriteOperationCount;
                sample.IoOtherOperations = (long)io.OtherOperationCount;
            }

            int threadCount;
            long[] threadPairs;
            if (TryReadProcessThreads(pid, out threadCount, out threadPairs))
            {
                sample.ThreadCount = threadCount;
                if (readThreadCpu)
                {
                    sample.ThreadCpuPairs = threadPairs;
                }
            }
            else
            {
                // Repli Toolhelp32 (lent, uniquement si NtQuerySystemInformation echoue).
                int[] threadIds = GetThreadIds(pid);
                sample.ThreadIds = threadIds;
                sample.ThreadCount = threadIds.Length;
                if (readThreadCpu)
                {
                    long[] fallbackPairs = new long[threadIds.Length * 2];
                    for (int i = 0; i < threadIds.Length; i++)
                    {
                        long threadKernel;
                        long threadUser;
                        bool ok = TryGetThreadTimes((uint)threadIds[i], out threadKernel, out threadUser);
                        fallbackPairs[i * 2] = (long)threadIds[i];
                        fallbackPairs[i * 2 + 1] = ok ? (threadKernel + threadUser) : -1L;
                    }
                    sample.ThreadCpuPairs = fallbackPairs;
                }
            }

            return sample;
        }
    }
}

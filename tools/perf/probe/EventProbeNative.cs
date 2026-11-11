// EventProbeNative.cs
// Native + managed helper for EventProbe.ps1 (RiotSwitch perf campaign).
//
// Purpose: passively count the WinEvent stream that RiotSwitch's watcher receives
// through its two SetWinEventHook registrations, and (optionally) sample the CPU
// time of an external process (RiotSwitch.exe) on the same timeline, so the Lead
// campaign can correlate event rate with watcher CPU.
//
// Fidelity with src/RiotSwitcher.App/RiotWindowTracker.cs:
//   hook 1: SetWinEventHook(EVENT_OBJECT_CREATE, EVENT_OBJECT_LOCATIONCHANGE,
//                           NULL, cb, 0, 0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS)
//   hook 2: SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND,
//                           NULL, cb, 0, 0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS)
// Same range, same flags, same process/thread filters (0 = global).
//
// Target: Windows PowerShell 5.1 / .NET Framework 4.x => C# 5 syntax only
//         (no string interpolation, no null-conditional operator, no nameof,
//          no out-variables, no expression-bodied members, no auto-property
//          initializers, no pattern matching).
//
// The helper is strictly passive: it installs its own hooks, counts what Windows
// delivers to it, reads process CPU times with query-only access and never sends
// input, moves, shows or otherwise touches any window.
//
// Counting callback: it only increments plain counters on the pumping thread.
// It never calls BeginInvoke/Check/Find like the application does; therefore the
// measured CPU per event is a LOWER BOUND for the application's hook cost.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace RiotSwitchPerf.Probe
{
    /// <summary>Options for one probe run. Plain public fields (C# 5 friendly).</summary>
    public sealed class ProbeOptions
    {
        public int DurationMs = 60000;   // measurement window (hooks installed, counted)
        public int IntervalMs = 1000;    // series snapshot period
        public int ControlMs = 3000;     // baseline window, no hooks installed (pump cost)
        public int WarmupMs = 1000;      // hooks installed, JIT warmup, counters reset after
        public int SamplerPid = 0;       // external process to sample (0 = none)
        public int[] ExcludePids = null; // optional: do not count events of these processes
    }

    /// <summary>One series row (one interval).</summary>
    public sealed class SeriesSample
    {
        public int Index;
        public string IsoUtc;
        public double ElapsedS;
        public double WindowS;
        public long EventsDelta;
        public long EventsCumulative;
        public long IdObjectZeroDelta;
        public long IdObjectNonZeroDelta;
        public long CheckDelta;
        public long LocationChangeDelta;
        public long ForegroundDelta;
        public long[] TypeDeltas;
        public double ProbeCpuMs;
        public double ProbeCpuPctCore;
        public double ProbeUsPerEventWindow;
        public bool SamplerValid;
        public double SamplerCpuMs;
        public double SamplerCpuPctCore;
    }

    /// <summary>Result of one probe run.</summary>
    public sealed class ProbeResult
    {
        public string StartedUtc;
        public string EndedUtc;
        public double MeasureDurationS;
        public double ControlDurationS;
        public double WarmupDurationS;
        public int IntervalMs;

        public uint[] EventTypes;
        public string[] EventTypeNames;

        // Raw counters over the measurement window.
        public long TotalEvents;
        public long[] ByType;
        public long[] ByTypeIdObjectZero;
        public long IdObjectZero;
        public long IdObjectNonZero;
        public long CheckEvents;              // idObject == 0 AND type != LOCATIONCHANGE
        public long LocationChangeEvents;     // all LOCATIONCHANGE (any idObject)
        public long LocationChangeIdObjectZero;
        public long FilteredIdObjectNonZero;  // total - idObject==0
        public long ExcludedEvents;
        public long UnknownEvents;
        public bool TypeSumOk;
        public bool IdObjectSumOk;
        public bool CheckPartitionOk;

        // Hook installation.
        public bool HookObjectOk;
        public bool HookForegroundOk;
        public int HookObjectError;
        public int HookForegroundError;

        // Self cost (measurement window / control window).
        public double SelfCpuMeasureS;
        public double SelfCpuControlS;

        // External process sampler.
        public bool SamplerPresent;
        public int SamplerPid;
        public bool SamplerTimesOk;
        public double SamplerCpuMeasureS;

        public SeriesSample[] Series;
    }

    /// <summary>WinEvent probe: hooks + counters + message pump + series + sampler.</summary>
    public static class WinEventProbe
    {
        // ---- WinEvent constants (identical to AppNativeMethods / RiotWindowTracker) ----
        public const uint EVENT_OBJECT_CREATE = 0x8000;
        public const uint EVENT_OBJECT_DESTROY = 0x8001;
        public const uint EVENT_OBJECT_SHOW = 0x8002;
        public const uint EVENT_OBJECT_HIDE = 0x8003;
        public const uint EVENT_OBJECT_REORDER = 0x8004;
        public const uint EVENT_OBJECT_FOCUS = 0x8005;
        public const uint EVENT_OBJECT_SELECTION = 0x8006;
        public const uint EVENT_OBJECT_SELECTIONADD = 0x8007;
        public const uint EVENT_OBJECT_SELECTIONREMOVE = 0x8008;
        public const uint EVENT_OBJECT_SELECTIONWITHIN = 0x8009;
        public const uint EVENT_OBJECT_STATECHANGE = 0x800A;
        public const uint EVENT_OBJECT_LOCATIONCHANGE = 0x800B;
        public const uint EVENT_SYSTEM_FOREGROUND = 0x0003;

        public const uint WINEVENT_OUTOFCONTEXT = 0x0000;
        public const uint WINEVENT_SKIPOWNPROCESS = 0x0002;

        private const uint QS_ALLINPUT = 0x04FF;
        private const uint PM_REMOVE = 0x0001;
        private const uint WAIT_TIMEOUT = 0x00000102;
        private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
        private const uint PROCESS_QUERY_INFORMATION = 0x0400;

        private const int FOREGROUND_INDEX = 12;
        private const int TYPE_COUNT = 13;

        private static readonly uint[] TYPE_VALUES = new uint[]
        {
            EVENT_OBJECT_CREATE,          // 0x8000
            EVENT_OBJECT_DESTROY,         // 0x8001
            EVENT_OBJECT_SHOW,            // 0x8002
            EVENT_OBJECT_HIDE,            // 0x8003
            EVENT_OBJECT_REORDER,         // 0x8004
            EVENT_OBJECT_FOCUS,           // 0x8005
            EVENT_OBJECT_SELECTION,       // 0x8006
            EVENT_OBJECT_SELECTIONADD,    // 0x8007
            EVENT_OBJECT_SELECTIONREMOVE, // 0x8008
            EVENT_OBJECT_SELECTIONWITHIN, // 0x8009
            EVENT_OBJECT_STATECHANGE,     // 0x800A
            EVENT_OBJECT_LOCATIONCHANGE,  // 0x800B
            EVENT_SYSTEM_FOREGROUND       // 0x0003
        };

        private static readonly string[] TYPE_NAMES = new string[]
        {
            "EVENT_OBJECT_CREATE",
            "EVENT_OBJECT_DESTROY",
            "EVENT_OBJECT_SHOW",
            "EVENT_OBJECT_HIDE",
            "EVENT_OBJECT_REORDER",
            "EVENT_OBJECT_FOCUS",
            "EVENT_OBJECT_SELECTION",
            "EVENT_OBJECT_SELECTIONADD",
            "EVENT_OBJECT_SELECTIONREMOVE",
            "EVENT_OBJECT_SELECTIONWITHIN",
            "EVENT_OBJECT_STATECHANGE",
            "EVENT_OBJECT_LOCATIONCHANGE",
            "EVENT_SYSTEM_FOREGROUND"
        };

        // ---- callback ownership (must stay alive: never let the GC collect it) ----
        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        public delegate void WinEventDelegate(
            IntPtr hWinEventHook,
            uint eventType,
            IntPtr hwnd,
            int idObject,
            int idChild,
            uint dwEventThread,
            uint dwmsEventTime);

        private static readonly WinEventDelegate s_callback = OnWinEvent;

        // ---- mutable state (single pumping thread is the only reader/writer) ----
        private static IntPtr s_hookObject = IntPtr.Zero;
        private static IntPtr s_hookForeground = IntPtr.Zero;
        private static int[] s_excludePids;
        private static IntPtr s_samplerHandle = IntPtr.Zero;
        private static int s_samplerPid;

        private static long s_total;
        private static readonly long[] s_byType = new long[TYPE_COUNT];
        private static readonly long[] s_byTypeIdObjectZero = new long[TYPE_COUNT];
        private static long s_idObjectZero;
        private static long s_idObjectNonZero;
        private static long s_check;
        private static long s_locationChange;
        private static long s_locationChangeZero;
        private static long s_excluded;
        private static long s_unknown;

        private static Stopwatch s_watch;
        private static List<SeriesSample> s_series;
        private static double s_lastSnapshotElapsedS;
        private static long s_prevTotal;
        private static readonly long[] s_prevByType = new long[TYPE_COUNT];
        private static long s_prevIdObjectZero;
        private static long s_prevIdObjectNonZero;
        private static long s_prevCheck;
        private static long s_prevLocationChange;
        private static long s_prevForeground;
        private static long s_prevSelfCpu100ns;
        private static long s_prevSamplerCpu100ns;

        // ---- native interop ----
        [StructLayout(LayoutKind.Sequential)]
        private struct FILETIME
        {
            public uint dwLowDateTime;
            public uint dwHighDateTime;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MSG
        {
            public IntPtr hwnd;
            public uint message;
            public UIntPtr wParam;
            public IntPtr lParam;
            public uint time;
            public int ptX;
            public int ptY;
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SetWinEventHook(
            uint eventMin,
            uint eventMax,
            IntPtr hmodWinEventProc,
            WinEventDelegate lpfnWinEventProc,
            uint idProcess,
            uint idThread,
            uint dwFlags);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool UnhookWinEvent(IntPtr hWinEventHook);

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

        // Signature reelle : (nCount, pHandles, dwMilliseconds, dwWakeMask, dwFlags).
        // Attention : l'ordre differe de MsgWaitForMultipleObjects (qui prend fWaitAll).
        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint MsgWaitForMultipleObjectsEx(
            uint nCount,
            IntPtr pHandles,
            uint dwMilliseconds,
            uint dwWakeMask,
            uint dwFlags);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool PeekMessage(
            out MSG lpMsg,
            IntPtr hWnd,
            uint wMsgFilterMin,
            uint wMsgFilterMax,
            uint wRemoveMsg);

        [DllImport("user32.dll")]
        private static extern bool TranslateMessage(ref MSG lpMsg);

        [DllImport("user32.dll")]
        private static extern IntPtr DispatchMessage(ref MSG lpMsg);

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetProcessTimes(
            IntPtr hProcess,
            out FILETIME lpCreationTime,
            out FILETIME lpExitTime,
            out FILETIME lpKernelTime,
            out FILETIME lpUserTime);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        private static long FileTimeToLong(FILETIME ft)
        {
            return ((long)ft.dwHighDateTime << 32) | (long)ft.dwLowDateTime;
        }

        // ---- counting callback (near no-op: only in-memory increments) ----
        private static void OnWinEvent(
            IntPtr hHook,
            uint eventType,
            IntPtr hwnd,
            int idObject,
            int idChild,
            uint dwEventThread,
            uint dwmsEventTime)
        {
            int idx = -1;
            if (eventType >= EVENT_OBJECT_CREATE && eventType <= EVENT_OBJECT_LOCATIONCHANGE)
            {
                idx = (int)(eventType - EVENT_OBJECT_CREATE);
            }
            else if (eventType == EVENT_SYSTEM_FOREGROUND)
            {
                idx = FOREGROUND_INDEX;
            }

            // Optional fidelity option: ignore events generated by given processes
            // (e.g. the watcher process itself, which the app skips through
            // WINEVENT_SKIPOWNPROCESS, while our probe is a different process).
            if (s_excludePids != null && s_excludePids.Length > 0)
            {
                uint pid;
                GetWindowThreadProcessId(hwnd, out pid);
                int pidInt = (int)pid;
                for (int i = 0; i < s_excludePids.Length; i++)
                {
                    if (s_excludePids[i] == pidInt)
                    {
                        s_excluded++;
                        return;
                    }
                }
            }

            s_total++;
            if (idx >= 0)
            {
                s_byType[idx]++;
            }
            else
            {
                s_unknown++;
            }

            // Same discrimination order as RiotWindowTracker.OnWinEvent:
            //   1) idObject != 0            -> app returns (no Check)
            //   2) eventType == LOCATIONCHANGE -> app returns (no Check)
            //   3) otherwise                 -> app would BeginInvoke(Check)
            if (idObject == 0)
            {
                s_idObjectZero++;
                if (idx >= 0)
                {
                    s_byTypeIdObjectZero[idx]++;
                }
                if (eventType == EVENT_OBJECT_LOCATIONCHANGE)
                {
                    s_locationChangeZero++;
                }
                else
                {
                    s_check++;
                }
            }
            else
            {
                s_idObjectNonZero++;
            }

            if (eventType == EVENT_OBJECT_LOCATIONCHANGE)
            {
                s_locationChange++;
            }
        }

        // ---- helpers ----
        private static void ResetCounters()
        {
            s_total = 0;
            for (int i = 0; i < TYPE_COUNT; i++)
            {
                s_byType[i] = 0;
                s_byTypeIdObjectZero[i] = 0;
                s_prevByType[i] = 0;
            }
            s_idObjectZero = 0;
            s_idObjectNonZero = 0;
            s_check = 0;
            s_locationChange = 0;
            s_locationChangeZero = 0;
            s_excluded = 0;
            s_unknown = 0;
            s_prevTotal = 0;
            s_prevIdObjectZero = 0;
            s_prevIdObjectNonZero = 0;
            s_prevCheck = 0;
            s_prevLocationChange = 0;
            s_prevForeground = 0;
        }

        private static long ReadSelfCpu100ns()
        {
            FILETIME created;
            FILETIME exited;
            FILETIME kernel;
            FILETIME user;
            if (!GetProcessTimes(GetCurrentProcess(), out created, out exited, out kernel, out user))
            {
                return -1;
            }
            return FileTimeToLong(kernel) + FileTimeToLong(user);
        }

        private static bool TryReadProcessCpu100ns(IntPtr handle, out long cpu100ns)
        {
            cpu100ns = 0;
            if (handle == IntPtr.Zero)
            {
                return false;
            }
            FILETIME created;
            FILETIME exited;
            FILETIME kernel;
            FILETIME user;
            if (!GetProcessTimes(handle, out created, out exited, out kernel, out user))
            {
                return false;
            }
            cpu100ns = FileTimeToLong(kernel) + FileTimeToLong(user);
            return true;
        }

        private static IntPtr OpenSamplingHandle(int pid)
        {
            IntPtr handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, (uint)pid);
            if (handle == IntPtr.Zero)
            {
                handle = OpenProcess(PROCESS_QUERY_INFORMATION, false, (uint)pid);
            }
            return handle;
        }

        private static void DrainMessages()
        {
            MSG msg;
            // Translate/Dispatch are kept on purpose: without them some queued
            // WinEvent deliveries (notably idObject != 0 events) were empirically
            // lost in the self-test (498 vs 937 events), even though user32
            // invokes out-of-context callbacks during PeekMessage as well.
            while (PeekMessage(out msg, IntPtr.Zero, 0, 0, PM_REMOVE))
            {
                TranslateMessage(ref msg);
                DispatchMessage(ref msg);
            }
        }

        private static void PumpWait(uint waitMs)
        {
            uint r = MsgWaitForMultipleObjectsEx(0, IntPtr.Zero, waitMs, QS_ALLINPUT, 0);
            if (r == WAIT_TIMEOUT)
            {
                return;
            }
            // WAIT_OBJECT_0 (=0 with nCount=0) means input is available.
            // Drain unconditionally otherwise: out-of-context WinEvent callbacks are
            // invoked by user32 while the thread retrieves messages.
            DrainMessages();
        }

        private static void PumpFor(int durationMs, int pollMs)
        {
            Stopwatch sw = Stopwatch.StartNew();
            while (sw.ElapsedMilliseconds < durationMs)
            {
                int remaining = durationMs - (int)sw.ElapsedMilliseconds;
                int wait = remaining < pollMs ? remaining : pollMs;
                if (wait < 1)
                {
                    wait = 1;
                }
                PumpWait((uint)wait);
            }
        }

        private static bool InstallHooksInternal(out int objectError, out int foregroundError)
        {
            s_hookObject = SetWinEventHook(
                EVENT_OBJECT_CREATE,
                EVENT_OBJECT_LOCATIONCHANGE,
                IntPtr.Zero,
                s_callback,
                0,
                0,
                WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
            objectError = s_hookObject == IntPtr.Zero ? Marshal.GetLastWin32Error() : 0;

            s_hookForeground = SetWinEventHook(
                EVENT_SYSTEM_FOREGROUND,
                EVENT_SYSTEM_FOREGROUND,
                IntPtr.Zero,
                s_callback,
                0,
                0,
                WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
            foregroundError = s_hookForeground == IntPtr.Zero ? Marshal.GetLastWin32Error() : 0;

            return objectError == 0 && foregroundError == 0;
        }

        private static void UninstallHooks()
        {
            if (s_hookObject != IntPtr.Zero)
            {
                UnhookWinEvent(s_hookObject);
                s_hookObject = IntPtr.Zero;
            }
            if (s_hookForeground != IntPtr.Zero)
            {
                UnhookWinEvent(s_hookForeground);
                s_hookForeground = IntPtr.Zero;
            }
        }

        private static void Snapshot()
        {
            double now = s_watch.Elapsed.TotalSeconds;
            double window = now - s_lastSnapshotElapsedS;
            if (window < 0.000001)
            {
                window = 0.000001;
            }

            SeriesSample sample = new SeriesSample();
            sample.Index = s_series.Count;
            sample.IsoUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ");
            sample.ElapsedS = Math.Round(now, 6);
            sample.WindowS = Math.Round(window, 6);
            sample.EventsDelta = s_total - s_prevTotal;
            sample.EventsCumulative = s_total;
            sample.IdObjectZeroDelta = s_idObjectZero - s_prevIdObjectZero;
            sample.IdObjectNonZeroDelta = s_idObjectNonZero - s_prevIdObjectNonZero;
            sample.CheckDelta = s_check - s_prevCheck;
            sample.LocationChangeDelta = s_locationChange - s_prevLocationChange;
            sample.ForegroundDelta = s_byType[FOREGROUND_INDEX] - s_prevForeground;

            sample.TypeDeltas = new long[TYPE_COUNT];
            for (int i = 0; i < TYPE_COUNT; i++)
            {
                sample.TypeDeltas[i] = s_byType[i] - s_prevByType[i];
            }

            long selfCpu = ReadSelfCpu100ns();
            if (selfCpu >= 0 && s_prevSelfCpu100ns >= 0)
            {
                sample.ProbeCpuMs = (selfCpu - s_prevSelfCpu100ns) / 10000.0;
            }
            sample.ProbeCpuPctCore = (sample.ProbeCpuMs / 1000.0) / window * 100.0;
            sample.ProbeUsPerEventWindow = sample.EventsDelta > 0
                ? (sample.ProbeCpuMs * 1000.0) / sample.EventsDelta
                : 0.0;

            if (s_samplerHandle != IntPtr.Zero)
            {
                long samplerCpu;
                if (TryReadProcessCpu100ns(s_samplerHandle, out samplerCpu) && s_prevSamplerCpu100ns >= 0)
                {
                    sample.SamplerValid = true;
                    sample.SamplerCpuMs = (samplerCpu - s_prevSamplerCpu100ns) / 10000.0;
                    sample.SamplerCpuPctCore = (sample.SamplerCpuMs / 1000.0) / window * 100.0;
                    s_prevSamplerCpu100ns = samplerCpu;
                }
            }

            // Save baselines for next interval.
            s_lastSnapshotElapsedS = now;
            s_prevTotal = s_total;
            s_prevIdObjectZero = s_idObjectZero;
            s_prevIdObjectNonZero = s_idObjectNonZero;
            s_prevCheck = s_check;
            s_prevLocationChange = s_locationChange;
            s_prevForeground = s_byType[FOREGROUND_INDEX];
            for (int i = 0; i < TYPE_COUNT; i++)
            {
                s_prevByType[i] = s_byType[i];
            }
            s_prevSelfCpu100ns = selfCpu;

            s_series.Add(sample);
        }

        /// <summary>
        /// Cost in ns of one managed counting callback invocation (the exact
        /// OnWinEvent body: in-memory increments only, no Check/Find/BeginInvoke).
        /// Measured after Run() so it never pollutes the probe counters reported
        /// by the run. This is a LOWER BOUND of the delivery cost seen by the app:
        /// it excludes the kernel-to-user hop and the app's BeginInvoke(Check).
        /// </summary>
        public static double BenchmarkCallback(int iterations)
        {
            if (iterations < 10000)
            {
                iterations = 10000;
            }
            s_excludePids = null;
            ResetCounters();
            IntPtr fakeHook = new IntPtr(1);
            long cpu0 = ReadSelfCpu100ns();
            for (int i = 0; i < iterations; i++)
            {
                uint eventType = ((i & 1) == 0) ? EVENT_OBJECT_SHOW : EVENT_SYSTEM_FOREGROUND;
                OnWinEvent(fakeHook, eventType, IntPtr.Zero, 0, 0, 0, 0);
            }
            long cpu1 = ReadSelfCpu100ns();
            if (cpu0 < 0 || cpu1 < cpu0)
            {
                return -1.0;
            }
            return (cpu1 - cpu0) * 100.0 / (double)iterations;
        }

        /// <summary>One full probe run: control baseline, warmup, measurement with series.</summary>
        public static ProbeResult Run(ProbeOptions options)
        {
            if (options == null)
            {
                throw new ArgumentNullException("options");
            }
            if (options.DurationMs < 1000)
            {
                options.DurationMs = 1000;
            }
            if (options.IntervalMs < 100)
            {
                options.IntervalMs = 100;
            }
            if (options.ControlMs < 0)
            {
                options.ControlMs = 0;
            }
            if (options.WarmupMs < 0)
            {
                options.WarmupMs = 0;
            }

            s_excludePids = options.ExcludePids;
            s_series = new List<SeriesSample>();
            s_lastSnapshotElapsedS = 0.0;

            ProbeResult result = new ProbeResult();
            result.StartedUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ");
            result.IntervalMs = options.IntervalMs;
            result.EventTypes = new uint[TYPE_COUNT];
            Array.Copy(TYPE_VALUES, result.EventTypes, TYPE_COUNT);
            result.EventTypeNames = new string[TYPE_COUNT];
            Array.Copy(TYPE_NAMES, result.EventTypeNames, TYPE_COUNT);

            // ---- external CPU sampler (read-only) ----
            bool samplerPresent = false;
            if (options.SamplerPid > 0)
            {
                s_samplerPid = options.SamplerPid;
                s_samplerHandle = OpenSamplingHandle(options.SamplerPid);
                samplerPresent = s_samplerHandle != IntPtr.Zero;
            }
            result.SamplerPid = options.SamplerPid;
            result.SamplerPresent = samplerPresent;

            try
            {
                // ---- prewarm: JIT the pump loop and pay the first user32 entry
                // outside the control window, so the control cost reflects the
                // steady-state blocking loop instead of one-off startup costs. ----
                PumpFor(300, 300);

                // ---- control phase: no hooks, only the message pump ----
                double controlCpuS = 0.0;
                double controlDurS = 0.0;
                if (options.ControlMs > 0)
                {
                    Stopwatch controlWatch = Stopwatch.StartNew();
                    long controlCpu0 = ReadSelfCpu100ns();
                    PumpFor(options.ControlMs, 1000);
                    long controlCpu1 = ReadSelfCpu100ns();
                    controlWatch.Stop();
                    controlDurS = controlWatch.Elapsed.TotalSeconds;
                    if (controlCpu0 >= 0 && controlCpu1 >= controlCpu0)
                    {
                        controlCpuS = (controlCpu1 - controlCpu0) / 10000000.0;
                    }
                }
                result.ControlDurationS = Math.Round(controlDurS, 6);
                result.SelfCpuControlS = Math.Round(controlCpuS, 9);

                // ---- install the two hooks (identical to the app) ----
                int objectError;
                int foregroundError;
                bool hooksOk = InstallHooksInternal(out objectError, out foregroundError);
                result.HookObjectOk = objectError == 0 && s_hookObject != IntPtr.Zero;
                result.HookForegroundOk = foregroundError == 0 && s_hookForeground != IntPtr.Zero;
                result.HookObjectError = objectError;
                result.HookForegroundError = foregroundError;
                if (!hooksOk)
                {
                    throw new InvalidOperationException(
                        "SetWinEventHook failed (objectError=" + objectError.ToString() +
                        ", foregroundError=" + foregroundError.ToString() + ")");
                }

                // ---- warmup: let JIT compile the callback and the pump loop ----
                Stopwatch warmupWatch = Stopwatch.StartNew();
                if (options.WarmupMs > 0)
                {
                    PumpFor(options.WarmupMs, 1000);
                }
                warmupWatch.Stop();
                result.WarmupDurationS = Math.Round(warmupWatch.Elapsed.TotalSeconds, 6);

                // ---- measurement ----
                ResetCounters();
                long selfCpu0 = ReadSelfCpu100ns();
                long samplerCpu0 = 0;
                bool samplerTimesOk = false;
                if (samplerPresent)
                {
                    samplerTimesOk = TryReadProcessCpu100ns(s_samplerHandle, out samplerCpu0);
                }
                s_prevSelfCpu100ns = selfCpu0;
                s_prevSamplerCpu100ns = samplerTimesOk ? samplerCpu0 : -1;

                s_watch = Stopwatch.StartNew();
                int intervalMs = options.IntervalMs;
                int durationMs = options.DurationMs;
                long nextBoundaryMs = intervalMs;

                while (true)
                {
                    int nowMs = (int)s_watch.ElapsedMilliseconds;
                    int remaining = durationMs - nowMs;
                    if (remaining <= 0)
                    {
                        break;
                    }
                    int untilNext = (int)(nextBoundaryMs - nowMs);
                    if (untilNext < 1)
                    {
                        untilNext = 1;
                    }
                    int wait = remaining < untilNext ? remaining : untilNext;
                    if (wait < 1)
                    {
                        wait = 1;
                    }
                    PumpWait((uint)wait);
                    if ((int)s_watch.ElapsedMilliseconds >= nextBoundaryMs)
                    {
                        Snapshot();
                        while (nextBoundaryMs <= (int)s_watch.ElapsedMilliseconds)
                        {
                            nextBoundaryMs += intervalMs;
                        }
                    }
                }

                // Final snapshot so that sum(series deltas) == total events.
                Snapshot();
                s_watch.Stop();

                double measureDurS = s_watch.Elapsed.TotalSeconds;
                long selfCpu1 = ReadSelfCpu100ns();
                long samplerCpu1 = 0;
                bool samplerEndOk = samplerPresent && TryReadProcessCpu100ns(s_samplerHandle, out samplerCpu1);

                result.MeasureDurationS = Math.Round(measureDurS, 6);
                if (selfCpu0 >= 0 && selfCpu1 >= selfCpu0)
                {
                    result.SelfCpuMeasureS = Math.Round((selfCpu1 - selfCpu0) / 10000000.0, 9);
                }
                result.SamplerTimesOk = samplerTimesOk && samplerEndOk;
                if (result.SamplerTimesOk && samplerCpu1 >= samplerCpu0)
                {
                    result.SamplerCpuMeasureS = Math.Round((samplerCpu1 - samplerCpu0) / 10000000.0, 9);
                }

                // ---- raw counters and consistency checks ----
                result.TotalEvents = s_total;
                result.ByType = new long[TYPE_COUNT];
                Array.Copy(s_byType, result.ByType, TYPE_COUNT);
                result.ByTypeIdObjectZero = new long[TYPE_COUNT];
                Array.Copy(s_byTypeIdObjectZero, result.ByTypeIdObjectZero, TYPE_COUNT);
                result.IdObjectZero = s_idObjectZero;
                result.IdObjectNonZero = s_idObjectNonZero;
                result.CheckEvents = s_check;
                result.LocationChangeEvents = s_locationChange;
                result.LocationChangeIdObjectZero = s_locationChangeZero;
                result.FilteredIdObjectNonZero = s_idObjectNonZero;
                result.ExcludedEvents = s_excluded;
                result.UnknownEvents = s_unknown;

                long typeSum = 0;
                for (int i = 0; i < TYPE_COUNT; i++)
                {
                    typeSum += s_byType[i];
                }
                result.TypeSumOk = (typeSum + s_unknown) == s_total;
                result.IdObjectSumOk = (s_idObjectZero + s_idObjectNonZero) == s_total;
                result.CheckPartitionOk = (s_check + s_locationChangeZero + s_idObjectNonZero) == s_total;

                result.Series = s_series.ToArray();
                result.EndedUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ");
                return result;
            }
            finally
            {
                UninstallHooks();
                if (s_samplerHandle != IntPtr.Zero)
                {
                    CloseHandle(s_samplerHandle);
                    s_samplerHandle = IntPtr.Zero;
                }
            }
        }
    }
}

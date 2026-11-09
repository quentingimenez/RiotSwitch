namespace RiotSwitcher.Core.Switching;

/// <summary>
/// Événement nommé qui signale « un switch est en cours » aux autres instances.
/// </summary>
public static class SwitchSignal
{
    public static IDisposable Activate()
    {
        EventWaitHandle? handle = null;
        try
        {
            handle = new EventWaitHandle(false, EventResetMode.ManualReset, AppInfo.SwitchingEventName);
            handle.Set();
            return new Scope(handle);
        }
        catch
        {
            handle?.Dispose();
            return new NullScope();
        }
    }

    public static bool IsActive()
    {
        try
        {
            using var handle = EventWaitHandle.OpenExisting(AppInfo.SwitchingEventName);
            return handle.WaitOne(0);
        }
        catch
        {
            return false;
        }
    }

    private sealed class Scope : IDisposable
    {
        private EventWaitHandle? _handle;

        public Scope(EventWaitHandle handle) => _handle = handle;

        public void Dispose()
        {
            var handle = Interlocked.Exchange(ref _handle, null);
            if (handle is null) return;

            try { handle.Reset(); } catch { }
            handle.Dispose();
        }
    }

    private sealed class NullScope : IDisposable
    {
        public void Dispose()
        {
        }
    }
}

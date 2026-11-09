namespace RiotSwitcher.Core.Infrastructure;

public static class Wait
{
    public static bool Until(Func<bool> condition, TimeSpan timeout, TimeSpan poll, CancellationToken cancellationToken = default)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (condition()) return true;
            Thread.Sleep(poll);
        }

        return condition();
    }

    public static async Task<bool> UntilAsync(
        Func<bool> condition,
        TimeSpan timeout,
        TimeSpan poll,
        CancellationToken cancellationToken = default)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (condition()) return true;
            await Task.Delay(poll, cancellationToken).ConfigureAwait(false);
        }

        return condition();
    }
}

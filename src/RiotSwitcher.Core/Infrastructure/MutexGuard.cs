namespace RiotSwitcher.Core.Infrastructure;

/// <summary>Mutex nommé inter-processus, relâché à la fin du using.</summary>
public sealed class MutexGuard : IDisposable
{
    private Mutex? _mutex;
    private bool _owned;

    private MutexGuard(Mutex mutex, bool owned)
    {
        _mutex = mutex;
        _owned = owned;
    }

    /// <summary>Retourne null si le mutex n'est pas obtenu dans le délai.</summary>
    public static MutexGuard? TryAcquire(string name, TimeSpan timeout)
    {
        if (string.IsNullOrWhiteSpace(name)) throw new ArgumentException("Nom de mutex requis.", nameof(name));

        Mutex? mutex = null;
        try
        {
            mutex = new Mutex(initiallyOwned: false, name, out _);
            bool owned;
            try
            {
                owned = mutex.WaitOne(timeout);
            }
            catch (AbandonedMutexException)
            {
                // Propriétaire précédent mort : on reprend le mutex.
                owned = true;
            }

            if (!owned)
            {
                mutex.Dispose();
                return null;
            }

            return new MutexGuard(mutex, owned);
        }
        catch
        {
            mutex?.Dispose();
            return null;
        }
    }

    public void Dispose()
    {
        var mutex = _mutex;
        if (mutex is null) return;
        _mutex = null;

        try
        {
            if (_owned) mutex.ReleaseMutex();
        }
        catch
        {
            // Ne pas masquer l'erreur d'origine.
        }
        finally
        {
            mutex.Dispose();
        }
    }
}

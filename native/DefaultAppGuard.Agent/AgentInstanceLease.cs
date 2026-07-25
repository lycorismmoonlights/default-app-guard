using System.Security.Principal;

namespace DefaultAppGuard.Agent;

public sealed class AgentInstanceLease : IDisposable
{
    private readonly Mutex mutex;
    private bool ownsMutex;

    private AgentInstanceLease(Mutex mutex)
    {
        this.mutex = mutex;
        ownsMutex = true;
    }

    public static AgentInstanceLease? TryAcquire()
    {
        var userIdentity = WindowsIdentity.GetCurrent().User?.Value
            ?? Environment.UserName;
        var mutex = new Mutex(
            initiallyOwned: false,
            $"Local\\DefaultAppGuard.Agent.{userIdentity}");
        try
        {
            if (!mutex.WaitOne(TimeSpan.Zero))
            {
                mutex.Dispose();
                return null;
            }
        }
        catch (AbandonedMutexException)
        {
            // Ownership is granted when a previous process terminated abruptly.
        }

        return new AgentInstanceLease(mutex);
    }

    public void Dispose()
    {
        if (ownsMutex)
        {
            ownsMutex = false;
            mutex.ReleaseMutex();
        }

        mutex.Dispose();
    }
}

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;

namespace Suchmaschine.Persistence
{
    // Contains no PowerShell objects, delegates or runspace-affine callbacks.
    public sealed class DatabasePool : IDisposable
    {
        private readonly object gate = new object();
        private readonly Queue<IDisposable> available;
        private bool disposed;
        private int waiting;
        public Guid Id { get; } = Guid.NewGuid();
        public int Capacity { get; }
        public int AvailableCount { get { lock (gate) return available.Count; } }
        public int WaitingCount { get { lock (gate) return waiting; } }
        public bool IsDisposed { get { lock (gate) return disposed; } }

        // Ownership transfers only on successful construction.
        public DatabasePool(IDisposable[] connections)
        {
            if (connections == null || connections.Length == 0)
                throw new ArgumentException("At least one connection is required.", nameof(connections));
            var unique = new HashSet<IDisposable>(ReferenceEqualityComparer.Instance);
            foreach (var connection in connections)
                if (connection == null || !unique.Add(connection))
                    throw new ArgumentException("Connections must be non-null and distinct.", nameof(connections));
            available = new Queue<IDisposable>(connections);
            Capacity = connections.Length;
        }

        public DatabaseLease Borrow(int timeoutMilliseconds)
        {
            if (timeoutMilliseconds < 0)
                throw new ArgumentOutOfRangeException(nameof(timeoutMilliseconds));
            var clock = Stopwatch.StartNew();
            lock (gate)
            {
                while (true)
                {
                    if (disposed) throw new ObjectDisposedException(nameof(DatabasePool));
                    if (available.Count > 0) return new DatabaseLease(this, available.Dequeue());
                    long remaining = timeoutMilliseconds - clock.ElapsedMilliseconds;
                    if (remaining <= 0) throw new TimeoutException("Timed out waiting for a database lease.");
                    waiting++;
                    try { Monitor.Wait(gate, (int)remaining); }
                    finally { waiting--; }
                }
            }
        }

        internal void Return(IDisposable connection)
        {
            lock (gate)
            {
                if (!disposed)
                {
                    available.Enqueue(connection);
                    Monitor.PulseAll(gate);
                    return;
                }
            }
            connection.Dispose();
        }

        // Never closes a connection still in use. Outstanding leases close on return.
        public void Dispose()
        {
            IDisposable[] idle;
            lock (gate)
            {
                if (disposed) return;
                disposed = true;
                idle = available.ToArray();
                available.Clear();
                Monitor.PulseAll(gate);
            }
            var errors = new List<Exception>();
            foreach (var connection in idle)
            {
                try { connection.Dispose(); }
                catch (Exception error) { errors.Add(error); }
            }
            if (errors.Count > 0) throw new AggregateException(errors);
        }
    }

    public sealed class DatabaseLease : IDisposable
    {
        private readonly DatabasePool pool;
        private readonly IDisposable connection;
        private int returned;
        private int claimed;
        public Guid PoolId => pool.Id;
        public bool IsReturned => Volatile.Read(ref returned) != 0;
        public object Connection { get { ThrowIfReturned(); return connection; } }
        internal DatabaseLease(DatabasePool pool, IDisposable connection)
        {
            this.pool = pool;
            this.connection = connection;
        }
        public void ThrowIfReturned()
        {
            if (IsReturned) throw new ObjectDisposedException(nameof(DatabaseLease));
        }
        public object ClaimRepositoryConnection()
        {
            ThrowIfReturned();
            if (Interlocked.CompareExchange(ref claimed, 1, 0) != 0)
                throw new InvalidOperationException("A lease may have only one repository adapter.");
            return connection;
        }
        public void Dispose()
        {
            if (Interlocked.Exchange(ref returned, 1) == 0) pool.Return(connection);
        }
    }
}

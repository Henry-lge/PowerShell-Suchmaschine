using module '../src/Model/Datei.psm1'
using module '../src/Persistence/SqliteDateiRepository.psm1'

Describe 'DatabasePool' {
    BeforeAll {
        $script:workerScript = Get-Content (Join-Path $PSScriptRoot 'fixtures/DatabasePoolWorker.ps1') -Raw
        # Absolute module paths let hosted runspaces resolve using module independently of cwd.
        $script:workerScript = $script:workerScript.Replace(
            '../../src/Model/Datei.psm1',
            ((Join-Path $PSScriptRoot '../src/Model/Datei.psm1') -replace "'", "''")
        ).Replace(
            '../../src/Persistence/SqliteDateiRepository.psm1',
            ((Join-Path $PSScriptRoot '../src/Persistence/SqliteDateiRepository.psm1') -replace "'", "''")
        )
        function Start-PoolWorker([int]$Id, [string]$Mode = 'Write') {
            $powershell = [powershell]::Create()
            [void]$powershell.AddScript($script:workerScript)
            foreach ($argument in @($script:pool, $script:ready, $script:gate, $script:root, $Id, $Mode)) {
                [void]$powershell.AddArgument($argument)
            }
            $handle = $powershell.BeginInvoke()
            $worker = [pscustomobject]@{ PowerShell = $powershell; Handle = $handle }
            $script:workers.Add($worker)
            return $worker
        }
        function Complete-PoolWorker($Worker) {
            if (-not $Worker.Handle.AsyncWaitHandle.WaitOne(15000)) {
                throw 'Worker did not finish within 15 seconds.'
            }
            $output = $Worker.PowerShell.EndInvoke($Worker.Handle)
            if ($Worker.PowerShell.HadErrors) {
                throw ($Worker.PowerShell.Streams.Error | Out-String)
            }
            return $output
        }
        function Wait-PoolWaiter {
            $clock = [System.Diagnostics.Stopwatch]::StartNew()
            while ($script:pool.WaitingCount -eq 0 -and $clock.ElapsedMilliseconds -lt 10000) {
                [System.Threading.Thread]::Sleep(10)
            }
            $script:pool.WaitingCount | Should -Be 1
        }
    }
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) ('database-pool-' + [guid]::NewGuid().ToString('N'))
        $script:path = Join-Path $script:root 'index.sqlite3'
        $script:pool = Initialize-DatabasePool -DatabasePath $script:path -PoolSize 2
        $script:workers = [System.Collections.Generic.List[object]]::new()
        $script:leases = [System.Collections.Generic.List[object]]::new()
        $script:ready = [System.Threading.CountdownEvent]::new(2)
        $script:gate = [System.Threading.ManualResetEventSlim]::new($false)
    }
    AfterEach {
        $script:gate.Set()
        $script:pool.Dispose()
        foreach ($lease in $script:leases) { $lease.Dispose() }
        foreach ($worker in $script:workers) {
            if (-not $worker.Handle.IsCompleted) { $worker.PowerShell.Stop() }
            $worker.PowerShell.Dispose()
        }
        $script:ready.Dispose()
        $script:gate.Dispose()
        Remove-Item -LiteralPath $script:root -Recurse -Force
    }

    It 'rejects invalid sizes and negative timeouts without opening extra connections' {
        foreach ($size in @(0, -1, 1025)) {
            { Initialize-DatabasePool -DatabasePath $script:path -PoolSize $size } | Should -Throw
        }
        { $script:pool.Borrow(-1) } | Should -Throw
        $script:pool.AvailableCount | Should -Be 2
    }

    It 'bounds exclusive leases, times out, and reuses exactly its original connections' {
        $first = $script:pool.Borrow(0)
        $second = $script:pool.Borrow(0)
        $script:leases.Add($first)
        $script:leases.Add($second)
        $connection = $first.Connection
        [object]::ReferenceEquals($connection, $second.Connection) | Should -BeFalse
        { $script:pool.Borrow(0) } | Should -Throw '*Timed out*'
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        { $script:pool.Borrow(80) } | Should -Throw '*Timed out*'
        $clock.ElapsedMilliseconds | Should -BeGreaterOrEqual 60
        $first.Dispose()
        $first.Dispose()
        for ($index = 0; $index -lt 40; $index++) {
            $next = $script:pool.Borrow(0)
            try { [object]::ReferenceEquals($connection, $next.Connection) | Should -BeTrue }
            finally { $next.Dispose() }
        }
        $script:pool.AvailableCount | Should -Be 1
        { $first.ThrowIfReturned() } | Should -Throw '*disposed*'
    }

    It 'closes idle connections on dispose without provider pooling' {
        $lease = $script:pool.Borrow(0)
        $connection = $lease.Connection
        $connection.ConnectionString | Should -Match '(?i)Pooling=False'
        $lease.Dispose()
        $script:pool.Dispose()
        $connection.State.ToString() | Should -Be 'Closed'
        $script:pool.IsDisposed | Should -BeTrue
        { $script:pool.Borrow(0) } | Should -Throw '*disposed*'
    }

    It 'returns after exceptions and invalidates stale adapters even after reborrow' {
        $lease = $script:pool.Borrow(0)
        $held = $script:pool.Borrow(0)
        $script:leases.Add($held)
        $connection = $lease.Connection
        $repository = [SqliteDateiRepository]::new($lease)
        { [SqliteDateiRepository]::new($lease) } | Should -Throw '*only one*'
        try {
            { $repository.Save([Datei]::new()) } | Should -Throw '*non-empty*'
        }
        finally { $lease.Dispose() }
        $next = $script:pool.Borrow(0)
        try {
            [object]::ReferenceEquals($connection, $next.Connection) | Should -BeTrue
            { $repository.Get($script:path) } | Should -Throw
        }
        finally { $next.Dispose(); $repository.Dispose(); $held.Dispose() }
        $script:pool.AvailableCount | Should -Be 2
    }

    It 'rolls back a SQL failure and reuses the same connection for successful writes' {
        $lease = $script:pool.Borrow(0)
        $held = $script:pool.Borrow(0)
        $script:leases.Add($lease)
        $script:leases.Add($held)
        $connection = $lease.Connection
        $repository = [SqliteDateiRepository]::new($lease)
        try {
            $command = $connection.CreateCommand()
            try {
                $command.CommandText = @"
CREATE TRIGGER reject_pool_file
BEFORE INSERT ON files_metadata
WHEN NEW.filename = 'reject'
BEGIN
    SELECT RAISE(ABORT, 'rejected by pool rollback test');
END;
"@
                [void]$command.ExecuteNonQuery()
            }
            finally { $command.Dispose() }
            $valid = [Datei]::new()
            $valid.Path = Join-Path $script:root 'valid-first.txt'
            $valid.HasContent = $true
            $valid.Content = 'rollbackpoolmarker'
            $rejected = [Datei]::new()
            $rejected.Path = Join-Path $script:root 'reject.txt'
            $rejected.HasContent = $true
            $rejected.Content = 'rollbackpoolmarker'

            { $repository.SaveBatch([Datei[]]@($valid, $rejected)) } |
                Should -Throw '*rejected by pool rollback test*'
            $repository.GetMany([string[]]@($valid.Path, $rejected.Path)).Count | Should -Be 0
            $repository.Search('rollbackpoolmarker', 100, $null).Count | Should -Be 0
        }
        finally { $repository.Dispose(); $lease.Dispose() }

        # Holding the other slot makes the identity check deterministic.
        $next = $script:pool.Borrow(0)
        $script:leases.Add($next)
        $fresh = $null
        try {
            [object]::ReferenceEquals($connection, $next.Connection) | Should -BeTrue
            $fresh = [SqliteDateiRepository]::new($next)
            $fresh.GetPathsUnder($script:root).Count | Should -Be 0
            $fresh.Search('rollbackpoolmarker', 100, $null).Count | Should -Be 0
            $fresh.Save($valid)
            $fresh.Get($valid.Path).Path | Should -Be $valid.Path
            $fresh.Search('rollbackpoolmarker', 100, $null).Count | Should -Be 1
        }
        finally {
            if ($null -ne $fresh) { $fresh.Dispose() }
            $next.Dispose()
            $held.Dispose()
        }
        $script:pool.AvailableCount | Should -Be 2
    }

    It 'runs overlapping worker-local repositories on the same pool with consistent metadata and FTS' {
        $first = Start-PoolWorker 1
        $second = Start-PoolWorker 2
        $script:ready.Wait(15000) | Should -BeTrue
        # Both workers hold leases before either can continue: actual overlap proof.
        $script:pool.AvailableCount | Should -Be 0
        $first.Handle.IsCompleted | Should -BeFalse
        $second.Handle.IsCompleted | Should -BeFalse
        $script:gate.Set()
        $one = Complete-PoolWorker $first
        $two = Complete-PoolWorker $second
        [object]::ReferenceEquals($one.Pool, $script:pool) | Should -BeTrue
        [object]::ReferenceEquals($two.Pool, $script:pool) | Should -BeTrue
        $one.PoolId | Should -Be $script:pool.Id
        $one.ThreadId | Should -Not -Be $two.ThreadId
        [object]::ReferenceEquals($one.Connection, $two.Connection) | Should -BeFalse
        $lease = $script:pool.Borrow(0)
        $repository = [SqliteDateiRepository]::new($lease)
        try {
            $repository.GetPathsUnder($script:root).Count | Should -Be 2
            $repository.Search('newpoolmarker', 100, $null).Count | Should -Be 2
            $repository.Search('oldpoolmarker', 100, $null).Count | Should -Be 0
            $repository.Search('removedpoolmarker', 100, $null).Count | Should -Be 0
            $command = $lease.Connection.CreateCommand()
            try {
                $command.CommandText = 'SELECT COUNT(*) FROM files_fts f LEFT JOIN files_metadata m ON m.id=f.file_id WHERE m.id IS NULL;'
                $command.ExecuteScalar() | Should -Be 0
            }
            finally { $command.Dispose() }
        }
        finally { $repository.Dispose() }
        $script:pool.AvailableCount | Should -Be 2
    }

    It 'wakes a blocked borrower when a connection returns' {
        1..2 | ForEach-Object { $script:leases.Add($script:pool.Borrow(0)) }
        $worker = Start-PoolWorker 1 'Wait'
        Wait-PoolWaiter
        $worker.Handle.IsCompleted | Should -BeFalse
        $script:leases[0].Dispose()
        $output = Complete-PoolWorker $worker
        $output.PoolId | Should -Be $script:pool.Id
        $script:pool.AvailableCount | Should -Be 1
    }

    It 'wakes waiters on shutdown and closes outstanding connections only on return' {
        1..2 | ForEach-Object { $script:leases.Add($script:pool.Borrow(0)) }
        $connection = $script:leases[0].Connection
        $repository = [SqliteDateiRepository]::new($script:leases[0])
        $worker = Start-PoolWorker 1 'Wait'
        Wait-PoolWaiter
        $script:pool.Dispose()
        $script:pool.Dispose()
        { $script:pool.Borrow(0) } | Should -Throw '*disposed*'
        $worker.Handle.AsyncWaitHandle.WaitOne(10000) | Should -BeTrue
        { Complete-PoolWorker $worker } | Should -Throw '*disposed*'
        $connection.State.ToString() | Should -Be 'Open'
        $repository.GetPathsUnder($script:root).Count | Should -Be 0
        $repository.Dispose()
        $connection.State.ToString() | Should -Be 'Closed'
        { $repository.Get($script:path) } | Should -Throw
        $script:pool.AvailableCount | Should -Be 0
    }
}

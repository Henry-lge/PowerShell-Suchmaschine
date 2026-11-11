using module '../src/Persistence/SqliteDateiRepository.psm1'

#requires -Version 7.2
[CmdletBinding()]
param(
    [ValidateRange(1, 10000)][int]$Repetitions = 10,
    [ValidateRange(0, 1000)][int]$WarmupRuns = 2,
    [ValidateRange(1, 1000000)][int]$Operations = 500,
    [string]$AssemblyPath = (Join-Path $PSScriptRoot '../lib/sqlite')
)

$ErrorActionPreference = 'Stop'
$root = Join-Path ([System.IO.Path]::GetTempPath()) ('database-pool-benchmark-' + [guid]::NewGuid().ToString('N'))
$pool = $null
try {
    $pool = Initialize-DatabasePool -DatabasePath (Join-Path $root 'index.sqlite3') -PoolSize 1 -AssemblyPath $AssemblyPath
    $lease = $pool.Borrow(0)
    try {
        $connectionString = $lease.Connection.ConnectionString
        $connectionType = $lease.Connection.GetType()
    }
    finally { $lease.Dispose() }

    for ($run = -$WarmupRuns; $run -lt $Repetitions; $run++) {
        # Alternate order to reduce systematic cache/order bias.
        $modes = if ($run % 2 -eq 0) { @('Pooled', 'RepeatedOpen') } else { @('RepeatedOpen', 'Pooled') }
        foreach ($mode in $modes) {
            $clock = [System.Diagnostics.Stopwatch]::StartNew()
            for ($operation = 0; $operation -lt $Operations; $operation++) {
                $lease = $null
                $connection = $null
                try {
                    if ($mode -eq 'Pooled') {
                        $lease = $pool.Borrow(0)
                        $connection = $lease.Connection
                    }
                    else {
                        $connection = [System.Activator]::CreateInstance($connectionType, [object[]]@($connectionString))
                        $connection.Open()
                    }
                    $command = $connection.CreateCommand()
                    try {
                        $command.CommandText = 'SELECT COUNT(*) FROM files_metadata;'
                        [void]$command.ExecuteScalar()
                    }
                    finally { $command.Dispose() }
                }
                finally {
                    if ($null -ne $lease) { $lease.Dispose() }
                    elseif ($null -ne $connection) { $connection.Dispose() }
                }
            }
            $clock.Stop()
            if ($run -ge 0) {
                [pscustomobject]@{
                    Mode = $mode
                    Repetition = $run + 1
                    Repetitions = $Repetitions
                    WarmupRuns = $WarmupRuns
                    Operations = $Operations
                    Milliseconds = $clock.Elapsed.TotalMilliseconds
                    OperationsPerSecond = $Operations / $clock.Elapsed.TotalSeconds
                    PowerShellVersion = $PSVersionTable.PSVersion.ToString()
                    ProviderVersion = $connectionType.Assembly.GetName().Version.ToString()
                }
            }
        }
    }
}
finally {
    if ($null -ne $pool) { $pool.Dispose() }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}

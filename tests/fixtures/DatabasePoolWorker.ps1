using module '../../src/Model/Datei.psm1'
using module '../../src/Persistence/SqliteDateiRepository.psm1'

param($Pool, $Ready, $Gate, [string]$Root, [int]$WorkerId, [string]$Mode = 'Write')

$ErrorActionPreference = 'Stop'
$lease = $null
$repository = $null
try {
    if ($Mode -eq 'Wait') { [void]$Ready.Signal() }
    $lease = $Pool.Borrow(10000)
    $repository = [SqliteDateiRepository]::new($lease)
    if ($Mode -ne 'Wait') {
        [void]$Ready.Signal()
        if (-not $Gate.Wait(10000)) { throw 'Worker gate timed out.' }
    }
    if ($Mode -eq 'Write') {
        $file = [Datei]::new()
        $file.Path = Join-Path $Root "worker-$WorkerId.txt"
        $file.Name = "worker-$WorkerId.txt"
        $file.Extension = '.txt'
        $file.Content = 'oldpoolmarker'
        $file.HasContent = $true
        $repository.Save($file)
        $file.Content = 'newpoolmarker'
        $repository.Save($file)
        $temporary = [Datei]::new()
        $temporary.Path = Join-Path $Root "removed-$WorkerId.txt"
        $temporary.Content = 'removedpoolmarker'
        $temporary.HasContent = $true
        $repository.Save($temporary)
        $repository.Remove($temporary.Path)
    }
    [pscustomobject]@{
        Pool = $Pool
        PoolId = $lease.PoolId
        Connection = $lease.Connection
        ThreadId = [System.Threading.Thread]::CurrentThread.ManagedThreadId
    }
}
finally {
    if ($null -ne $repository) { $repository.Dispose() }
    if ($null -ne $lease) { $lease.Dispose() }
}

using module '../src/Model/Datei.psm1'
using module '../src/Persistence/DateiRepository.psm1'
using module '../src/Persistence/SqliteDateiRepository.psm1'
using module '../src/Crawler/Crawler.psm1'

Describe 'Database interface compatibility (<Mode>)' -ForEach @(
    @{ Mode = 'Standalone' }
    @{ Mode = 'Pooled' }
) {
    BeforeAll {
        function New-InterfaceDatei([string]$Path) {
            $file = [Datei]::new()
            $file.Path = $Path
            $file.Name = [System.IO.Path]::GetFileName($Path)
            $file.Extension = '.txt'
            $file.Content = 'interfacemarker'
            $file.HasContent = $true
            $file.LastWriteTimeUtc = [datetime]::UtcNow
            return $file
        }
    }
    BeforeEach {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ('database-interfaces-' + [guid]::NewGuid().ToString('N'))
        $path = Join-Path $root 'index.sqlite3'
        $pool = $null
        $lease = $null
        $database = $null
        if ($Mode -eq 'Pooled') {
            $pool = Initialize-DatabasePool -DatabasePath $path -PoolSize 1
            $lease = $pool.Borrow(0)
            $database = [SqliteDateiRepository]::new($lease)
        }
        else { $database = Initialize-Database -DatabasePath $path }
    }
    AfterEach {
        if ($null -ne $database) { $database.Dispose() }
        if ($null -ne $lease) { $lease.Dispose() }
        if ($null -ne $pool) { $pool.Dispose() }
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }

    It 'preserves Add-File, Sync-Files and Search-Query including pipeline use' {
        $first = New-InterfaceDatei (Join-Path $root 'first.txt')
        $second = New-InterfaceDatei (Join-Path $root 'second.txt')
        $third = New-InterfaceDatei (Join-Path $root 'third.txt')
        $added = $first | Add-File -Database $database
        [object]::ReferenceEquals($added, $first) | Should -BeTrue
        $sync = @($second, $third) | Sync-Files -Database $database
        $sync.Added | Should -Be 2
        $sync = @($second, $third) | Sync-Files -Database $database
        $sync.Unchanged | Should -Be 2
        $second.LastWriteTimeUtc = $second.LastWriteTimeUtc.AddMinutes(1)
        $second.Content = 'updatedinterfacemarker'
        (Sync-Files -Database $database -Files @($second)).Updated | Should -Be 1
        $contentResults = @(
            Search-Query -Database $database -Query 'interfacemarker' `
                -SearchMode Content -Limit 1 -Extension 'txt'
        )
        $contentResults | Should -HaveCount 1
        $filenameResults = @(
            Search-Query -Database $database -Query 'first' -SearchMode FileName
        )
        $filenameResults | Should -HaveCount 1
        $filenameResults[0].File.Path | Should -Be $first.Path
        (Search-Query -Database $database -Query 'first' -SearchMode Content) |
            Should -BeNullOrEmpty

        $results = @(
            Search-Query -Database $database -SearchMode Content `
                -Query 'updatedinterfacemarker'
        )
        $results.Count | Should -Be 1
        $results[0].File.Path | Should -Be $second.Path
    }

    It 'supports actual crawler scans and unchanged rescans without replacing the interface' {
        $fixture = Join-Path $root 'documents'
        [void][System.IO.Directory]::CreateDirectory($fixture)
        Set-Content -LiteralPath (Join-Path $fixture 'notes.txt') -Value 'crawlerinterfacemarker'
        Set-Content -LiteralPath (Join-Path $fixture 'readme.md') -Value '# crawlerinterfacemarker'
        $crawler = [Crawler]::new()
        $crawler.Repository = $database

        $crawler.ScanFolder($fixture)
        $crawler.Errors.Count | Should -Be 0
        $database.GetPathsUnder($fixture).Count | Should -Be 2
        $results = @(
            Search-Query -Database $database -Query 'crawlerinterfacemarker' `
                -SearchMode Both
        )
        $results | Should -HaveCount 2
        (Search-Query -Database $database -Query 'notes' -SearchMode FileName).File.Path |
            Should -Be (Join-Path $fixture 'notes.txt')
        (Search-Query -Database $database -Query 'notes' -SearchMode Content) |
            Should -BeNullOrEmpty
        $crawler.ScanFolder($fixture)
        $crawler.Errors.Count | Should -Be 0
        $database.GetPathsUnder($fixture).Count | Should -Be 2
        @(
            Search-Query -Database $database -Query 'crawlerinterfacemarker' `
                -SearchMode Both
        ) | Should -HaveCount 2
    }

    It 'preserves every DateiRepository operation and the crawler assignment contract' {
        $database | Should -BeOfType ([DateiRepository])
        $crawler = [Crawler]::new()
        $crawler.Repository = $database
        [object]::ReferenceEquals($crawler.Repository, $database) | Should -BeTrue
        $first = New-InterfaceDatei (Join-Path $root 'one.txt')
        $second = New-InterfaceDatei (Join-Path $root 'two.txt')
        $third = New-InterfaceDatei (Join-Path $root 'three.txt')
        $database.Save($first)
        $database.SaveBatch([Datei[]]@($second, $third))
        $database.Get($first.Path).Path | Should -Be $first.Path
        $database.GetMany([string[]]@($first.Path, $second.Path, $third.Path)).Count | Should -Be 3
        $database.GetPathsUnder($root).Count | Should -Be 3
        $database.Remove($first.Path)
        $database.RemoveBatch([string[]]@($second.Path, $third.Path))
        $database.Get($first.Path) | Should -BeNullOrEmpty
        $database.GetPathsUnder($root).Count | Should -Be 0
        $database.Search('interfacemarker', 100, $null).Count | Should -Be 0
    }
}

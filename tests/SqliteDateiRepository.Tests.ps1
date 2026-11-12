using module "../src/Model/Datei.psm1"
using module "../src/Persistence/SqliteDateiRepository.psm1"

Describe "SqliteDateiRepository" {
    BeforeAll {
        function New-TestDatei {
            param([Parameter(Mandatory)][string]$Path)

            $name = [System.IO.Path]::GetFileName($Path)
            $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
            $now = [datetime]::UtcNow
            $file = [Datei]::new()
            $file.Name = $name
            $file.Path = $Path
            $file.Extension = $extension
            $file.Size = 128
            $file.CreationTimeUtc = $now.AddDays(-2)
            $file.LastWriteTimeUtc = $now.AddDays(-1)
            $file.IndexedAtUtc = $now
            $file.Content = "originalmarker searchabletext"
            $file.HasContent = $true
            return $file
        }

        function Invoke-TestSql {
            param([Parameter(Mandatory)][string]$Sql)

            $connectionProperty = [SqliteDateiRepository].GetProperty(
                "_connection",
                [System.Reflection.BindingFlags]"Instance,Public,NonPublic"
            )
            $command = $connectionProperty.GetValue($script:database).CreateCommand()
            try {
                $command.CommandText = $Sql
                return $command.ExecuteScalar()
            }
            finally {
                $command.Dispose()
            }
        }

        $script:testRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
            "powershell-suchmaschine-tests-" + [guid]::NewGuid().ToString("N")
        )
        # Die SQLite-Runtime liegt im Repository (lib/sqlite) und wird von
        # Install-Sqlite.ps1 bei Bedarf eingerichtet; ein eigener Temp-Ordner
        # scheitert unter Windows in AfterAll, weil die geladene native
        # e_sqlite3.dll bis zum Prozessende gesperrt ist.
        $script:assemblyPath = Join-Path (Join-Path $PSScriptRoot "..") "lib/sqlite"
        [System.IO.Directory]::CreateDirectory($script:testRoot) | Out-Null
    }

    BeforeEach {
        $script:databasePath = Join-Path $script:testRoot (
            [guid]::NewGuid().ToString("N") + ".sqlite3"
        )
        $script:database = Initialize-Database `
            -DatabasePath $script:databasePath `
            -AssemblyPath $script:assemblyPath
    }

    AfterEach {
        if ($null -ne $script:database) {
            $script:database.Dispose()
            $script:database = $null
        }

        foreach ($suffix in @("", "-shm", "-wal")) {
            $file = "$script:databasePath$suffix"
            if (Test-Path -LiteralPath $file) {
                Remove-Item -LiteralPath $file -Force
            }
        }
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It "creates its database and schema on initialization" {
        Test-Path -LiteralPath $script:databasePath -PathType Leaf | Should -BeTrue
        @($script:database.GetPathsUnder($script:testRoot)) | Should -HaveCount 0
    }

    It "saves and retrieves file metadata" {
        $file = New-TestDatei -Path (Join-Path $script:testRoot "notes.txt")

        $script:database.Save($file)
        $stored = $script:database.Get($file.Path)

        $stored | Should -Not -BeNullOrEmpty
        $stored.Name | Should -Be "notes.txt"
        $stored.Extension | Should -Be ".txt"
        $stored.Size | Should -Be 128
        $stored.LastWriteTimeUtc.Ticks | Should -Be $file.LastWriteTimeUtc.Ticks
        $stored.HasContent | Should -BeTrue
    }

    It "reconstructs the original path casing while exposing a normalized extension" {
        $file = New-TestDatei -Path (Join-Path $script:testRoot "Notes.TXT")

        $script:database.Save($file)
        $stored = $script:database.Get($file.Path)

        $stored.Path | Should -Be $file.Path
        $stored.Name | Should -Be "Notes.TXT"
        $stored.Extension | Should -Be ".txt"
    }

    It "compares file paths case-insensitively except on Linux" {
        $file = New-TestDatei -Path (Join-Path $script:testRoot "CaseSensitive.txt")
        $script:database.Save($file)

        $alternateCasePath = Join-Path $script:testRoot "CASESENSITIVE.TXT"
        $stored = $script:database.Get($alternateCasePath)

        if ($global:IsLinux) {
            $stored | Should -BeNullOrEmpty
        }
        else {
            $stored.Path | Should -Be $file.Path
        }
    }

    It "updates an existing path instead of creating a duplicate" {
        $file = New-TestDatei -Path (Join-Path $script:testRoot "notes.txt")
        $script:database.Save($file)
        $file.Content = "replacement searchabletext"
        $file.LastWriteTimeUtc = $file.LastWriteTimeUtc.AddMinutes(1)
        $file.IndexedAtUtc = $file.IndexedAtUtc.AddMinutes(1)

        $script:database.Save($file)

        $script:database.GetPathsUnder($script:testRoot) | Should -HaveCount 1
        (Search-Query -Database $script:database -Query "replacement").Count |
            Should -Be 1
        (Search-Query -Database $script:database -Query "originalmarker").Count |
            Should -Be 0
    }

    It "uses metadata IDs as FTS rowids despite gaps and updates" {
        $metadataOnly = New-TestDatei -Path (Join-Path $script:testRoot "metadata.txt")
        $metadataOnly.HasContent = $false
        $file = New-TestDatei -Path (Join-Path $script:testRoot "indexed.txt")
        $script:database.SaveBatch([Datei[]]@($metadataOnly, $file))
        $script:database.Save($file)

        (Invoke-TestSql "SELECT rowid FROM files_fts WHERE filename = 'indexed.txt';") |
            Should -Be 2
        (Invoke-TestSql "SELECT count(*) FROM files_fts WHERE rowid = file_id;") |
            Should -Be 2
        (Search-Query -Database $script:database -Query "originalmarker").File.Path |
            Should -Be $file.Path

        $file.HasContent = $false
        $script:database.Save($file)
        (Invoke-TestSql "SELECT count(*) FROM files_fts;") | Should -Be 2
        (Search-Query -Database $script:database -Query "originalmarker" -SearchMode Content) |
            Should -BeNullOrEmpty
        (Search-Query -Database $script:database -Query "indexed" -SearchMode FileName).File.Path |
            Should -Be $file.Path
        $script:database.Get($file.Path).HasContent | Should -BeFalse
    }

    It "searches filenames, content, or both and indexes metadata-only filenames" {
        $file = New-TestDatei -Path (Join-Path $script:testRoot "filenameonlymarker.txt")
        $file.Content = "bodyonlymarker"
        $script:database.Save($file)

        $metadataOnly = New-TestDatei -Path (Join-Path $script:testRoot "metadataonlymarker.bin")
        $metadataOnly.HasContent = $false
        $metadataOnly.Content = $null
        $script:database.Save($metadataOnly)

        $filenameResults = Search-Query -Database $script:database `
            -Query "filenameonlymarker" -SearchMode FileName
        $filenameResults.File.Path | Should -Be $file.Path
        $filenameResults.Snippet | Should -Match "\[filenameonlymarker\]"
        (Search-Query -Database $script:database -Query "filenameonlymarker").File.Path |
            Should -Be $file.Path
        (Search-Query -Database $script:database -Query "filenameonlymarker" `
            -SearchMode Content) | Should -BeNullOrEmpty
        (Search-Query -Database $script:database -Query "bodyonlymarker" `
            -SearchMode FileName) | Should -BeNullOrEmpty
        (Search-Query -Database $script:database -Query "bodyonlymarker" `
            -SearchMode Content).File.Path | Should -Be $file.Path
        (Search-Query -Database $script:database -Query "metadataonlymarker" `
            -SearchMode FileName).File.Path | Should -Be $metadataOnly.Path
        (Search-Query -Database $script:database -Query "bodyonlymarker" `
            -SearchMode Both).File.Path | Should -Be $file.Path
    }

    It "indexes full text and returns a snippet and positive relevance score" {
        $file = New-TestDatei -Path (Join-Path $script:testRoot "alpha.txt")
        $file.Content = "A unique searchmarker appears in this document."
        $script:database.Save($file)

        $results = Search-Query -Database $script:database -Query "searchmarker"

        $results | Should -HaveCount 1
        $results[0].File.Path | Should -Be $file.Path
        $results[0].Snippet | Should -Match "\[searchmarker\]"
        $results[0].Score | Should -BeGreaterThan 0
    }

    It "filters search results by extension" {
        $textFile = New-TestDatei -Path (Join-Path $script:testRoot "report.txt")
        $pdfFile = New-TestDatei -Path (Join-Path $script:testRoot "report.pdf")
        $textFile.Content = "extensionmarker text record"
        $pdfFile.Content = "extensionmarker pdf record"
        $script:database.SaveBatch([Datei[]]@($textFile, $pdfFile))

        $results = Search-Query `
            -Database $script:database `
            -Query "extensionmarker" `
            -Extension "TXT"

        $results | Should -HaveCount 1
        $results[0].File.Extension | Should -Be ".txt"
    }

    It "searches literal punctuation in filenames without FTS syntax errors" {
        $text = New-TestDatei -Path (Join-Path $script:testRoot 'hsw.txt')
        $pdf = New-TestDatei -Path (Join-Path $script:testRoot 'hsw.pdf')
        $script:database.SaveBatch([Datei[]]@($text, $pdf))

        @(Search-Query -Database $script:database -Query '.txt' -Literal).File.Name | Should -Be 'hsw.txt'
        @(Search-Query -Database $script:database -Query '.' -Literal) | Should -HaveCount 2
        @(Search-Query -Database $script:database -Query 'hsw' -Literal) | Should -HaveCount 2
        @(Search-Query -Database $script:database -Query '.' -Literal -Extension 'TXT').File.Name | Should -Be 'hsw.txt'
        @(Search-Query -Database $script:database -Query '.' -Literal -Limit 1) | Should -HaveCount 1
        @(Search-Query -Database $script:database -Query '.' -Literal -SearchMode Content) | Should -HaveCount 0
    }

    It "returns punctuation filename matches through the GUI JSON adapter" {
        $file = New-TestDatei -Path (Join-Path $script:testRoot 'adapter.txt')
        $script:database.Save($file)
        $adapter = Join-Path $PSScriptRoot '../Invoke-GuiSearch.ps1'

        foreach ($query in @('.txt', '.')) {
            $request = @{ query = $query; limit = 100 } | ConvertTo-Json -Compress
            $json = $request | & (Get-Process -Id $PID).Path -NoProfile -NonInteractive `
                -File $adapter -DatabasePath $script:databasePath
            $response = $json | ConvertFrom-Json
            $response.ok | Should -BeTrue
            $response.count | Should -Be 1
            $response.results[0].fileName | Should -Be 'adapter.txt'
        }
    }

    It "escapes wildcard characters and FTS quotes in literal searches" {
        $file = New-TestDatei -Path (Join-Path $script:testRoot 'rate_100%.txt')
        $other = New-TestDatei -Path (Join-Path $script:testRoot 'rateX100x.txt')
        $file.Content = 'quoted content marker'
        $script:database.SaveBatch([Datei[]]@($file, $other))

        @(Search-Query -Database $script:database -Query '_100%' -Literal -SearchMode FileName).File.Name |
            Should -Be 'rate_100%.txt'
        @(Search-Query -Database $script:database -Query '"quoted content"' -Literal -SearchMode Content) |
            Should -HaveCount 1
        @(Search-Query -Database $script:database -Query 'quoted OR missing' -Literal -SearchMode Content) |
            Should -HaveCount 0
        @(Search-Query -Database $script:database -Query 'quoted OR missing' -SearchMode Content) |
            Should -HaveCount 1
    }

    It "deduplicates content and filename matches in literal searches" {
        $file = New-TestDatei -Path (Join-Path $script:testRoot 'marker.txt')
        $file.Content = 'marker appears here'
        $script:database.Save($file)

        @(Search-Query -Database $script:database -Query 'marker' -Literal) | Should -HaveCount 1
        @(Search-Query -Database $script:database -Query 'marker' -Literal -SearchMode FileName) | Should -HaveCount 1
        @(Search-Query -Database $script:database -Query 'marker' -Literal -SearchMode Content) | Should -HaveCount 1
    }

    It "returns no results for blank queries and unmatched terms" {
        $file = New-TestDatei -Path (Join-Path $script:testRoot "notes.txt")
        $script:database.Save($file)

        (Search-Query -Database $script:database -Query "  ").Count | Should -Be 0
        (Search-Query -Database $script:database -Query "notpresent").Count |
            Should -Be 0
    }

    It "removes a file from both metadata and the full-text index" {
        $file = New-TestDatei -Path (Join-Path $script:testRoot "remove.txt")
        $file.Content = "deletemarker"
        $script:database.Save($file)

        $script:database.Remove($file.Path)

        $script:database.Get($file.Path) | Should -BeNullOrEmpty
        (Search-Query -Database $script:database -Query "deletemarker").Count |
            Should -Be 0
    }

    It "removes multiple batches including duplicate and missing paths" {
        $files = [Datei[]]@(for ($index = 0; $index -lt 605; $index++) {
            New-TestDatei -Path (Join-Path $script:testRoot "remove-$index.txt")
        })
        $keep = New-TestDatei -Path (Join-Path $script:testRoot "keep.txt")
        $script:database.SaveBatch($files + [Datei[]]@($keep))
        $paths = [string[]]@($files | ForEach-Object { $_.Path })
        $paths += @($files[0].Path, (Join-Path $script:testRoot "missing.txt"))

        $script:database.RemoveBatch($paths)
        $script:database.RemoveBatch([string[]]@())

        $script:database.GetPathsUnder($script:testRoot) | Should -HaveCount 1
        (Invoke-TestSql "SELECT count(*) FROM files_fts;") | Should -Be 1
        (Search-Query -Database $script:database -Query "originalmarker").File.Path |
            Should -Be $keep.Path
    }

    It "validates all removal paths before deleting anything" {
        $file = New-TestDatei -Path (Join-Path $script:testRoot "keep.txt")
        $script:database.Save($file)

        { $script:database.RemoveBatch([string[]]@($file.Path, "")) } | Should -Throw

        $script:database.Get($file.Path) | Should -Not -BeNullOrEmpty
        (Invoke-TestSql "SELECT count(*) FROM files_fts;") | Should -Be 1
    }

    It "rolls back FTS and metadata deletions across removal batches" {
        $files = [Datei[]]@(for ($index = 0; $index -lt 301; $index++) {
            New-TestDatei -Path (Join-Path $script:testRoot "rollback-$index.txt")
        })
        $script:database.SaveBatch($files)
        [void](Invoke-TestSql @"
CREATE TRIGGER reject_removal BEFORE DELETE ON files_metadata
WHEN OLD.filename = 'rollback-300'
BEGIN
    SELECT RAISE(ABORT, 'rejected by removal test');
END;
"@)

        {
            $script:database.RemoveBatch([string[]]@($files | ForEach-Object { $_.Path }))
        } | Should -Throw "*rejected by removal test*"

        (Invoke-TestSql "SELECT count(*) FROM files_metadata;") | Should -Be 301
        (Invoke-TestSql "SELECT count(*) FROM files_fts;") | Should -Be 301
        @(Search-Query -Database $script:database -Query "originalmarker" -Limit 1000) |
            Should -HaveCount 301
    }

    It "returns paths under a folder without matching similarly prefixed folders" {
        $nested = New-TestDatei -Path (
            Join-Path $script:testRoot "nested/inside.txt"
        )
        $outside = New-TestDatei -Path (
            Join-Path "$script:testRoot-other" "outside.txt"
        )
        $script:database.SaveBatch([Datei[]]@($nested, $outside))

        $paths = $script:database.GetPathsUnder(
            (Join-Path $script:testRoot "nested")
        )

        $paths | Should -HaveCount 1
        $paths[0] | Should -Be $nested.Path
    }

    It "filters wildcard characters literally when finding paths under a folder" {
        $wildcardFolder = New-TestDatei -Path (
            Join-Path $script:testRoot "wild%_scope/inside.txt"
        )
        $notUnderFolder = New-TestDatei -Path (
            Join-Path $script:testRoot "wildXXscope/outside.txt"
        )
        $script:database.SaveBatch([Datei[]]@($wildcardFolder, $notUnderFolder))

        $paths = $script:database.GetPathsUnder(
            (Join-Path $script:testRoot "wild%_scope")
        )

        $paths | Should -HaveCount 1
        $paths[0] | Should -Be $wildcardFolder.Path
    }

    It "returns direct and deeply nested files but not sibling-prefix folders" {
        $folder = Join-Path $script:testRoot "scope"
        $direct = New-TestDatei -Path (Join-Path $folder "direct.txt")
        $nested = New-TestDatei -Path (Join-Path $folder "child/deep/nested.txt")
        $sibling = New-TestDatei -Path (Join-Path "$folder-other" "outside.txt")
        $script:database.SaveBatch([Datei[]]@($direct, $nested, $sibling))

        $paths = $script:database.GetPathsUnder($folder)

        $paths | Should -HaveCount 2
        $paths | Should -Contain $direct.Path
        $paths | Should -Contain $nested.Path
    }

    It "accepts a trailing separator without changing the result" {
        $folder = Join-Path $script:testRoot "scope"
        $file = New-TestDatei -Path (Join-Path $folder "child/inside.txt")
        $script:database.Save($file)

        $paths = $script:database.GetPathsUnder(
            $folder + [System.IO.Path]::DirectorySeparatorChar
        )

        $paths | Should -HaveCount 1
        $paths[0] | Should -Be $file.Path
    }

    It "finds direct and nested paths when the requested folder is a filesystem root" {
        $root = [System.IO.Path]::GetPathRoot($script:testRoot)
        $direct = New-TestDatei -Path (Join-Path $root "root-level.txt")
        $nested = New-TestDatei -Path (Join-Path $script:testRoot "child/nested.txt")
        $script:database.SaveBatch([Datei[]]@($direct, $nested))

        $paths = $script:database.GetPathsUnder($root)

        $paths | Should -HaveCount 2
        $paths | Should -Contain $direct.Path
        $paths | Should -Contain $nested.Path
    }

    It "keeps platform-specific ASCII path casing semantics" {
        $folder = Join-Path $script:testRoot "CaseScope"
        $file = New-TestDatei -Path (Join-Path $folder "child/inside.txt")
        $script:database.Save($file)

        $paths = @($script:database.GetPathsUnder(
            (Join-Path $script:testRoot "casescope")
        ))

        if ($IsLinux) {
            $paths | Should -HaveCount 0
        }
        else {
            $paths | Should -HaveCount 1
            $paths[0] | Should -BeExactly $file.Path
        }
    }

    It "keeps platform-specific Unicode path casing semantics" {
        $folder = Join-Path $script:testRoot "unicode/Äpfel"
        $direct = New-TestDatei -Path (Join-Path $folder "direct.txt")
        $nested = New-TestDatei -Path (Join-Path $folder "child/nested.txt")
        $outside = New-TestDatei -Path (Join-Path $script:testRoot "unicode/Andere/outside.txt")
        $script:database.SaveBatch([Datei[]]@($direct, $nested, $outside))

        $paths = @($script:database.GetPathsUnder(
            (Join-Path $script:testRoot "unicode/äpfel")
        ))

        if ($IsLinux) {
            $paths | Should -HaveCount 0
        }
        else {
            $paths | Should -HaveCount 2
            $paths | Should -Contain $direct.Path
            $paths | Should -Contain $nested.Path
        }
        $script:database.GetPathsUnder($folder) | Should -HaveCount 2
    }

    It "returns no paths for an absent folder in a populated index" {
        $file = New-TestDatei -Path (Join-Path $script:testRoot "other/inside.txt")
        $script:database.Save($file)

        @($script:database.GetPathsUnder(
            (Join-Path $script:testRoot "absent")
        )) | Should -HaveCount 0
    }

    It "narrows SQL candidates and treats LIKE metacharacters literally" {
        # ASCII root keeps this a selective-query test even with a Unicode temp path.
        $root = [System.IO.Path]::GetPathRoot($script:testRoot)
        $folder = Join-Path $root "query%_scope"
        if ($IsLinux) { $folder += '\literal' }
        # Path.Combine preserves a literal backslash on Linux; Join-Path rewrites it.
        $direct = New-TestDatei -Path ([System.IO.Path]::Combine($folder, "direct.txt"))
        $nested = New-TestDatei -Path (
            [System.IO.Path]::Combine($folder, "child", "nested.txt")
        )
        $sibling = New-TestDatei -Path (
            [System.IO.Path]::Combine("$folder-other", "outside.txt")
        )
        $wildcardMatch = New-TestDatei -Path (
            [System.IO.Path]::Combine($folder.Replace('%_', 'XX'), "child", "outside.txt")
        )
        $script:database.SaveBatch([Datei[]]@($direct, $nested, $sibling, $wildcardMatch))
        $command = $script:database.NewPathsUnderCommand($folder)
        try {
            $reader = $command.ExecuteReader()
            try {
                $count = 0
                while ($reader.Read()) { $count++ }
            }
            finally { $reader.Dispose() }
        }
        finally { $command.Dispose() }

        # Unlike public-result tests, this fails if SQL again returns the entire index.
        $count | Should -Be 2
        $script:database.GetPathsUnder($folder) | Should -HaveCount 2
    }

    It "uses indexed searches for the actual folder candidate query" {
        $root = [System.IO.Path]::GetPathRoot($script:testRoot)
        $folder = Join-Path $root "query-plan-scope"
        $command = $script:database.NewPathsUnderCommand($folder)
        $command.CommandText = "EXPLAIN QUERY PLAN " + $command.CommandText
        $details = [System.Collections.Generic.List[string]]::new()
        try {
            $reader = $command.ExecuteReader()
            try {
                while ($reader.Read()) { $details.Add([string]$reader['detail']) }
            }
            finally { $reader.Dispose() }
        }
        finally { $command.Dispose() }

        # Check the access strategy, not version-dependent index names or plan IDs.
        ($details -join "`n") | Should -Match 'SEARCH files_metadata .*directory_path'
        ($details -join "`n") | Should -Not -Match 'SCAN files_metadata'
    }

    It "retrieves many paths in bounded SQLite batches" {
        $file = New-TestDatei -Path (Join-Path $script:testRoot "bulk-existing.txt")
        $script:database.Save($file)
        $paths = [System.Collections.Generic.List[string]]::new()
        $paths.Add($file.Path)
        for ($index = 0; $index -lt 605; $index++) {
            $paths.Add((Join-Path $script:testRoot "missing-$index.txt"))
        }

        $stored = $script:database.GetMany($paths.ToArray())

        $stored.Count | Should -Be 1
        $stored[$file.Path].Name | Should -Be "bulk-existing.txt"
        { $script:database.GetMany([string[]]@($file.Path, "")) } |
            Should -Throw
    }

    It "uses a transaction to persist a batch and rejects invalid records" {
        $file = New-TestDatei -Path (Join-Path $script:testRoot "valid.txt")
        $invalid = [Datei]::new()

        { $script:database.SaveBatch([Datei[]]@($file, $invalid)) } |
            Should -Throw
        $script:database.Get($file.Path) | Should -BeNullOrEmpty
    }

    It "rolls back every write when a record fails during a transaction" {
        $connectionProperty = [SqliteDateiRepository].GetProperty(
            "_connection",
            [System.Reflection.BindingFlags]"Instance,Public,NonPublic"
        )
        $connection = $connectionProperty.GetValue($script:database)
        $command = $connection.CreateCommand()
        $command.CommandText = @"
CREATE TRIGGER reject_test_file
BEFORE INSERT ON files_metadata
WHEN NEW.filename = 'reject'
BEGIN
    SELECT RAISE(ABORT, 'rejected by transaction test');
END;
"@
        [void]$command.ExecuteNonQuery()
        $command.Dispose()

        $valid = New-TestDatei -Path (Join-Path $script:testRoot "valid-first.txt")
        $rejected = New-TestDatei -Path (Join-Path $script:testRoot "reject.txt")

        {
            $script:database.SaveBatch([Datei[]]@($valid, $rejected))
        } | Should -Throw "*rejected by transaction test*"

        $script:database.Get($valid.Path) | Should -BeNullOrEmpty
    }

    It "synchronizes changed files and skips unchanged files" {
        $file = New-TestDatei -Path (Join-Path $script:testRoot "sync.txt")
        $first = Sync-Files -Database $script:database -Files @($file)
        $again = Sync-Files -Database $script:database -Files @($file)
        $file.LastWriteTimeUtc = $file.LastWriteTimeUtc.AddMinutes(1)
        $file.Content = "sync updatedmarker"
        $updated = Sync-Files -Database $script:database -Files @($file)

        $first.Added | Should -Be 1
        $again.Unchanged | Should -Be 1
        $updated.Updated | Should -Be 1
        (Search-Query -Database $script:database -Query "updatedmarker").Count |
            Should -Be 1
    }

    It "retains indexed content when reopened from disk" {
        $file = New-TestDatei -Path (Join-Path $script:testRoot "persistent.txt")
        $file.Content = "persistentmarker"
        $script:database.Save($file)
        $script:database.Dispose()
        $script:database = Initialize-Database `
            -DatabasePath $script:databasePath `
            -AssemblyPath $script:assemblyPath

        $results = Search-Query -Database $script:database -Query "persistentmarker"

        $results | Should -HaveCount 1
        $results[0].File.Path | Should -Be $file.Path
    }

    It "keeps the current FTS schema and indexed data when reopened" {
        $metadataOnly = New-TestDatei -Path (Join-Path $script:testRoot "metadata.txt")
        $metadataOnly.HasContent = $false
        $first = New-TestDatei -Path (Join-Path $script:testRoot "first.txt")
        $second = New-TestDatei -Path (Join-Path $script:testRoot "second.txt")
        $script:database.SaveBatch([Datei[]]@($metadataOnly, $first, $second))
        [void](Invoke-TestSql @"
CREATE TRIGGER guard_fts_migration BEFORE INSERT ON files_fts_data
BEGIN
    SELECT RAISE(ABORT, 'unexpected FTS rebuild');
END;
"@)
        $script:database.Dispose()
        $script:database = Initialize-Database `
            -DatabasePath $script:databasePath `
            -AssemblyPath $script:assemblyPath

        (Invoke-TestSql "SELECT count(*) FROM pragma_table_info('files_fts') WHERE name = 'filename';") |
            Should -Be 1
        (Invoke-TestSql "SELECT count(*) FROM files_fts WHERE rowid != file_id;") |
            Should -Be 0
        (Search-Query -Database $script:database -Query "metadata" -SearchMode FileName).File.Path |
            Should -Be $metadataOnly.Path
        (Search-Query -Database $script:database -Query "originalmarker").Count |
            Should -Be 2
        (Invoke-TestSql "SELECT count(*) FROM sqlite_master WHERE name = 'guard_fts_migration';") |
            Should -Be 1
        [void](Invoke-TestSql "DROP TRIGGER guard_fts_migration;")

        $first.Content = "updatedmarker"
        $script:database.Save($first)
        (Search-Query -Database $script:database -Query "originalmarker").File.Path |
            Should -Be $second.Path
        (Search-Query -Database $script:database -Query "updatedmarker").File.Path |
            Should -Be $first.Path
        $script:database.Remove($second.Path)
        (Search-Query -Database $script:database -Query "originalmarker").Count | Should -Be 0
        (Invoke-TestSql "SELECT count(*) FROM files_fts;") | Should -Be 2
    }

    It "rejects an FTS schema without the filename column" {
        [void](Invoke-TestSql @"
DROP TABLE files_fts;
CREATE VIRTUAL TABLE files_fts USING fts5(
    file_id UNINDEXED,
    content,
    tokenize = 'unicode61 remove_diacritics 2'
);
"@)

        $script:database.Dispose()
        {
            Initialize-Database `
                -DatabasePath $script:databasePath `
                -AssemblyPath $script:assemblyPath
        } | Should -Throw "*unsupported FTS schema*"
    }

    It "rejects the legacy full-path schema with an actionable error" {
        $connectionProperty = [SqliteDateiRepository].GetProperty(
            "_connection",
            [System.Reflection.BindingFlags]"Instance,Public,NonPublic"
        )
        $connection = $connectionProperty.GetValue($script:database)
        $command = $connection.CreateCommand()
        $command.CommandText = @"
DROP TABLE files_fts;
DROP TABLE files_metadata;
CREATE TABLE files_metadata (
    id INTEGER PRIMARY KEY,
    path_key TEXT NOT NULL UNIQUE,
    path TEXT NOT NULL
);
"@
        [void]$command.ExecuteNonQuery()
        $command.Dispose()

        $script:database.Dispose()
        {
            Initialize-Database `
                -DatabasePath $script:databasePath `
                -AssemblyPath $script:assemblyPath
        } | Should -Throw "*unsupported legacy schema*"
    }

    It "validates the search limit" {
        { Search-Query -Database $script:database -Query "any" -Limit 0 } |
            Should -Throw
        { $script:database.Search("any", 1001, $null) } | Should -Throw
    }

    It "throws when used after disposal" {
        $script:database.Dispose()

        { $script:database.Get($script:testRoot) } | Should -Throw
    }
}

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

        $script:testRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
            "powershell-suchmaschine-tests-" + [guid]::NewGuid().ToString("N")
        )
        $script:assemblyPath = Join-Path $script:testRoot "sqlite"
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

    It "migrates the legacy full-path schema without losing searchable content" {
        $path = Join-Path $script:testRoot "legacy.txt"
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
    path TEXT NOT NULL,
    filename TEXT NOT NULL,
    extension TEXT NOT NULL,
    size_bytes INTEGER NOT NULL,
    creation_time_utc_ticks INTEGER NOT NULL,
    last_write_time_utc_ticks INTEGER NOT NULL,
    indexed_at_utc_ticks INTEGER NOT NULL,
    has_content INTEGER NOT NULL,
    is_cloud_only INTEGER NOT NULL
);
CREATE VIRTUAL TABLE files_fts USING fts5(
    path_key UNINDEXED,
    content,
    tokenize = 'unicode61 remove_diacritics 2'
);
"@
        [void]$command.ExecuteNonQuery()
        $command.Dispose()

        $legacy = New-TestDatei -Path $path
        $legacy.Content = "legacysearchmarker"
        $legacyCommand = $connection.CreateCommand()
        $legacyCommand.CommandText = @"
INSERT INTO files_metadata (
    id, path_key, path, filename, extension, size_bytes, creation_time_utc_ticks,
    last_write_time_utc_ticks, indexed_at_utc_ticks, has_content, is_cloud_only
) VALUES (
    23, 'LEGACYKEY', `$path, 'legacy.txt', '.txt', 128, `$creationTicks,
    `$writeTicks, `$indexedTicks, 1, 0
);
INSERT INTO files_fts(path_key, content) VALUES ('LEGACYKEY', 'legacysearchmarker');
"@
        [void]$legacyCommand.Parameters.AddWithValue('$path', $path)
        [void]$legacyCommand.Parameters.AddWithValue('$creationTicks', $legacy.CreationTimeUtc.Ticks)
        [void]$legacyCommand.Parameters.AddWithValue('$writeTicks', $legacy.LastWriteTimeUtc.Ticks)
        [void]$legacyCommand.Parameters.AddWithValue('$indexedTicks', $legacy.IndexedAtUtc.Ticks)
        [void]$legacyCommand.ExecuteNonQuery()
        $legacyCommand.Dispose()

        $script:database.Dispose()
        $script:database = Initialize-Database `
            -DatabasePath $script:databasePath `
            -AssemblyPath $script:assemblyPath

        $stored = $script:database.Get($path)
        $stored.Path | Should -Be $path
        $stored.Name | Should -Be "legacy.txt"
        $stored.Extension | Should -Be ".txt"
        (Search-Query -Database $script:database -Query "legacysearchmarker").File.Path |
            Should -Be $path

        $schemaCommand = $connectionProperty.GetValue($script:database).CreateCommand()
        $schemaCommand.CommandText = "PRAGMA table_info(files_metadata);"
        $schemaReader = $schemaCommand.ExecuteReader()
        $columnNames = [System.Collections.Generic.List[string]]::new()
        while ($schemaReader.Read()) {
            $columnNames.Add([string]$schemaReader["name"])
        }
        $schemaReader.Dispose()
        $schemaCommand.Dispose()
        $columnNames | Should -Contain "directory_path"
        $columnNames | Should -Not -Contain "path"
        $columnNames | Should -Not -Contain "path_key"
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

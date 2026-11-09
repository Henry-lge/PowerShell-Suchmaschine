using module "../Common/PathUtil.psm1"
using module "../Model/Datei.psm1"
using module "./DateiRepository.psm1"

#requires -Version 7.2

class SqliteProvider {
    static [void] Load([string]$assemblyPath) {
        $assemblies = @(
            "SQLitePCLRaw.core.dll",
            "SQLitePCLRaw.provider.e_sqlite3.dll",
            "SQLitePCLRaw.batteries_v2.dll",
            "Microsoft.Data.Sqlite.dll"
        )

        foreach ($assemblyName in $assemblies) {
            $path = Join-Path $assemblyPath $assemblyName
            if (-not [System.IO.File]::Exists($path)) {
                throw "SQLite dependency was not found: $path"
            }

            [void][System.Reflection.Assembly]::LoadFrom($path)
        }

        $batteriesType = [type]::GetType(
            "SQLitePCL.Batteries_V2, SQLitePCLRaw.batteries_v2",
            $true
        )
        [void]$batteriesType.GetMethod("Init").Invoke($null, @())
    }
}

class SqliteDateiRepository : DateiRepository {
    hidden [object]$_connection
    hidden [bool]$_disposed = $false

    SqliteDateiRepository([string]$databasePath, [string]$assemblyPath) {
        if ([string]::IsNullOrWhiteSpace($databasePath)) {
            throw "Database path must not be empty."
        }

        if ([string]::IsNullOrWhiteSpace($assemblyPath)) {
            throw "SQLite assembly path must not be empty."
        }

        [SqliteProvider]::Load($assemblyPath)
        $normalizedPath = [PathUtil]::Normalize($databasePath)
        $parentPath = [System.IO.Path]::GetDirectoryName($normalizedPath)
        [System.IO.Directory]::CreateDirectory($parentPath) | Out-Null

        $builderType = [type]::GetType(
            "Microsoft.Data.Sqlite.SqliteConnectionStringBuilder, Microsoft.Data.Sqlite",
            $true
        )
        $builder = [System.Activator]::CreateInstance($builderType)
        $builder.DataSource = $normalizedPath
        $builder.Mode = [enum]::Parse(
            $builderType.GetProperty("Mode").PropertyType,
            "ReadWriteCreate"
        )

        $connectionType = [type]::GetType(
            "Microsoft.Data.Sqlite.SqliteConnection, Microsoft.Data.Sqlite",
            $true
        )
        $this._connection = [System.Activator]::CreateInstance(
            $connectionType,
            [object[]]@($builder.ToString())
        )
        try {
            $this._connection.Open()
            $this.InitializeSchema()
        }
        catch {
            $this._connection.Dispose()
            throw
        }
    }

    [Datei] Get([string]$path) {
        $this.EnsureOpen()
        $parts = $this.GetPathParts($path)
        $collation = $this.GetPathCollation()
        $command = $this.NewCommand(
            "SELECT directory_path, filename, extension, size_bytes, creation_time_utc_ticks, " +
            "last_write_time_utc_ticks, indexed_at_utc_ticks, has_content, is_cloud_only " +
            "FROM files_metadata " +
            "WHERE directory_path = `$directoryParameter COLLATE $collation " +
            "AND filename = `$filenameParameter COLLATE $collation " +
            "AND extension = `$extensionParameter COLLATE $collation;"
        )
        [void]$command.Parameters.AddWithValue('$directoryParameter', $parts.Directory)
        [void]$command.Parameters.AddWithValue('$filenameParameter', $parts.Name)
        [void]$command.Parameters.AddWithValue('$extensionParameter', $parts.Extension)

        try {
            $reader = $command.ExecuteReader()
            try {
                if (-not $reader.Read()) {
                    return $null
                }

                return $this.ReadDatei($reader)
            }
            finally {
                $reader.Dispose()
            }
        }
        finally {
            $command.Dispose()
        }
    }

    [System.Collections.Generic.Dictionary[string, Datei]] GetMany([string[]]$paths) {
        $this.EnsureOpen()
        $files = [System.Collections.Generic.Dictionary[string, Datei]]::new(
            [PathUtil]::GetComparer()
        )
        if ($paths.Count -eq 0) {
            return $files
        }

        $pathParts = [System.Collections.Generic.List[object]]::new()
        $seenPaths = [System.Collections.Generic.HashSet[string]]::new(
            [PathUtil]::GetComparer()
        )
        foreach ($path in $paths) {
            if ([string]::IsNullOrWhiteSpace($path)) {
                throw "Each path must not be empty."
            }

            $normalizedPath = [PathUtil]::Normalize($path)
            if (-not $seenPaths.Add($normalizedPath)) {
                continue
            }

            $pathParts.Add($this.GetPathParts($normalizedPath))
        }

        $collation = $this.GetPathCollation()
        $batchSize = 300
        for ($offset = 0; $offset -lt $pathParts.Count; $offset += $batchSize) {
            $count = [Math]::Min($batchSize, $pathParts.Count - $offset)
            $values = [System.Collections.Generic.List[string]]::new()
            $command = $null
            try {
                $command = $this._connection.CreateCommand()
                for ($index = 0; $index -lt $count; $index++) {
                    $parameterIndex = $index * 3
                    $values.Add(
                        "(`$directory$parameterIndex, `$filename$parameterIndex, `$extension$parameterIndex)"
                    )
                    $parts = $pathParts[$offset + $index]
                    [void]$command.Parameters.AddWithValue(
                        "`$directory$parameterIndex",
                        $parts.Directory
                    )
                    [void]$command.Parameters.AddWithValue(
                        "`$filename$parameterIndex",
                        $parts.Name
                    )
                    [void]$command.Parameters.AddWithValue(
                        "`$extension$parameterIndex",
                        $parts.Extension
                    )
                }

                $command.CommandText = @"
WITH requested(directory_path, filename, extension) AS (
    VALUES $($values -join ", ")
)
SELECT metadata.directory_path, metadata.filename, metadata.extension,
    metadata.size_bytes, metadata.creation_time_utc_ticks,
    metadata.last_write_time_utc_ticks, metadata.indexed_at_utc_ticks,
    metadata.has_content, metadata.is_cloud_only
FROM requested
JOIN files_metadata AS metadata
    ON metadata.directory_path = requested.directory_path COLLATE $collation
    AND metadata.filename = requested.filename COLLATE $collation
    AND metadata.extension = requested.extension COLLATE $collation;
"@
                $reader = $command.ExecuteReader()
                try {
                    while ($reader.Read()) {
                        $file = $this.ReadDatei($reader)
                        $files[$file.Path] = $file
                    }
                }
                finally {
                    $reader.Dispose()
                }
            }
            finally {
                if ($null -ne $command) {
                    $command.Dispose()
                }
            }
        }

        return $files
    }

    [void] Save([Datei]$datei) {
        $this.SaveBatch(@($datei))
    }

    [void] SaveBatch([Datei[]]$dateien) {
        $this.EnsureOpen()

        foreach ($datei in $dateien) {
            if ($null -eq $datei -or [string]::IsNullOrWhiteSpace($datei.Path)) {
                throw "A Datei with a non-empty Path is required."
            }
        }

        if ($dateien.Count -eq 0) {
            return
        }

        $transaction = $this._connection.BeginTransaction()
        $metadataCommand = $null
        $deleteCommand = $null
        $insertCommand = $null
        try {
            $metadataCommand = $this.NewSaveMetadataCommand($transaction)
            $deleteCommand = $this.NewSaveFtsDeleteCommand($transaction)
            $insertCommand = $this.NewSaveFtsInsertCommand($transaction)

            foreach ($datei in $dateien) {
                $this.SaveWithinTransaction(
                    $datei,
                    $metadataCommand,
                    $deleteCommand,
                    $insertCommand
                )
            }
            $transaction.Commit()
        }
        catch {
            $transaction.Rollback()
            throw
        }
        finally {
            if ($null -ne $insertCommand) {
                $insertCommand.Dispose()
            }
            if ($null -ne $deleteCommand) {
                $deleteCommand.Dispose()
            }
            if ($null -ne $metadataCommand) {
                $metadataCommand.Dispose()
            }
            $transaction.Dispose()
        }
    }

    [void] Remove([string]$path) {
        $this.RemoveBatch([string[]]@($path))
    }

    [void] RemoveBatch([string[]]$paths) {
        $this.EnsureOpen()
        if ($null -eq $paths -or $paths.Count -eq 0) {
            return
        }

        $pathParts = [System.Collections.Generic.List[object]]::new()
        $seenPaths = [System.Collections.Generic.HashSet[string]]::new(
            [PathUtil]::GetComparer()
        )
        foreach ($path in $paths) {
            $parts = $this.GetPathParts($path)
            $normalizedPath = [PathUtil]::Normalize($path)
            if ($seenPaths.Add($normalizedPath)) {
                $pathParts.Add($parts)
            }
        }

        if ($pathParts.Count -eq 0) {
            return
        }

        $collation = $this.GetPathCollation()
        $transaction = $this._connection.BeginTransaction()

        try {
            $batchSize = 300
            for ($offset = 0; $offset -lt $pathParts.Count; $offset += $batchSize) {
                $count = [Math]::Min($batchSize, $pathParts.Count - $offset)
                $values = [System.Collections.Generic.List[string]]::new()
                for ($index = 0; $index -lt $count; $index++) {
                    $parameterIndex = $index * 3
                    $values.Add(
                        "(`$directory$parameterIndex, `$filename$parameterIndex, `$extension$parameterIndex)"
                    )
                }

                $requestedCte = @"
WITH requested(directory_path, filename, extension) AS (
    VALUES $($values -join ", ")
)
"@
                $ftsCommand = $null
                $metadataCommand = $null
                try {
                    $ftsSql = @"
$requestedCte
DELETE FROM files_fts
WHERE file_id IN (
    SELECT metadata.id
    FROM files_metadata AS metadata
    JOIN requested
        ON metadata.directory_path = requested.directory_path COLLATE $collation
        AND metadata.filename = requested.filename COLLATE $collation
        AND metadata.extension = requested.extension COLLATE $collation
);
"@
                    $metadataSql = @"
$requestedCte
DELETE FROM files_metadata
WHERE id IN (
    SELECT metadata.id
    FROM files_metadata AS metadata
    JOIN requested
        ON metadata.directory_path = requested.directory_path COLLATE $collation
        AND metadata.filename = requested.filename COLLATE $collation
        AND metadata.extension = requested.extension COLLATE $collation
);
"@
                    $ftsCommand = $this.NewCommand($ftsSql, $transaction)
                    $metadataCommand = $this.NewCommand($metadataSql, $transaction)

                    for ($index = 0; $index -lt $count; $index++) {
                        $parameterIndex = $index * 3
                        $parts = $pathParts[$offset + $index]
                        foreach ($command in @($ftsCommand, $metadataCommand)) {
                            [void]$command.Parameters.AddWithValue(
                                "`$directory$parameterIndex",
                                $parts.Directory
                            )
                            [void]$command.Parameters.AddWithValue(
                                "`$filename$parameterIndex",
                                $parts.Name
                            )
                            [void]$command.Parameters.AddWithValue(
                                "`$extension$parameterIndex",
                                $parts.Extension
                            )
                        }
                    }

                    [void]$ftsCommand.ExecuteNonQuery()
                    [void]$metadataCommand.ExecuteNonQuery()
                }
                finally {
                    if ($null -ne $metadataCommand) {
                        $metadataCommand.Dispose()
                    }
                    if ($null -ne $ftsCommand) {
                        $ftsCommand.Dispose()
                    }
                }
            }

            $transaction.Commit()
        }
        catch {
            $transaction.Rollback()
            throw
        }
        finally {
            $transaction.Dispose()
        }
    }

    [string[]] GetPathsUnder([string]$folderPath) {
        $this.EnsureOpen()
        $folder = [PathUtil]::Normalize($folderPath)
        $prefix = $folder
        if (-not [System.IO.Path]::EndsInDirectorySeparator($prefix)) {
            $prefix += [System.IO.Path]::DirectorySeparatorChar
        }
        $escapedPrefix = $prefix.Replace("\", "\\").Replace("%", "\%").Replace("_", "\_")
        $collation = $this.GetPathCollation()
        $paths = [System.Collections.Generic.List[string]]::new()
        $command = $this.NewCommand(
            "SELECT directory_path, filename, extension FROM files_metadata " +
            "WHERE directory_path = `$folderParameter COLLATE $collation " +
            "OR directory_path LIKE `$prefixParameter ESCAPE '\';"
        )
        [void]$command.Parameters.AddWithValue('$folderParameter', $folder)
        [void]$command.Parameters.AddWithValue('$prefixParameter', "$escapedPrefix%")

        try {
            $reader = $command.ExecuteReader()
            try {
                while ($reader.Read()) {
                    $path = $this.GetFullPath(
                        [string]$reader["directory_path"],
                        [string]$reader["filename"],
                        [string]$reader["extension"]
                    )
                    if ([PathUtil]::IsSameOrUnder($path, $folder)) {
                        $paths.Add($path)
                    }
                }
            }
            finally {
                $reader.Dispose()
            }
        }
        finally {
            $command.Dispose()
        }

        return $paths.ToArray()
    }

    [object[]] Search(
        [string]$query,
        [int]$limit = 100,
        [string]$extension = $null
    ) {
        $this.EnsureOpen()
        if ([string]::IsNullOrWhiteSpace($query)) {
            return @()
        }
        if ($limit -lt 1 -or $limit -gt 1000) {
            throw "Search limit must be between 1 and 1000."
        }

        if (-not [string]::IsNullOrWhiteSpace($extension)) {
            $extension = $extension.ToLowerInvariant()
            if (-not $extension.StartsWith(".")) {
                $extension = ".$extension"
            }
        }

        $command = $this.NewCommand(
            "SELECT m.directory_path, m.filename, m.extension, m.size_bytes, " +
            "m.creation_time_utc_ticks, m.last_write_time_utc_ticks, " +
            "m.indexed_at_utc_ticks, m.has_content, m.is_cloud_only, " +
            "bm25(files_fts) AS rank, snippet(files_fts, 1, '[', ']', '...', 16) AS excerpt " +
            "FROM files_fts JOIN files_metadata AS m ON m.id = files_fts.file_id " +
            "WHERE files_fts MATCH `$queryParameter " +
            "AND (`$extensionParameter IS NULL OR " +
            "m.extension = `$extensionParameter COLLATE NOCASE) " +
            "ORDER BY rank LIMIT `$limitParameter;"
        )
        [void]$command.Parameters.AddWithValue('$queryParameter', $query)
        [void]$command.Parameters.AddWithValue(
            '$extensionParameter',
            $(if ([string]::IsNullOrWhiteSpace($extension)) { [DBNull]::Value } else { $extension })
        )
        [void]$command.Parameters.AddWithValue('$limitParameter', $limit)

        $results = [System.Collections.Generic.List[object]]::new()
        try {
            $reader = $command.ExecuteReader()
            try {
                while ($reader.Read()) {
                    $datei = $this.ReadDatei($reader)
                    $results.Add([PSCustomObject]@{
                        File = $datei
                        Score = -[double]$reader["rank"]
                        Snippet = [string]$reader["excerpt"]
                    })
                }
            }
            finally {
                $reader.Dispose()
            }
        }
        finally {
            $command.Dispose()
        }

        return $results.ToArray()
    }

    [void] Dispose() {
        if ($this._disposed) {
            return
        }

        $this._disposed = $true
        if ($null -ne $this._connection) {
            $this._connection.Dispose()
        }
    }

    hidden [void] InitializeSchema() {
        $pragmaCommand = $this.NewCommand(@"
PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA busy_timeout = 10000;
"@)
        try {
            [void]$pragmaCommand.ExecuteNonQuery()
        }
        finally {
            $pragmaCommand.Dispose()
        }

        $columns = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
        $columnsCommand = $this.NewCommand("PRAGMA table_info(files_metadata);")
        try {
            $reader = $columnsCommand.ExecuteReader()
            try {
                while ($reader.Read()) {
                    [void]$columns.Add([string]$reader["name"])
                }
            }
            finally {
                $reader.Dispose()
            }
        }
        finally {
            $columnsCommand.Dispose()
        }

        if ($columns.Count -gt 0 -and -not $columns.Contains("directory_path")) {
            $this.MigrateLegacySchema()
        }

        $collation = $this.GetPathCollation()
        $command = $this.NewCommand(@"
CREATE TABLE IF NOT EXISTS files_metadata (
    id INTEGER PRIMARY KEY,
    directory_path TEXT NOT NULL,
    filename TEXT NOT NULL,
    extension TEXT NOT NULL,
    size_bytes INTEGER NOT NULL,
    creation_time_utc_ticks INTEGER NOT NULL,
    last_write_time_utc_ticks INTEGER NOT NULL,
    indexed_at_utc_ticks INTEGER NOT NULL,
    has_content INTEGER NOT NULL,
    is_cloud_only INTEGER NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_files_metadata_path
    ON files_metadata(
        directory_path COLLATE $collation,
        filename COLLATE $collation,
        extension COLLATE $collation
    );

CREATE INDEX IF NOT EXISTS idx_files_metadata_extension
    ON files_metadata(extension COLLATE NOCASE);

CREATE VIRTUAL TABLE IF NOT EXISTS files_fts USING fts5(
    file_id UNINDEXED,
    content,
    tokenize = 'unicode61 remove_diacritics 2'
);
"@)
        try {
            [void]$command.ExecuteNonQuery()
        }
        finally {
            $command.Dispose()
        }

        if ($collation -eq "BINARY") {
            $directoryIndexCommand = $this.NewCommand(@"
CREATE INDEX IF NOT EXISTS idx_files_metadata_directory_nocase
    ON files_metadata(directory_path COLLATE NOCASE);
"@)
            try {
                [void]$directoryIndexCommand.ExecuteNonQuery()
            }
            finally {
                $directoryIndexCommand.Dispose()
            }
        }
    }

    hidden [void] MigrateLegacySchema() {
        $collation = $this.GetPathCollation()
        $transaction = $this._connection.BeginTransaction()
        try {
            $createCommand = $this.NewCommand(@"
CREATE TABLE files_metadata_v2 (
    id INTEGER PRIMARY KEY,
    directory_path TEXT NOT NULL,
    filename TEXT NOT NULL,
    extension TEXT NOT NULL,
    size_bytes INTEGER NOT NULL,
    creation_time_utc_ticks INTEGER NOT NULL,
    last_write_time_utc_ticks INTEGER NOT NULL,
    indexed_at_utc_ticks INTEGER NOT NULL,
    has_content INTEGER NOT NULL,
    is_cloud_only INTEGER NOT NULL
);
CREATE VIRTUAL TABLE files_fts_v2 USING fts5(
    file_id UNINDEXED,
    content,
    tokenize = 'unicode61 remove_diacritics 2'
);
"@, $transaction)
            try {
                [void]$createCommand.ExecuteNonQuery()
            }
            finally {
                $createCommand.Dispose()
            }

            $insertCommand = $this.NewCommand(@"
INSERT INTO files_metadata_v2 (
    id, directory_path, filename, extension, size_bytes,
    creation_time_utc_ticks, last_write_time_utc_ticks, indexed_at_utc_ticks,
    has_content, is_cloud_only
) VALUES (
    `$idParameter, `$directoryParameter, `$filenameParameter, `$extensionParameter,
    `$sizeParameter, `$creationTimeParameter, `$lastWriteTimeParameter,
    `$indexedAtParameter, `$hasContentParameter, `$cloudOnlyParameter
);
"@, $transaction)
            try {
                [void]$insertCommand.Parameters.AddWithValue('$idParameter', 0)
                [void]$insertCommand.Parameters.AddWithValue('$directoryParameter', "")
                [void]$insertCommand.Parameters.AddWithValue('$filenameParameter', "")
                [void]$insertCommand.Parameters.AddWithValue('$extensionParameter', "")
                [void]$insertCommand.Parameters.AddWithValue('$sizeParameter', 0)
                [void]$insertCommand.Parameters.AddWithValue('$creationTimeParameter', 0)
                [void]$insertCommand.Parameters.AddWithValue('$lastWriteTimeParameter', 0)
                [void]$insertCommand.Parameters.AddWithValue('$indexedAtParameter', 0)
                [void]$insertCommand.Parameters.AddWithValue('$hasContentParameter', $false)
                [void]$insertCommand.Parameters.AddWithValue('$cloudOnlyParameter', $false)
                $insertCommand.Prepare()

                $hasLastId = $false
                $lastId = [long]0
                do {
                    $selectSql = (
                        "SELECT id, path, size_bytes, creation_time_utc_ticks, " +
                        "last_write_time_utc_ticks, indexed_at_utc_ticks, has_content, is_cloud_only " +
                        "FROM files_metadata "
                    )
                    if ($hasLastId) {
                        $selectSql += "WHERE id > `$lastIdParameter "
                    }
                    $selectSql += "ORDER BY id LIMIT 300;"

                    $selectCommand = $this.NewCommand($selectSql, $transaction)
                    $legacyFiles = [System.Collections.Generic.List[object]]::new()
                    try {
                        if ($hasLastId) {
                            [void]$selectCommand.Parameters.AddWithValue(
                                '$lastIdParameter',
                                $lastId
                            )
                        }
                        $reader = $selectCommand.ExecuteReader()
                        try {
                            while ($reader.Read()) {
                                $legacyFiles.Add([PSCustomObject]@{
                                    Id = [long]$reader["id"]
                                    Path = [string]$reader["path"]
                                    Size = [long]$reader["size_bytes"]
                                    CreationTicks = [long]$reader["creation_time_utc_ticks"]
                                    WriteTicks = [long]$reader["last_write_time_utc_ticks"]
                                    IndexedTicks = [long]$reader["indexed_at_utc_ticks"]
                                    HasContent = [bool]$reader["has_content"]
                                    IsCloudOnly = [bool]$reader["is_cloud_only"]
                                })
                            }
                        }
                        finally {
                            $reader.Dispose()
                        }
                    }
                    finally {
                        $selectCommand.Dispose()
                    }

                    foreach ($legacyFile in $legacyFiles) {
                        $path = [PathUtil]::Normalize($legacyFile.Path)
                        $directory = [System.IO.Path]::GetDirectoryName($path)
                        $fullName = [System.IO.Path]::GetFileName($path)
                        $extension = [System.IO.Path]::GetExtension($fullName)
                        $name = [System.IO.Path]::GetFileNameWithoutExtension($fullName)
                        $insertCommand.Parameters['$idParameter'].Value = $legacyFile.Id
                        $insertCommand.Parameters['$directoryParameter'].Value = $directory
                        $insertCommand.Parameters['$filenameParameter'].Value = $name
                        $insertCommand.Parameters['$extensionParameter'].Value = $extension
                        $insertCommand.Parameters['$sizeParameter'].Value = $legacyFile.Size
                        $insertCommand.Parameters['$creationTimeParameter'].Value = $legacyFile.CreationTicks
                        $insertCommand.Parameters['$lastWriteTimeParameter'].Value = $legacyFile.WriteTicks
                        $insertCommand.Parameters['$indexedAtParameter'].Value = $legacyFile.IndexedTicks
                        $insertCommand.Parameters['$hasContentParameter'].Value = $legacyFile.HasContent
                        $insertCommand.Parameters['$cloudOnlyParameter'].Value = $legacyFile.IsCloudOnly
                        [void]$insertCommand.ExecuteNonQuery()
                        $lastId = $legacyFile.Id
                        $hasLastId = $true
                    }
                } while ($legacyFiles.Count -gt 0)
            }
            finally {
                $insertCommand.Dispose()
            }

            $copyFtsCommand = $this.NewCommand(@"
INSERT INTO files_fts_v2(file_id, content)
SELECT metadata.id, full_text.content
FROM files_fts AS full_text
JOIN files_metadata AS metadata ON metadata.path_key = full_text.path_key;
"@, $transaction)
            try {
                [void]$copyFtsCommand.ExecuteNonQuery()
            }
            finally {
                $copyFtsCommand.Dispose()
            }

            $replaceCommand = $this.NewCommand(@"
DROP TABLE files_fts;
DROP TABLE files_metadata;
ALTER TABLE files_metadata_v2 RENAME TO files_metadata;
ALTER TABLE files_fts_v2 RENAME TO files_fts;
CREATE UNIQUE INDEX idx_files_metadata_path
    ON files_metadata(
        directory_path COLLATE $collation,
        filename COLLATE $collation,
        extension COLLATE $collation
    );
CREATE INDEX idx_files_metadata_extension ON files_metadata(extension COLLATE NOCASE);
"@, $transaction)
            if ($collation -eq "BINARY") {
                $replaceCommand.CommandText += @"

CREATE INDEX idx_files_metadata_directory_nocase
    ON files_metadata(directory_path COLLATE NOCASE);
"@
            }
            try {
                [void]$replaceCommand.ExecuteNonQuery()
            }
            finally {
                $replaceCommand.Dispose()
            }

            $transaction.Commit()
        }
        catch {
            $transaction.Rollback()
            throw
        }
        finally {
            $transaction.Dispose()
        }
    }

    hidden [object] NewSaveMetadataCommand([object]$transaction) {
        $collation = $this.GetPathCollation()
        $command = $this.NewCommand(@"
INSERT INTO files_metadata (
    directory_path, filename, extension, size_bytes, creation_time_utc_ticks,
    last_write_time_utc_ticks, indexed_at_utc_ticks, has_content, is_cloud_only
) VALUES (
    `$directoryParameter, `$filenameParameter, `$extensionParameter, `$sizeParameter,
    `$creationTimeParameter, `$lastWriteTimeParameter, `$indexedAtParameter,
    `$hasContentParameter, `$cloudOnlyParameter
)
ON CONFLICT(
    directory_path COLLATE $collation,
    filename COLLATE $collation,
    extension COLLATE $collation
) DO UPDATE SET
    size_bytes = excluded.size_bytes,
    creation_time_utc_ticks = excluded.creation_time_utc_ticks,
    last_write_time_utc_ticks = excluded.last_write_time_utc_ticks,
    indexed_at_utc_ticks = excluded.indexed_at_utc_ticks,
    has_content = excluded.has_content,
    is_cloud_only = excluded.is_cloud_only
RETURNING id;
"@, $transaction)
        try {
            [void]$command.Parameters.AddWithValue('$directoryParameter', "")
            [void]$command.Parameters.AddWithValue('$filenameParameter', "")
            [void]$command.Parameters.AddWithValue('$extensionParameter', "")
            [void]$command.Parameters.AddWithValue('$sizeParameter', 0)
            [void]$command.Parameters.AddWithValue('$creationTimeParameter', 0)
            [void]$command.Parameters.AddWithValue('$lastWriteTimeParameter', 0)
            [void]$command.Parameters.AddWithValue('$indexedAtParameter', 0)
            [void]$command.Parameters.AddWithValue('$hasContentParameter', $false)
            [void]$command.Parameters.AddWithValue('$cloudOnlyParameter', $false)
            $command.Prepare()
            return $command
        }
        catch {
            $command.Dispose()
            throw
        }
    }

    hidden [object] NewSaveFtsDeleteCommand([object]$transaction) {
        $command = $this.NewCommand(
            "DELETE FROM files_fts WHERE file_id = `$fileIdParameter;",
            $transaction
        )
        try {
            [void]$command.Parameters.AddWithValue('$fileIdParameter', 0)
            $command.Prepare()
            return $command
        }
        catch {
            $command.Dispose()
            throw
        }
    }

    hidden [object] NewSaveFtsInsertCommand([object]$transaction) {
        $command = $this.NewCommand(
            "INSERT INTO files_fts(file_id, content) " +
            "VALUES (`$fileIdParameter, `$contentParameter);",
            $transaction
        )
        try {
            [void]$command.Parameters.AddWithValue('$fileIdParameter', 0)
            [void]$command.Parameters.AddWithValue('$contentParameter', "")
            $command.Prepare()
            return $command
        }
        catch {
            $command.Dispose()
            throw
        }
    }

    hidden [void] SaveWithinTransaction(
        [Datei]$datei,
        [object]$metadataCommand,
        [object]$deleteCommand,
        [object]$insertCommand
    ) {
        $parts = $this.GetPathParts($datei.Path)
        $metadataCommand.Parameters['$directoryParameter'].Value = $parts.Directory
        $metadataCommand.Parameters['$filenameParameter'].Value = $parts.Name
        $metadataCommand.Parameters['$extensionParameter'].Value = $parts.Extension
        $metadataCommand.Parameters['$sizeParameter'].Value = $datei.Size
        $metadataCommand.Parameters['$creationTimeParameter'].Value = $datei.CreationTimeUtc.Ticks
        $metadataCommand.Parameters['$lastWriteTimeParameter'].Value = $datei.LastWriteTimeUtc.Ticks
        $metadataCommand.Parameters['$indexedAtParameter'].Value = $datei.IndexedAtUtc.Ticks
        $metadataCommand.Parameters['$hasContentParameter'].Value = $datei.HasContent
        $metadataCommand.Parameters['$cloudOnlyParameter'].Value = $datei.IsCloudOnly
        $fileId = [long]$metadataCommand.ExecuteScalar()

        $deleteCommand.Parameters['$fileIdParameter'].Value = $fileId
        [void]$deleteCommand.ExecuteNonQuery()

        if ($datei.HasContent) {
            $content = ""
            if ($null -ne $datei.Content) {
                $content = $datei.Content
            }
            $insertCommand.Parameters['$fileIdParameter'].Value = $fileId
            $insertCommand.Parameters['$contentParameter'].Value = $content
            [void]$insertCommand.ExecuteNonQuery()
        }
    }

    hidden [object] NewCommand([string]$sql) {
        return $this.NewCommand($sql, $null)
    }

    hidden [object] NewCommand([string]$sql, [object]$transaction) {
        $command = $this._connection.CreateCommand()
        $command.CommandText = $sql
        if ($null -ne $transaction) {
            $command.Transaction = $transaction
        }
        return $command
    }

    hidden [Datei] ReadDatei([object]$reader) {
        $datei = [Datei]::new()
        $storedExtension = [string]$reader["extension"]
        $datei.Extension = $storedExtension.ToLowerInvariant()
        $datei.Name = [string]$reader["filename"] + $storedExtension
        $datei.Path = $this.GetFullPath(
            [string]$reader["directory_path"],
            [string]$reader["filename"],
            $storedExtension
        )
        $datei.Size = [long]$reader["size_bytes"]
        $datei.CreationTimeUtc = [datetime]::new(
            [long]$reader["creation_time_utc_ticks"],
            [System.DateTimeKind]::Utc
        )
        $datei.LastWriteTimeUtc = [datetime]::new(
            [long]$reader["last_write_time_utc_ticks"],
            [System.DateTimeKind]::Utc
        )
        $datei.IndexedAtUtc = [datetime]::new(
            [long]$reader["indexed_at_utc_ticks"],
            [System.DateTimeKind]::Utc
        )
        $datei.HasContent = [bool]$reader["has_content"]
        $datei.IsCloudOnly = [bool]$reader["is_cloud_only"]
        return $datei
    }

    hidden [object] GetPathParts([string]$path) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            throw "File path must not be empty."
        }

        $normalizedPath = [PathUtil]::Normalize($path)
        $fullName = [System.IO.Path]::GetFileName($normalizedPath)
        if ([string]::IsNullOrWhiteSpace($fullName)) {
            throw "File path must include a file name."
        }

        return [PSCustomObject]@{
            Directory = [System.IO.Path]::GetDirectoryName($normalizedPath)
            Name = [System.IO.Path]::GetFileNameWithoutExtension($fullName)
            Extension = [System.IO.Path]::GetExtension($fullName)
        }
    }

    hidden [string] GetFullPath(
        [string]$directory,
        [string]$name,
        [string]$extension
    ) {
        return [PathUtil]::Normalize(
            [System.IO.Path]::Combine($directory, "$name$extension")
        )
    }

    hidden [string] GetPathCollation() {
        if ([PathUtil]::GetComparison() -eq [System.StringComparison]::OrdinalIgnoreCase) {
            return "NOCASE"
        }
        return "BINARY"
    }

    hidden [void] AddPathParameters([object]$command, [object]$parts) {
        [void]$command.Parameters.AddWithValue('$directoryParameter', $parts.Directory)
        [void]$command.Parameters.AddWithValue('$filenameParameter', $parts.Name)
        [void]$command.Parameters.AddWithValue('$extensionParameter', $parts.Extension)
    }

    hidden [void] EnsureOpen() {
        if ($this._disposed) {
            throw "SqliteDateiRepository is already disposed."
        }
    }
}

function Initialize-Database {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [string]$AssemblyPath = (Join-Path $PSScriptRoot "../../lib/sqlite")
    )

    & (Join-Path $PSScriptRoot "Install-Sqlite.ps1") -Destination $AssemblyPath
    return [SqliteDateiRepository]::new($DatabasePath, $AssemblyPath)
}

function Add-File {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [SqliteDateiRepository]$Database,

        [Parameter(Mandatory, ValueFromPipeline)]
        [Datei]$File
    )

    process {
        $Database.Save($File)
        return $File
    }
}

function Sync-Files {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [SqliteDateiRepository]$Database,

        [Parameter(Mandatory, ValueFromPipeline)]
        [Datei[]]$Files
    )

    begin {
        $pending = [System.Collections.Generic.List[Datei]]::new()
        $filesToCheck = [System.Collections.Generic.List[Datei]]::new()
        $added = 0
        $updated = 0
        $unchanged = 0
    }
    process {
        foreach ($file in $Files) {
            if ($null -eq $file -or [string]::IsNullOrWhiteSpace($file.Path)) {
                throw "Each file must have a non-empty Path."
            }

            $filesToCheck.Add($file)
        }
    }
    end {
        $storedFiles = $Database.GetMany(
            [string[]]@($filesToCheck | ForEach-Object { $_.Path })
        )

        foreach ($file in $filesToCheck) {
            $stored = $null
            $normalizedPath = [PathUtil]::Normalize($file.Path)
            [void]$storedFiles.TryGetValue($normalizedPath, [ref]$stored)
            if (
                $null -ne $stored -and
                $stored.LastWriteTimeUtc.Ticks -eq $file.LastWriteTimeUtc.Ticks -and
                (-not $stored.IsCloudOnly -or $file.IsCloudOnly)
            ) {
                $unchanged++
                continue
            }

            if ($null -eq $stored) {
                $added++
            }
            else {
                $updated++
            }
            $pending.Add($file)
        }

        $Database.SaveBatch($pending.ToArray())
        return [PSCustomObject]@{
            Added = $added
            Updated = $updated
            Unchanged = $unchanged
        }
    }
}

function Search-Query {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [SqliteDateiRepository]$Database,

        [Parameter(Mandatory)]
        [string]$Query,

        [ValidateRange(1, 1000)]
        [int]$Limit = 100,

        [string]$Extension
    )

    return $Database.Search($Query, $Limit, $Extension)
}

Export-ModuleMember -Function Initialize-Database, Add-File, Sync-Files, Search-Query

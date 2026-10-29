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
        $pathKey = $this.GetPathKey($path)
        $command = $this.NewCommand(
            "SELECT path, filename, extension, size_bytes, creation_time_utc_ticks, " +
            "last_write_time_utc_ticks, indexed_at_utc_ticks, has_content, is_cloud_only " +
            "FROM files_metadata WHERE path_key = `$pathParameter;"
        )
        [void]$command.Parameters.AddWithValue('$pathParameter', $pathKey)

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
        try {
            foreach ($datei in $dateien) {
                $this.SaveWithinTransaction($datei, $transaction)
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

    [void] Remove([string]$path) {
        $this.EnsureOpen()
        $pathKey = $this.GetPathKey($path)
        $transaction = $this._connection.BeginTransaction()

        try {
            $ftsCommand = $this.NewCommand(
                "DELETE FROM files_fts WHERE path_key = `$pathParameter;",
                $transaction
            )
            [void]$ftsCommand.Parameters.AddWithValue('$pathParameter', $pathKey)
            try {
                [void]$ftsCommand.ExecuteNonQuery()
            }
            finally {
                $ftsCommand.Dispose()
            }

            $metadataCommand = $this.NewCommand(
                "DELETE FROM files_metadata WHERE path_key = `$pathParameter;",
                $transaction
            )
            [void]$metadataCommand.Parameters.AddWithValue('$pathParameter', $pathKey)
            try {
                [void]$metadataCommand.ExecuteNonQuery()
            }
            finally {
                $metadataCommand.Dispose()
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
        $paths = [System.Collections.Generic.List[string]]::new()
        $command = $this.NewCommand("SELECT path FROM files_metadata;")

        try {
            $reader = $command.ExecuteReader()
            try {
                while ($reader.Read()) {
                    $path = [string]$reader["path"]
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
            "SELECT m.path, m.filename, m.extension, m.size_bytes, " +
            "m.creation_time_utc_ticks, m.last_write_time_utc_ticks, " +
            "m.indexed_at_utc_ticks, m.has_content, m.is_cloud_only, " +
            "bm25(files_fts) AS rank, snippet(files_fts, 1, '[', ']', '...', 16) AS excerpt " +
            "FROM files_fts JOIN files_metadata AS m ON m.path_key = files_fts.path_key " +
            "WHERE files_fts MATCH `$queryParameter " +
            "AND (`$extensionParameter IS NULL OR m.extension = `$extensionParameter) " +
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
        $command = $this.NewCommand(@"
PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA busy_timeout = 10000;

CREATE TABLE IF NOT EXISTS files_metadata (
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

CREATE INDEX IF NOT EXISTS idx_files_metadata_extension
    ON files_metadata(extension);

CREATE VIRTUAL TABLE IF NOT EXISTS files_fts USING fts5(
    path_key UNINDEXED,
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
    }

    hidden [void] SaveWithinTransaction([Datei]$datei, [object]$transaction) {
        $path = [PathUtil]::Normalize($datei.Path)
        $pathKey = $this.GetPathKey($path)
        $filename = $datei.Name
        if ([string]::IsNullOrWhiteSpace($filename)) {
            $filename = [System.IO.Path]::GetFileName($path)
        }
        $extension = $datei.Extension
        if ([string]::IsNullOrWhiteSpace($extension)) {
            $extension = [System.IO.Path]::GetExtension($filename)
        }
        $extension = $extension.ToLowerInvariant()
        $command = $this.NewCommand(@"
INSERT INTO files_metadata (
    path_key, path, filename, extension, size_bytes, creation_time_utc_ticks,
    last_write_time_utc_ticks, indexed_at_utc_ticks, has_content, is_cloud_only
) VALUES (
    `$pathKeyParameter, `$pathParameter, `$filenameParameter, `$extensionParameter,
    `$sizeParameter, `$creationTimeParameter, `$lastWriteTimeParameter,
    `$indexedAtParameter, `$hasContentParameter, `$cloudOnlyParameter
)
ON CONFLICT(path_key) DO UPDATE SET
    path = excluded.path,
    filename = excluded.filename,
    extension = excluded.extension,
    size_bytes = excluded.size_bytes,
    creation_time_utc_ticks = excluded.creation_time_utc_ticks,
    last_write_time_utc_ticks = excluded.last_write_time_utc_ticks,
    indexed_at_utc_ticks = excluded.indexed_at_utc_ticks,
    has_content = excluded.has_content,
    is_cloud_only = excluded.is_cloud_only;
"@, $transaction)
        [void]$command.Parameters.AddWithValue('$pathKeyParameter', $pathKey)
        [void]$command.Parameters.AddWithValue('$pathParameter', $path)
        [void]$command.Parameters.AddWithValue('$filenameParameter', $filename)
        [void]$command.Parameters.AddWithValue('$extensionParameter', $extension)
        [void]$command.Parameters.AddWithValue('$sizeParameter', $datei.Size)
        [void]$command.Parameters.AddWithValue('$creationTimeParameter', $datei.CreationTimeUtc.Ticks)
        [void]$command.Parameters.AddWithValue('$lastWriteTimeParameter', $datei.LastWriteTimeUtc.Ticks)
        [void]$command.Parameters.AddWithValue('$indexedAtParameter', $datei.IndexedAtUtc.Ticks)
        [void]$command.Parameters.AddWithValue('$hasContentParameter', $datei.HasContent)
        [void]$command.Parameters.AddWithValue('$cloudOnlyParameter', $datei.IsCloudOnly)

        try {
            [void]$command.ExecuteNonQuery()
        }
        finally {
            $command.Dispose()
        }

        $deleteCommand = $this.NewCommand(
            "DELETE FROM files_fts WHERE path_key = `$pathKeyParameter;",
            $transaction
        )
        [void]$deleteCommand.Parameters.AddWithValue('$pathKeyParameter', $pathKey)
        try {
            [void]$deleteCommand.ExecuteNonQuery()
        }
        finally {
            $deleteCommand.Dispose()
        }

        if ($datei.HasContent) {
            $insertCommand = $this.NewCommand(
                "INSERT INTO files_fts(path_key, content) " +
                "VALUES (`$pathKeyParameter, `$contentParameter);",
                $transaction
            )
            [void]$insertCommand.Parameters.AddWithValue('$pathKeyParameter', $pathKey)
            [void]$insertCommand.Parameters.AddWithValue(
                '$contentParameter',
                $(if ($null -eq $datei.Content) { "" } else { $datei.Content })
            )
            try {
                [void]$insertCommand.ExecuteNonQuery()
            }
            finally {
                $insertCommand.Dispose()
            }
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
        $datei.Path = [string]$reader["path"]
        $datei.Name = [string]$reader["filename"]
        $datei.Extension = [string]$reader["extension"]
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

    hidden [string] GetPathKey([string]$path) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            throw "File path must not be empty."
        }

        $normalizedPath = [PathUtil]::Normalize($path)
        if ([PathUtil]::GetComparison() -eq [System.StringComparison]::OrdinalIgnoreCase) {
            return $normalizedPath.ToUpperInvariant()
        }
        return $normalizedPath
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
        $added = 0
        $updated = 0
        $unchanged = 0
    }
    process {
        foreach ($file in $Files) {
            if ($null -eq $file -or [string]::IsNullOrWhiteSpace($file.Path)) {
                throw "Each file must have a non-empty Path."
            }

            $stored = $Database.Get($file.Path)
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
    }
    end {
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

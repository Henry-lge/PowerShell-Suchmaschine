#requires -Version 7.2
param([string]$DatabasePath = (Join-Path $PSScriptRoot 'data/index.sqlite3'))

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding  = $utf8
[Console]::OutputEncoding = $utf8

function Write-Response($Object) {
    $Object | ConvertTo-Json -Depth 6 -Compress | Write-Output
}

# FTS5 (Inhaltssuche): jedes Wort wird zur Phrase, optional mit Präfix-Stern
function ConvertTo-Fts5Query([string]$Text, [bool]$Prefix) {
    $terms = $Text -split '\s+' | Where-Object { $_ }
    ($terms | ForEach-Object {
        '"' + ($_ -replace '"', '""') + '"' + $(if ($Prefix) { '*' } else { '' })
    }) -join ' '
}

# LIKE (Namenssuche): *, ? sind Platzhalter; ohne Platzhalter "enthält"
function ConvertTo-LikePattern([string]$Term) {
    # erst LIKE-Sonderzeichen entschärfen (Escape-Zeichen ist \)
    $escaped = $Term -replace '\\', '\\' -replace '%', '\%' -replace '_', '\_'
    if ($escaped -match '[*?]') {
        return ($escaped -replace '\*', '%' -replace '\?', '_')
    }
    return "%$escaped%"
}

# Suche in den Metadaten (Dateiname). Eigene, schreibgeschützte Verbindung.
function Search-FileName {
    param([string]$DatabasePath, [string[]]$Terms, [string]$Extension, [int]$Limit)

    $ext = $null
    if ($Extension) {
        $ext = $Extension.ToLowerInvariant()
        if (-not $ext.StartsWith('.')) { $ext = ".$ext" }
    }

    $fullPath = [IO.Path]::GetFullPath($DatabasePath)
    $conn = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$fullPath;Mode=ReadOnly")
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()

        $conditions = for ($i = 0; $i -lt $Terms.Count; $i++) {
            "filename LIKE `$p$i ESCAPE '\'"
        }
        $cmd.CommandText = 'SELECT path, filename, extension, last_write_time_utc_ticks ' +
            'FROM files_metadata WHERE ' + ($conditions -join ' AND ') +
            ' AND ($ext IS NULL OR extension = $ext) ORDER BY filename LIMIT $limit'

        for ($i = 0; $i -lt $Terms.Count; $i++) {
            [void]$cmd.Parameters.AddWithValue("`$p$i", (ConvertTo-LikePattern $Terms[$i]))
        }
        [void]$cmd.Parameters.AddWithValue('$ext', $(if ($ext) { $ext } else { [DBNull]::Value }))
        [void]$cmd.Parameters.AddWithValue('$limit', $Limit)

        $reader = $cmd.ExecuteReader()
        try {
            while ($reader.Read()) {
                [ordered]@{
                    path         = $reader.GetString(0)
                    fileName     = $reader.GetString(1)
                    extension    = [string]$reader.GetValue(2)
                    lastWriteUtc = [datetime]::new([long]$reader.GetValue(3), [DateTimeKind]::Utc).ToString('o')
                    snippet      = ''
                    score        = 0.0
                    matchedIn    = 'Name'
                }
            }
        }
        finally { $reader.Dispose() }
    }
    finally { $conn.Dispose() }
}

$db = $null
try {
    $req = [Console]::In.ReadToEnd() | ConvertFrom-Json

    $mode = if ($req.mode) { [string]$req.mode } else { 'both' }
    if ($mode -notin 'content', 'name', 'both') { throw "Unbekannter Modus: $mode" }

    $text = ([string]$req.query).Trim()
    if (-not $text) {
        Write-Response @{ ok = $true; count = 0; results = @() }
        return
    }

    # Initialize-Database lädt auch die SQLite-Bibliotheken, die Search-FileName braucht
    Import-Module (Join-Path $PSScriptRoot 'src/Persistence/SqliteDateiRepository.psm1') -Force 6>$null
    $db = Initialize-Database -DatabasePath $DatabasePath 6>$null 3>$null

    $limit = if ($req.limit) { [Math]::Clamp([int]$req.limit, 1, 1000) } else { 100 }
    $extension = if ($req.extension) { [string]$req.extension } else { '' }

    $results = [System.Collections.Generic.List[object]]::new()
    $seen    = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    # 1. Namenssuche zuerst
    if ($mode -ne 'content') {
        $terms = @($text -split '\s+' | Where-Object { $_ })
        foreach ($hit in Search-FileName -DatabasePath $DatabasePath -Terms $terms -Extension $extension -Limit $limit) {
            if ($seen.Add($hit.path)) { $results.Add($hit) }
        }
    }

    # 2. Inhaltssuche (bei "both" und Platzhaltern wie *.txt überspringen)
    $skipContent = ($mode -eq 'both') -and ($text -match '[*?]')
    if ($mode -ne 'name' -and -not $skipContent) {
        $query  = ConvertTo-Fts5Query $text ([bool]$req.prefix)
        $params = @{ Database = $db; Query = $query; Limit = $limit }
        if ($extension) { $params.Extension = $extension }

        foreach ($hit in @(Search-Query @params)) {
            if ($seen.Add($hit.File.Path)) {
                $results.Add([ordered]@{
                    path         = $hit.File.Path
                    fileName     = $hit.File.Name
                    extension    = $hit.File.Extension
                    lastWriteUtc = $hit.File.LastWriteTimeUtc.ToString('o')
                    snippet      = $hit.Snippet
                    score        = [double]$hit.Score
                    matchedIn    = 'Inhalt'
                })
            }
        }
    }

    $final = @($results | Select-Object -First $limit)
    Write-Response @{ ok = $true; count = $final.Count; results = $final }
}
catch {
    Write-Response @{ ok = $false; error = $_.Exception.Message }
    exit 1
}
finally {
    if ($db) { $db.Dispose() }
}
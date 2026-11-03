#requires -Version 7.2
param([string]$DatabasePath = (Join-Path $PSScriptRoot 'data/search.sqlite3'))

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding  = $utf8
[Console]::OutputEncoding = $utf8

function Write-Response($Object) {
    $Object | ConvertTo-Json -Depth 6 -Compress | Write-Output
}

# Jeder Suchbegriff wird zur Phrase (mit Präfixsuche), damit Eingaben wie
# "C++" oder "foo-bar" keine FTS5-Syntaxfehler auslösen.
function ConvertTo-Fts5Query([string]$Text, [bool]$Prefix) {
    $terms = $Text -split '\s+' | Where-Object { $_ }
    ($terms | ForEach-Object {
        '"' + ($_ -replace '"', '""') + '"' + $(if ($Prefix) { '*' } else { '' })
    }) -join ' '
}

$db = $null
try {
    $req = [Console]::In.ReadToEnd() | ConvertFrom-Json

    Import-Module (Join-Path $PSScriptRoot 'src/Persistence/SqliteDateiRepository.psm1') -Force 6>$null
    $db = Initialize-Database -DatabasePath $DatabasePath 6>$null 3>$null

    $query = ConvertTo-Fts5Query ([string]$req.query) ([bool]$req.prefix)
    if (-not $query) {
        Write-Response @{ ok = $true; count = 0; results = @() }
        return
    }

    $limit  = if ($req.limit) { [Math]::Clamp([int]$req.limit, 1, 1000) } else { 100 }
    $params = @{ Database = $db; Query = $query; Limit = $limit }
    if ($req.extension) { $params.Extension = [string]$req.extension }

    $hits = @(Search-Query @params)

    $results = @($hits | ForEach-Object {
        [ordered]@{
            path         = $_.File.Path
            fileName     = $_.File.Name
            extension    = $_.File.Extension
            lastWriteUtc = $_.File.LastWriteTimeUtc.ToString('o')
            snippet      = $_.Snippet
            score        = [double]$_.Score
        }
    })
    Write-Response @{ ok = $true; count = $results.Count; results = $results }
}
catch {
    Write-Response @{ ok = $false; error = $_.Exception.Message }
    exit 1
}
finally {
    if ($db) { $db.Dispose() }
}
#requires -Version 7.2
# GUI-Adapter: Anfrage lesen, DB-Schnittstelle aufrufen, Treffer als JSON ausgeben.
param(
    [string]$Query,
    [string]$DatabasePath = (Join-Path $PSScriptRoot 'data/index.sqlite3'),
    [ValidateRange(1, 1000)]
    [int]$Limit = 100,
    [string]$Extension,
    [string]$SearchMode = 'Both',
    [string[]]$Extensions
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$database = $null
$useLiteral = $false

try {

if (-not $PSBoundParameters.ContainsKey('Query')) {
    $request = [Console]::In.ReadToEnd() | ConvertFrom-Json

    $Query = [string]$request.query

    if ($null -ne $request.limit) {
        $Limit = [int]$request.limit
    }

    if ($null -ne $request.extension) {
        $Extension = [string]$request.extension
    }

    if ($null -ne $request.extensions) {
        $Extensions = [string[]]@($request.extensions)
    }

    if ($null -ne $request.literal) {
        $useLiteral = [bool]$request.literal
    }

    $rawMode = $request.mode

    if ([string]::IsNullOrWhiteSpace([string]$rawMode)) {
        $rawMode = $request.searchMode
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$rawMode)) {
        switch ([string]$rawMode.Trim().ToLowerInvariant()) {
            'filename' { $SearchMode = 'FileName' }
            'content'  { $SearchMode = 'Content' }
            'both'     { $SearchMode = 'Both' }
            default {
                throw "Ungültiger Suchmodus: $rawMode"
            }
        }
    }
}

    if ($Limit -lt 1 -or $Limit -gt 1000) {
        throw 'Limit muss zwischen 1 und 1000 liegen.'
    }

    $results = @()
    if (-not [string]::IsNullOrWhiteSpace($Query)) {
        if (-not (Test-Path -LiteralPath $DatabasePath -PathType Leaf)) {
            throw "Suchindex nicht gefunden: $DatabasePath. Bitte zuerst suchmaschine.ps1 ausführen."
        }
        Import-Module (Join-Path $PSScriptRoot 'src/Persistence/SqliteDateiRepository.psm1') -Force 6>$null
        $database = Initialize-Database -DatabasePath $DatabasePath 6>$null 3>$null

        $filters = [System.Collections.Generic.List[string]]::new()
        $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($item in $Extensions) {
            $suffix = ([string]$item).Trim()
            if ($suffix -eq '') {
                continue
            }
            if (-not $suffix.StartsWith('.')) {
                $suffix = ".$suffix"
            }
            if ($seen.Add($suffix)) {
                [void]$filters.Add($suffix)
            }
        }
        if ($filters.Count -eq 0) {
            $filters.Add($Extension)
        }

        $searchParameters = @{
            Database = $database
            Query = $Query
            Limit = $Limit
            SearchMode = $SearchMode
        }
        if ($useLiteral) {
            $searchParameters.Literal = $true
        }

        # Die DB-Schnittstelle nimmt eine einzelne Endung pro Aufruf an.
        $rawResults = @(foreach ($filter in $filters) {
            $searchParameters.Extension = $filter
            try {
                Search-Query @searchParameters
            }
            catch {
                if ($searchParameters.Literal -or $_.Exception.Message -notmatch '(?i)(fts|match|syntax)') {
                    throw
                }

                $searchParameters.Literal = $true
                Search-Query @searchParameters
            }
        })
        if ($filters.Count -gt 1) {
            $sortKeys = @(
                @{ Expression = { $_.Score }; Descending = $true }
                @{ Expression = { [System.IO.Path]::GetFileNameWithoutExtension($_.File.Name) } }
            )
            $rawResults = @($rawResults | Sort-Object -Property $sortKeys -CaseSensitive -Top $Limit)
        }

        $results = @($rawResults |
            ForEach-Object {
                [ordered]@{
                    path = $_.File.Path
                    fileName = $_.File.Name
                    extension = $_.File.Extension
                    lastWriteUtc = $_.File.LastWriteTimeUtc.ToString('o')
                    snippet = $_.Snippet
                    score = [double]$_.Score
                    matchedIn = switch ($SearchMode) {
                    'FileName' { 'Dateiname' }
                    'Content'  { 'Inhalt' }
                    'Both'     { 'Dateiname + Inhalt' }
}
                }
            })
    }
    @{ ok = $true; count = $results.Count; results = $results } |
        ConvertTo-Json -Depth 6 -Compress
}
catch {
    @{ ok = $false; error = $_.Exception.Message; results = @() } |
        ConvertTo-Json -Depth 6 -Compress
    exit 1
}
finally {
    if ($null -ne $database) { $database.Dispose() }
}
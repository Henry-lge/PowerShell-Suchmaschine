#requires -Version 7.2
# GUI-Adapter: Anfrage lesen, DB-Schnittstelle aufrufen, Treffer als JSON ausgeben.
param(
    [string]$Query,
    [string]$DatabasePath = (Join-Path $PSScriptRoot 'data/index.sqlite3'),
    [ValidateRange(1, 1000)]
    [int]$Limit = 100,
    [string]$Extension,
    [ValidateSet('FileName', 'Content', 'Both')]
    [string]$SearchMode = 'Both',
    [switch]$Literal,
    [string[]]$IncludeExtensions = @(),
    [string[]]$ExcludeExtensions = @(),
    [switch]$ListExtensions
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$database = $null

try {
    if (
        -not $PSBoundParameters.ContainsKey('Query') -and
        -not $PSBoundParameters.ContainsKey('ListExtensions')
    ) {
        $request = [Console]::In.ReadToEnd() | ConvertFrom-Json
        $Query = [string]$request.query
        if ($null -ne $request.limit) { $Limit = [int]$request.limit }
        if ($null -ne $request.extension) { $Extension = [string]$request.extension }
        if ($null -ne $request.includeExtensions) {
            $IncludeExtensions = [string[]]$request.includeExtensions
        }
        if ($null -ne $request.excludeExtensions) {
            $ExcludeExtensions = [string[]]$request.excludeExtensions
        }
        if ($null -ne $request.literal) { $Literal = [bool]$request.literal }
        if ($request.action -eq 'listExtensions') { $ListExtensions = $true }

        $rawMode = $request.mode
        if ([string]::IsNullOrWhiteSpace([string]$rawMode)) {
            $rawMode = $request.searchMode
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$rawMode)) {
            switch ([string]$rawMode.Trim().ToLowerInvariant()) {
                'filename' { $SearchMode = 'FileName' }
                'content' { $SearchMode = 'Content' }
                'both' { $SearchMode = 'Both' }
                default { throw "Ungültiger Suchmodus: $rawMode" }
            }
        }
    }
    if ($Limit -lt 1 -or $Limit -gt 1000) {
        throw 'Limit muss zwischen 1 und 1000 liegen.'
    }

    $results = @()
    $extensions = @()
    if ($ListExtensions -or -not [string]::IsNullOrWhiteSpace($Query)) {
        if (-not (Test-Path -LiteralPath $DatabasePath -PathType Leaf)) {
            throw "Suchindex nicht gefunden: $DatabasePath. Bitte zuerst suchmaschine.ps1 ausführen."
        }
        Import-Module (Join-Path $PSScriptRoot 'src/Persistence/SqliteDateiRepository.psm1') -Force 6>$null
        $database = Initialize-Database -DatabasePath $DatabasePath 6>$null 3>$null

        if ($ListExtensions) {
            $extensions = @(Get-SearchExtensions -Database $database)
        }
        elseif (-not [string]::IsNullOrWhiteSpace($Query)) {
            # Die gesamte Suchlogik liegt hinter der DB-Schnittstelle.
            $searchParameters = @{
                Database = $database
                Query = $Query
                Limit = $Limit
                Extension = $Extension
                SearchMode = $SearchMode
                IncludeExtensions = $IncludeExtensions
                ExcludeExtensions = $ExcludeExtensions
            }
            if ($Literal) { $searchParameters.Literal = $true }

            try {
                $rawResults = @(Search-Query @searchParameters)
            }
            catch {
                if (
                    $Literal -or
                    $_.Exception.Message -notmatch '(?i)(fts|match|syntax)'
                ) {
                    throw
                }

                $searchParameters.Literal = $true
                $rawResults = @(Search-Query @searchParameters)
            }

            $matchedIn = switch ($SearchMode) {
                'FileName' { 'Dateiname' }
                'Content' { 'Inhalt' }
                'Both' { 'Dateiname + Inhalt' }
            }
            $results = @($rawResults | ForEach-Object {
                [ordered]@{
                    path = $_.File.Path
                    fileName = $_.File.Name
                    extension = $_.File.Extension
                    lastWriteUtc = $_.File.LastWriteTimeUtc.ToString('o')
                    snippet = $_.Snippet
                    score = [double]$_.Score
                    matchedIn = $matchedIn
                }
            })
        }
    }
    @{ ok = $true; count = $results.Count; results = $results; extensions = $extensions } |
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

#requires -Version 7.2
# GUI-Adapter: Anfrage lesen, DB-Schnittstelle aufrufen, Treffer als JSON ausgeben.
param(
    [string]$Query,
    [string]$DatabasePath = (Join-Path $PSScriptRoot 'data/index.sqlite3'),
    [ValidateRange(1, 1000)]
    [int]$Limit = 100,
    [string]$Extension
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$database = $null

try {
    if (-not $PSBoundParameters.ContainsKey('Query')) {
        $request = [Console]::In.ReadToEnd() | ConvertFrom-Json
        $Query = [string]$request.query
        if ($null -ne $request.limit) { $Limit = [int]$request.limit }
        if ($null -ne $request.extension) { $Extension = [string]$request.extension }
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

        # Die gesamte Suchlogik liegt hinter der DB-Schnittstelle.
        $results = @(Search-Query -Database $database -Query $Query -Limit $Limit -Extension $Extension |
            ForEach-Object {
                [ordered]@{
                    path = $_.File.Path
                    fileName = $_.File.Name
                    extension = $_.File.Extension
                    lastWriteUtc = $_.File.LastWriteTimeUtc.ToString('o')
                    snippet = $_.Snippet
                    score = [double]$_.Score
                    matchedIn = 'Inhalt'
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

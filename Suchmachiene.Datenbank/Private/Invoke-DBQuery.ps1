function Invoke-DBQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query
    )

    Write-Verbose "Führe interne DB-Abfrage aus: $Query"
    return "DB-OK"
}
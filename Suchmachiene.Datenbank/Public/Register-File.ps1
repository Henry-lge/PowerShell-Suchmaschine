function Register-File {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('FullName')]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [hashtable]$Metadata
    )

    process {
        if (-not (Test-Path -Path $Path)) {
            Write-Error "Datei nicht gefunden: $Path"
            return
        }

        $dbStatus = Invoke-DBQuery -Query "INSERT INTO files VALUES ('$Path')"

        Write-Verbose "Datei $Path erfolgreich indexiert."
        
        $fileInfo = Get-Item -Path $Path

        $record = [FileRecord]::new($fileInfo.FullName, $fileInfo.Length, $dbStatus)
        # Write-Host $record.GetTest()
        return $record
    }
}
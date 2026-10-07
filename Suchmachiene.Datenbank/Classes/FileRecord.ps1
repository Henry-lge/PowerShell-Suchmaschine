class FileRecord {
    [string]$Path
    [long]$Size
    [datetime]$IndexedAt
    [string]$Status

    # Konstruktor
    FileRecord([string]$path, [long]$size, [string]$status) {
        $this.Path = $path
        $this.Size = $size
        $this.IndexedAt = [datetime]::Now
        $this.Status = $status
    }

    [bool] GetTest() {
        return $true
    }
}
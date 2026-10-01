using module "./DateiEntitie.psm1"

class Scanner {

    # Scan counters.
    [int]$ScannedFolders = 0
    [int]$ScannedFiles = 0
    [int]$ContentFilesRead = 0
    [int]$ContentFilesSkipped = 0

    # Successfully processed files.
    [System.Collections.Generic.List[Datei]]$Files = [System.Collections.Generic.List[Datei]]::new()

    # Optional processing steps.
    [bool]$PrintFiles = $true
    [bool]$CalculateHashes = $true
    [bool]$ReadContents = $true

    # Maximum content size to read.
    [Int64]$MaxContentSizeBytes = 10MB

    # Supported content extensions.
    [string[]]$ContentExtensions = @(
        ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx",
        ".txt", ".pdf", ".md", ".markdown", ".html", ".htm",
        ".csv", ".json", ".xml"
    )

    # Recursively scan a folder.
    [void] ScanFolder([string]$folderPath) {
        $this.ScannedFolders++
        try {
            # Ignore inaccessible, hidden, and system entries.
            $options = [System.IO.EnumerationOptions]::new()
            $options.IgnoreInaccessible = $true
            $options.AttributesToSkip = [System.IO.FileAttributes]::Hidden -bor
                [System.IO.FileAttributes]::System
            $items = [System.IO.DirectoryInfo]::new($folderPath).EnumerateFileSystemInfos("*", $options)
        } catch {
            # Skip inaccessible or invalid folders.
            return
        }

        foreach ($item in $items) {
            if ($item -is [System.IO.DirectoryInfo]) {
                # Scan subfolders recursively.
                $this.ScanFolder($item.FullName)
            } else {
                $this.ScannedFiles++
                $datei = $this.ProcessFile($item)
                if ($null -ne $datei) {
                    # Store successfully processed files.
                    [void]$this.Files.Add($datei)
                }
            }
        }
    }

    # Process one file.
    [Datei] ProcessFile([System.IO.FileInfo]$file) {
        try {
            # Copy file metadata.
            $datei = [Datei]::new()
            $datei.Name = $file.Name
            $datei.Path = $file.FullName
            $datei.Extension = $file.Extension
            $datei.Size = $file.Length
            $datei.CreationTime = $file.CreationTime
            $datei.LastWriteTime = $file.LastWriteTime
            $datei.LastAccessTime = $file.LastAccessTime

            $extension = $file.Extension.ToLowerInvariant()
            $isContentFormat = $this.ContentExtensions -contains $extension

            # Read supported content within the size limit.
            if ($this.ReadContents -and $isContentFormat -and $file.Length -le $this.MaxContentSizeBytes) {
                $datei.Content = [System.IO.File]::ReadAllText($file.FullName)
                $this.ContentFilesRead++
            } else {
                $this.ContentFilesSkipped++
            }

            # Calculate a SHA256 content hash.
            if ($this.CalculateHashes) {
                $datei.Hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
            }

            # Print the collected metadata when enabled.
            if ($this.PrintFiles) {
                $datei.print() | Out-Host
            }
            return $datei
        } catch {
            # Keep scanning when one file fails.
            Write-Warning "Metadaten konnten nicht gelesen werden: $($file.FullName)"
            return $null
        }
    }

}
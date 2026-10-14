using module "./DateiEntitie.psm1"

#requires -Version 7.0


# =============================================================================
# LAYER 1: CONFIGURATION
# =============================================================================

$script:MaxContentSizeBytes = 10MB

# These extensions limit content loading to supported document types.
# Content is read as text; binary formats are not converted.
$script:DefaultContentExtensions = @(
    ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx",
    ".txt", ".pdf", ".md", ".markdown", ".html", ".htm",
    ".csv", ".json", ".xml"
)

$script:DefaultAttributesToSkip = (
    [System.IO.FileAttributes]::Hidden -bor
    [System.IO.FileAttributes]::System -bor
    [System.IO.FileAttributes]::Temporary
)


# =============================================================================
# LAYER 2: PERSISTENCE ADAPTER
# =============================================================================

# The adapter stores the last processed timestamp for each file path.
# This allows later scans to skip files that have not changed.
$script:DummyDatabase = @{}

$script:DatabaseAdapter = @{
    GetLastWriteTimeUtc = {
        param(
            [string]$Path
        )

        # Hashtable lookup returns $null for paths that are not stored yet.
        return $script:DummyDatabase[$Path]
    }

    SaveFile = {
        param(
            [Datei]$Datei,
            [datetime]$LastWriteTimeUtc
        )

        $script:DummyDatabase[$Datei.Path] = $LastWriteTimeUtc
    }
}


# =============================================================================
# LAYER 3: PUBLIC DATABASE HELPERS
# =============================================================================

# These wrappers preserve the existing public access points.
# The scanner itself uses the adapter for both operations.

function Test-FileUnchangedInDatabase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [datetime]$LastWriteTimeUtc
    )

    $storedLastWriteTimeUtc = & $script:DatabaseAdapter.GetLastWriteTimeUtc `
        -Path $Path

    if ($null -eq $storedLastWriteTimeUtc) {
        return $false
    }

    return (
        ([datetime]$storedLastWriteTimeUtc).Ticks -eq
        $LastWriteTimeUtc.Ticks
    )
}


function Save-FileToDatabase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Datei]$Datei,

        [Parameter(Mandatory = $true)]
        [datetime]$LastWriteTimeUtc
    )

    & $script:DatabaseAdapter.SaveFile `
        -Datei $Datei `
        -LastWriteTimeUtc $LastWriteTimeUtc
}


class Scanner {

    # =============================================================================
    # LAYER 4: SCANNER STATE
    # =============================================================================

    # Counters expose scan progress and processing results.
    [int]$ScannedFolders = 0
    [int]$ScannedFiles = 0
    [int]$ProcessedFiles = 0
    [int]$FailedFiles = 0
    [int]$ContentFilesRead = 0
    [int]$ContentFilesSkipped = 0
    [int]$UnchangedFiles = 0

    # Results and errors remain available for separate evaluation after scanning.
    [System.Collections.Generic.List[Datei]]$Files = (
        [System.Collections.Generic.List[Datei]]::new()
    )

    [System.Collections.Generic.List[string]]$Errors = (
        [System.Collections.Generic.List[string]]::new()
    )

    # These properties control filters, content loading, and scan output.
    [bool]$ReadContents = $true
    [bool]$VerboseOutput = $false
    [bool]$ProgressOutput = $false

    [long]$MaxContentSizeBytes = $script:MaxContentSizeBytes

    [string[]]$ContentExtensions = $script:DefaultContentExtensions

    [System.IO.FileAttributes]$AttributesToSkip = (
        $script:DefaultAttributesToSkip
    )

    [int]$ProgressInterval = 100

    # Skipping directory links prevents cycles by default.
    [bool]$FollowDirectoryLinks = $false

    # Prepared enumeration and extension filters for the current scan.
    hidden [int]$_fileCounter = 0

    hidden [System.IO.EnumerationOptions]$_enumerationOptions

    hidden [System.Collections.Generic.HashSet[string]]$_contentExtensionSet


    # =============================================================================
    # LAYER 5: SCAN PREPARATION
    # =============================================================================

    hidden [void] _PrepareScan() {
        $this._enumerationOptions = (
            [System.IO.EnumerationOptions]::new()
        )

        $this._enumerationOptions.IgnoreInaccessible = $true
        $this._enumerationOptions.AttributesToSkip = $this.AttributesToSkip
        $this._enumerationOptions.ReturnSpecialDirectories = $false

        # Subdirectories are processed individually so folders can be counted
        # separately and link handling remains under scanner control.
        $this._enumerationOptions.RecurseSubdirectories = $false

        $this._contentExtensionSet = (
            [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase
            )
        )

        foreach ($extension in $this.ContentExtensions) {
            if (-not [string]::IsNullOrWhiteSpace($extension)) {
                [void]$this._contentExtensionSet.Add($extension)
            }
        }
    }


    # =============================================================================
    # LAYER 6: DIRECTORY SCANNING
    # =============================================================================

    [void] ScanFolder([string]$folderPath) {
        if ([string]::IsNullOrWhiteSpace($folderPath)) {
            Write-Warning "Folder path must not be empty."
            return
        }

        if (-not [System.IO.Directory]::Exists($folderPath)) {
            Write-Warning (
                "Folder does not exist or is inaccessible: $folderPath"
            )
            return
        }

        # Rebuild filters before every scan so configuration changes take effect.
        $this._PrepareScan()

        $this._ScanFolderInternal($folderPath)
    }


    [void] _ScanFolderInternal([string]$folderPath) {
        # This fallback also makes direct internal calls safe on a new instance.
        if ($null -eq $this._enumerationOptions) {
            $this._PrepareScan()
        }

        $this.ScannedFolders++

        try {
            $directory = [System.IO.DirectoryInfo]::new($folderPath)

            $items = $directory.EnumerateFileSystemInfos(
                "*",
                $this._enumerationOptions
            )

            foreach ($item in $items) {
                if ($item -is [System.IO.DirectoryInfo]) {
                    if (
                        -not $this.FollowDirectoryLinks -and
                        (
                            ($item.Attributes -band
                                [System.IO.FileAttributes]::ReparsePoint
                            ) -ne 0
                        )
                    ) {
                        continue
                    }

                    $this._ScanFolderInternal($item.FullName)
                    continue
                }

                if ($item -isnot [System.IO.FileInfo]) {
                    continue
                }

                $this.ScannedFiles++
                $this._fileCounter++

                $datei = $this.ProcessFile($item)

                if ($null -ne $datei) {
                    [void]$this.Files.Add($datei)
                    $this.ProcessedFiles++
                }
                else {
                    $this.FailedFiles++
                }

                if (
                    $this.ProgressOutput -and
                    $this.ProgressInterval -gt 0 -and
                    (
                        $this._fileCounter % $this.ProgressInterval -eq 0
                    )
                ) {
                    Write-Host (
                        "Scanned: {0} | Processed: {1} | Unchanged: {2} | Failed: {3}" -f
                        $this.ScannedFiles,
                        $this.ProcessedFiles,
                        $this.UnchangedFiles,
                        $this.FailedFiles
                    )
                }
            }
        }
        catch {
            $errorMsg = (
                "Folder enumeration failed: {0} - {1}" -f
                $folderPath,
                $_.Exception.Message
            )

            [void]$this.Errors.Add($errorMsg)
            Write-Warning $errorMsg
        }
    }


    # =============================================================================
    # LAYER 7: FILE PROCESSING
    # =============================================================================

    [Datei] ProcessFile([System.IO.FileInfo]$file) {
        if ($null -eq $file) {
            $errorMsg = "File processing failed: FileInfo must not be null."

            [void]$this.Errors.Add($errorMsg)
            Write-Warning $errorMsg

            return $null
        }

        try {
            # Direct calls require the same preparation as a complete scan.
            if ($null -eq $this._contentExtensionSet) {
                $this._PrepareScan()
            }

            # Enumeration already provides the required metadata.
            # Refreshing would cause unnecessary file system access.
            if (-not $file.Exists) {
                throw "File no longer exists: $($file.FullName)"
            }

            $filePath = $file.FullName
            $fileSize = $file.Length
            $lastWriteTimeUtc = $file.LastWriteTimeUtc

            # The stored timestamp provides a fast change check.
            $storedLastWriteTimeUtc = (
                & $script:DatabaseAdapter.GetLastWriteTimeUtc `
                    -Path $filePath
            )

            $isUnchanged = (
                $null -ne $storedLastWriteTimeUtc -and
                (
                    ([datetime]$storedLastWriteTimeUtc).Ticks -eq
                    $lastWriteTimeUtc.Ticks
                )
            )

            # Return unchanged files as well so results represent the complete
            # scan inventory.
            $datei = [Datei]::new()
            $datei.Name = $file.Name
            $datei.Path = $filePath
            $datei.Extension = $file.Extension.ToLowerInvariant()
            $datei.Size = $fileSize
            $datei.CreationTime = $file.CreationTime
            $datei.LastWriteTime = $file.LastWriteTime
            $datei.LastAccessTime = $file.LastAccessTime

            if ($isUnchanged) {
                $this.UnchangedFiles++
                $this.ContentFilesSkipped++

                if ($this.VerboseOutput) {
                    Write-Host "File unchanged, skipping content: $filePath"
                }

                return $datei
            }

            # Read content only when all three safeguards pass: enabled, small
            # enough, and matching a supported extension.
            if (
                $this.ReadContents -and
                $fileSize -le $this.MaxContentSizeBytes -and
                $this._contentExtensionSet.Contains($datei.Extension)
            ) {
                try {
                    $datei.Content = [System.IO.File]::ReadAllText(
                        $filePath
                    )

                    $this.ContentFilesRead++
                }
                catch {
                    $errorMsg = (
                        "Content read failed: {0} - {1}" -f
                        $filePath,
                        $_.Exception.Message
                    )

                    [void]$this.Errors.Add($errorMsg)
                    Write-Warning $errorMsg

                    # Without saving, a later scan will retry the failed read.
                    return $null
                }
            }
            else {
                $this.ContentFilesSkipped++
            }

            & $script:DatabaseAdapter.SaveFile `
                -Datei $datei `
                -LastWriteTimeUtc $lastWriteTimeUtc

            if ($this.VerboseOutput) {
                $datei.print() | Out-Host
            }

            return $datei
        }
        catch {
            $errorMsg = (
                "File processing failed: {0} - {1}" -f
                $file.FullName,
                $_.Exception.Message
            )

            [void]$this.Errors.Add($errorMsg)
            Write-Warning $errorMsg

            return $null
        }
    }


    # =============================================================================
    # LAYER 8: STATE RESET
    # =============================================================================

    [void] Reset() {
        $this.Files.Clear()
        $this.Errors.Clear()

        $this.ScannedFolders = 0
        $this.ScannedFiles = 0
        $this.ProcessedFiles = 0
        $this.FailedFiles = 0
        $this.ContentFilesRead = 0
        $this.ContentFilesSkipped = 0
        $this.UnchangedFiles = 0
        $this._fileCounter = 0

        # The next operation must rebuild all derived filters.
        $this._enumerationOptions = $null
        $this._contentExtensionSet = $null

        # Keep the timestamp cache so later scans can detect unchanged files.
    }
}

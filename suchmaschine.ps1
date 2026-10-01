# Load the scanner module.
using module "./docScanner.psm1"

# Create a scanner with default options.
$docScanner = [Scanner]::new()

# Measure the scan duration.
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Recursively scan the root folder.
$docScanner.ScanFolder("/Users/henry/Developer/")

# Stop the timer after scanning.
$stopwatch.Stop()

# Print the scan summary.
Write-Host "Scanned folders: $($docScanner.ScannedFolders)"
Write-Host "Scanned files: $($docScanner.ScannedFiles)"
Write-Host "Files with content read: $($docScanner.ContentFilesRead)"
Write-Host "Files with content skipped: $($docScanner.ContentFilesSkipped)"
Write-Host "Scan duration: $($stopwatch.Elapsed.TotalSeconds.ToString('F3')) seconds"
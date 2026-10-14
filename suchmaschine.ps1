# Load the scanner module.
using module "./DocScanner.psm1"

# Create a scanner with default options.
$docScanner = [Scanner]::new()

# Optional: Enable progress output for large scans
$docScanner.ProgressOutput = $true
$docScanner.VerboseOutput = $false

# Measure the scan duration.
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Recursively scan the root folder.
$docScanner.ScanFolder("/Users/henry/Developer/")

# Stop the timer after scanning.
$stopwatch.Stop()

# Print the scan summary.
Write-Host "Scanned folders: $($docScanner.ScannedFolders)"
Write-Host "Scanned files: $($docScanner.ScannedFiles)"
Write-Host "Processed files: $($docScanner.ProcessedFiles)"
Write-Host "Failed files: $($docScanner.FailedFiles)"
Write-Host "Files with content read: $($docScanner.ContentFilesRead)"
Write-Host "Files with content skipped: $($docScanner.ContentFilesSkipped)"
Write-Host "Hash matches (skipped): $($docScanner.HashMatches)"
Write-Host "Errors: $($docScanner.Errors.Count)"
Write-Host "Scan duration: $($stopwatch.Elapsed.TotalSeconds.ToString('F3')) seconds"
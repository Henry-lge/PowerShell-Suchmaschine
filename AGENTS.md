# PowerShell Suchmaschine / Full-Text Search Engine

## Development Environment

### Prerequisites
- **PowerShell 7.2+** (required by module `requires -Version 7.2`)
- PowerShell modules loaded via `using module` statements at file top

### Main Entry Points

| File | Purpose |
|------|---------|
| `suchmaschine.ps1` | CLI entrypoint for scanning directories and creating a SQLite search index |
| `src/Crawler/Crawler.psm1` | Directory scanning, change detection, and document extraction |
| `src/Persistence/SqliteDateiRepository.psm1` | SQLite storage, FTS5 search, and database service API |

## Running the Crawler/Scanner

```powershell
# Run the main script - scans $HOME by default, creates ./data/search.sqlite3
$env:PWD = "/some/path"; . "./suchmaschine.ps1"

# With custom parameters:
./suchmaschine.ps1 -RootPath "C:\Docs\" -ExcludePath @("node_modules", ".git") `
    -DatabasePath "$HOME/.my-search-index/search.sqlite3"
```

## Repository Implementations (Exchangeable via Crawler.Repository)

### Default: SqliteDateiRepository
- SQLite metadata and a full-text inverted index using **FTS5**.
- SQLite provider assemblies and the native runtime are downloaded from NuGet on first use into `./lib/sqlite`.
- Uses transactions for batch saves and WAL mode for concurrent readers.
- The Crawler depends only on `DateiRepository`, so another backend can be added without changing scanning or content extraction.

The database API is available from `src/Persistence/SqliteDateiRepository.psm1`:

```powershell
using module "./src/Model/Datei.psm1"
using module "./src/Persistence/SqliteDateiRepository.psm1"

$database = Initialize-Database -DatabasePath "./data/search.sqlite3"
try {
    $results = Search-Query -Database $database -Query "full text" -Limit 25
}
finally {
    $database.Dispose()
}
```

`Add-File` and `Sync-Files` accept `[Datei]` records; document discovery and
content extraction remain outside the persistence module. Search uses SQLite
FTS5 syntax and returns each result's file metadata, relevance score, and
matching excerpt.

## DocScanner Supported Types

The following readers exist and are auto-loaded by `using module` statements in `src/DocScanner/`:

| Reader | Extensions | Notes |
|--------|------------|-------|
| TextContentReader | .txt, .md, .log, .xml* | UTF8 default |
| WordContentReader/legacy* | docx, rtf* | OpenXML (docx, odt) + legacy .doc RTF fallbacks |
| ExcelContentReader/legacy* | xlsx, ods, csv*, rtf* | Office 2013+ OpenXML formats preferred |
| PowerPointContentReader/legacy* | pptx, odp, ppsx, potx | All variants supported |
| PdfContentReader | .pdf | PDF extraction only |
| EpubContentReader | .epub | eBook parsing |
| EmIContent/MsgConten treader | eml, msg | Email content (plain text) only |
| ImageOcrContentReader | *.jpg, *.png*, etc. | OCR via Tesseract if available |

\* = Multiple reader files exist; primary one is used based on encoding detection
RTF: OpenDocument uses UTF16 (legacy .rtf may use other encodings per content)

Run for overview: `$crawler.DocScanner.GetReaderOverview() \| Format-Table`

## Key Architecture Facts

### Change Detection
File change detection relies **solely on LastWriteTimeUtc.Ticks** (not hash):

```powershell
$isUnchanged = ($null -ne $stored -and
    $datei.LastWriteTimeUtc.Ticks -eq $fileInfo.LastWriteTimeUtc.Ticks)
```

- Saves time compared to always computing file hashes
- **Known limitation**: File content changes without timestamp change will not be detected until re-indexed (or touched manually). For robustness, consider: periodic scans of "stable" files OR a `touch` operation after edits.

### Platform-Specific Cloud Detection

| OS | Detection Method | What Gets Skipped |
|----|------------------|--------------------|
| macOS | Native `lstat()` calling DarwinFileFlags::IsDataless() via P/Invoke; checks for SF_DATALESS (0x40000000) flag on files with iCloud, OneDrive "Files On-Demand," Dropbox selective sync enabled. | Only skipped when content can't be read without download AND you're not using ReadCloudOnlyFiles.

Windows
| Checks for attributes 0x100 (OfflineCache), 0x4wOo0)24Rr53(RecalOnOpne, or OnDataAccess); only triggers after file has been accessed. | Same behavior as macOS.
```powershell
IsCloudOnly() returns $true → content is NOT read unless ReadContents and you're not using cloud-only files.

Reads are skipped to avoid performance penalties; next scan succeeds once download occurs.

### Path Normalization & Cross-Platform Sensitivity

`PathUtil.Normalize()` removes trailing separators and ensures consistent full paths.
Crawler uses: `System.StringComparer::OrdinalIgnoreCase`. All path comparisons are case-insensitive on macOS/Windows, exact match (case-sensitive) on Linux. The code explicitly handles this via separate GetComparison() calls in IsSameOrUnder().

### Error Reporting Format

Errors reported as objects with structured data for filtering:
- [phase] - [/path] message where phase ∈ {Folder, Metadata, Content, Repository}
Filter example: `$crawler.Errors \| Where-Object Phase -eq "Content" | Select-Object @{Name="Path"; Expression={$_.`Path}}, Message`

## Critical Setup & Build Notes

1. SQLite assemblies and the native library are installed automatically by `src/Persistence/Install-Sqlite.ps1`.
2. The first run needs network access to NuGet unless the runtime files are already present in `lib/sqlite`.

Run the database tests with Pester:

```powershell
Invoke-Pester ./tests/SqliteDateiRepository.Tests.ps1
```

## Common Pitfalls

- Cloud file detection only affects macOS/iCloud, Windows offline files need proper attribute flags set by cloud sync clients
- Full-text matching and tokenization are provided by SQLite FTS5; queries may use FTS5 operators and quoted phrases.

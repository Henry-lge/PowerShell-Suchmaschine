using module "../ContentReader.psm1"

#requires -Version 7.2


# =============================================================================
# READER FÜR ARCHIVE
# =============================================================================

# Gibt die Namen der Dateien in einem Archiv zurück, eine pro Zeile. So findet
# eine Suche nach einem Dateinamen auch das Archiv, das die Datei enthält. Die
# Dateien werden nur aufgelistet, nie entpackt.
#
# Tools:
#   - .zip                   in .NET eingebaut, alle Plattformen
#   - .tar, .tgz, .gz, ...   "tar" (Windows 10+, macOS, Linux)
#   - .7z, .rar              "tar", wenn es bsdtar/libarchive ist (macOS,
#                            Windows), sonst 7-Zip ("7z", "7zz", "7za")
# Die unterstützten Endungen werden im Konstruktor abhängig von den
# installierten Tools gewählt, damit fehlende Tools nie zu Fehlern im Scan
# führen.
#
# Eine einzelne komprimierte Datei wie "notes.txt.gz" ist kein Archiv; ihr
# Inhalt ist der Name der inneren Datei ("notes.txt").
class ArchiveContentReader : ContentReader {

    # Sehr große Archive werden nach so vielen Namen abgeschnitten.
    [int]$MaxEntries = 10000

    hidden [string]$_tarTool
    hidden [bool]$_tarIsLibarchive
    hidden [string]$_sevenZipTool


    ArchiveContentReader() {
        $this.Description = "Archives (file list)"

        $supported = [System.Collections.Generic.List[string]]::new()
        $supported.Add(".zip")

        $this._tarTool = $this.FindTool(@("bsdtar", "tar"))
        $this._sevenZipTool = $this.FindTool(@("7z", "7zz", "7za"))

        if (-not [string]::IsNullOrEmpty($this._tarTool)) {
            $supported.AddRange([string[]]@(".tar", ".tgz", ".tbz2", ".txz", ".gz", ".bz2", ".xz"))

            # bsdtar (libarchive) listet auch 7z und RAR auf, GNU tar nicht.
            try {
                $version = $this.RunTool($this._tarTool, @("--version"), 10)
                $this._tarIsLibarchive = $version -match "bsdtar|libarchive"
            }
            catch {
                $this._tarIsLibarchive = $false
            }
        }

        if ($this._tarIsLibarchive -or -not [string]::IsNullOrEmpty($this._sevenZipTool)) {
            $supported.AddRange([string[]]@(".7z", ".rar"))
        }

        $this.Extensions = $supported.ToArray()
    }


    [string] ReadContent([System.IO.FileInfo]$file) {
        $extension = $file.Extension.ToLowerInvariant()

        if ($extension -eq ".zip") {
            return $this._FormatNames($this._ListZip($file))
        }

        # "x.txt.gz" ist eine einzelne komprimierte Datei, "x.tar.gz" ein Archiv.
        if (
            $extension -in @(".gz", ".bz2", ".xz") -and
            $file.Name -notmatch "\.tar\.(gz|bz2|xz)$"
        ) {
            return [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        }

        if ($extension -in @(".7z", ".rar") -and -not $this._tarIsLibarchive) {
            return $this._FormatNames($this._ListSevenZip($file))
        }

        $output = $this.RunTool($this._tarTool, @("-tf", $file.FullName), 60)

        return $this._FormatNames($output -split "\r?\n")
    }


    hidden [string[]] _ListZip([System.IO.FileInfo]$file) {
        $zip = $this.OpenZip($file)

        try {
            return [string[]]@($zip.Entries | ForEach-Object { $_.FullName })
        }
        finally {
            $zip.Dispose()
        }
    }


    # "7z l -slt" gibt pro Eintrag eine Zeile "Path = ..." aus; -ba blendet
    # den Kopfbereich mit dem Pfad des Archivs selbst aus.
    hidden [string[]] _ListSevenZip([System.IO.FileInfo]$file) {
        $output = $this.RunTool($this._sevenZipTool, @("l", "-ba", "-slt", $file.FullName), 60)

        return [string[]]@(
            $output -split "\r?\n" |
                Where-Object { $_.StartsWith("Path = ") } |
                ForEach-Object { $_.Substring(7) }
        )
    }


    # Ein Name pro Zeile ohne Ordnereinträge, begrenzt auf MaxEntries.
    hidden [string] _FormatNames([string[]]$names) {
        $files = @(
            $names |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_) -and
                    -not $_.EndsWith("/") -and
                    -not $_.EndsWith("\")
                } |
                ForEach-Object {
                    # tar gibt "./name" aus; macOS speichert Umlaute zerlegt
                    # (o + kombinierendes Zeichen), Normalize() setzt sie
                    # wieder zusammen.
                    $name = if ($_.StartsWith("./")) { $_.Substring(2) } else { $_ }
                    $name.Normalize()
                }
        )

        if ($files.Count -le $this.MaxEntries) {
            return $files -join "`n"
        }

        $shown = $files[0..($this.MaxEntries - 1)] -join "`n"

        return "$shown`n... ($($files.Count - $this.MaxEntries) more)"
    }
}

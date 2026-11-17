using module "./Readers/ContentReader.psm1"
using module "./Readers/Text/TextContentReader.psm1"
using module "./Readers/Office/WordContentReader.psm1"
using module "./Readers/Office/ExcelContentReader.psm1"
using module "./Readers/Office/PowerPointContentReader.psm1"
using module "./Readers/Office/LegacyWordContentReader.psm1"
using module "./Readers/Office/LegacyExcelContentReader.psm1"
using module "./Readers/Office/LegacyPowerPointContentReader.psm1"
using module "./Readers/Office/OpenDocumentContentReader.psm1"
using module "./Readers/Office/RtfContentReader.psm1"
using module "./Readers/Office/IWorkContentReader.psm1"
using module "./Readers/Pdf/PdfContentReader.psm1"
using module "./Readers/Image/ImageOcrContentReader.psm1"
using module "./Readers/Ebook/EpubContentReader.psm1"
using module "./Readers/Mail/EmlContentReader.psm1"
using module "./Readers/Mail/MsgContentReader.psm1"
using module "./Readers/Media/MediaContentReader.psm1"
using module "./Readers/Archive/ArchiveContentReader.psm1"

#requires -Version 7.4


# =============================================================================
# DOCSCANNER
# =============================================================================

# Der DocScanner liest den Textinhalt einer einzelnen Datei. Er durchläuft
# keine Ordner (das ist Aufgabe des Crawlers), sondern wählt nur den Reader,
# der für die Dateiendung registriert ist, und gibt die Arbeit an ihn weiter.
#
# Alle Klassen des DocScanners und seiner Reader tragen [NoRunspaceAffinity()],
# weil der Crawler sie in mehreren Worker-Runspaces gleichzeitig verwendet
# (siehe Crawler.psm1). Neue Reader brauchen das Attribut ebenfalls.
[NoRunspaceAffinity()]
class DocScanner {

    # Größere Dateien werden übersprungen, damit der Speicherbedarf
    # vorhersehbar bleibt.
    [long]$MaxContentSizeBytes = 10MB

    # Endung -> Reader. Ohne Beachtung der Groß-/Kleinschreibung, damit ".PDF"
    # und ".pdf" passen.
    hidden [System.Collections.Generic.Dictionary[string, ContentReader]]$_readers = (
        [System.Collections.Generic.Dictionary[string, ContentReader]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
    )

    # Jeder an RegisterReader() übergebene Reader, auch nicht verfügbare, für
    # GetReaderOverview().
    hidden [System.Collections.Generic.List[ContentReader]]$_allReaders = (
        [System.Collections.Generic.List[ContentReader]]::new()
    )


    # True, sobald nach dem Konstruktor ein Reader registriert wurde.
    hidden [bool]$_defaultsRegistered = $false
    hidden [bool]$_hasCustomReaders = $false


    DocScanner() {
        $this.RegisterDefaultReaders()
        $this._defaultsRegistered = $true
    }


    # True, wenn zur Laufzeit eigene Reader registriert wurden. Die Worker des
    # Crawlers bauen ihren DocScanner nur mit den Standard-Readern nach und
    # kennen diese Reader nicht; der Crawler liest dann nacheinander.
    [bool] HasCustomReaders() {
        return $this._hasCustomReaders
    }


    # Alle bekannten Reader. Reader, deren IsAvailable() $false liefert,
    # erscheinen in der Übersicht, werden aber erst nach ihrer Implementierung
    # verwendet.
    hidden [void] RegisterDefaultReaders() {
        # Text
        $this.RegisterReader([TextContentReader]::new())

        # Office
        $this.RegisterReader([WordContentReader]::new())
        $this.RegisterReader([ExcelContentReader]::new())
        $this.RegisterReader([PowerPointContentReader]::new())
        $this.RegisterReader([LegacyWordContentReader]::new())
        $this.RegisterReader([LegacyExcelContentReader]::new())
        $this.RegisterReader([LegacyPowerPointContentReader]::new())
        $this.RegisterReader([OpenDocumentContentReader]::new())
        $this.RegisterReader([RtfContentReader]::new())
        $this.RegisterReader([IWorkContentReader]::new())

        # Weitere Dokumente
        $this.RegisterReader([PdfContentReader]::new())
        $this.RegisterReader([EpubContentReader]::new())
        $this.RegisterReader([EmlContentReader]::new())
        $this.RegisterReader([MsgContentReader]::new())

        # Bilder, Medien und Archive
        $this.RegisterReader([ImageOcrContentReader]::new())
        $this.RegisterReader([MediaContentReader]::new())
        $this.RegisterReader([ArchiveContentReader]::new())
    }


    # Ordnet jede Endung des Readers ihm zu. Eine spätere Registrierung für
    # dieselbe Endung ersetzt die frühere. Nicht verfügbare Reader werden
    # ignoriert.
    [void] RegisterReader([ContentReader]$reader) {
        if ($null -eq $reader) {
            return
        }

        if ($this._defaultsRegistered) {
            $this._hasCustomReaders = $true
        }

        $this._allReaders.Add($reader)

        if (-not $reader.IsAvailable()) {
            return
        }

        foreach ($extension in $reader.Extensions) {
            if (-not [string]::IsNullOrWhiteSpace($extension)) {
                $this._readers[$extension] = $reader
            }
        }
    }


    [bool] CanRead([string]$extension) {
        return (
            -not [string]::IsNullOrEmpty($extension) -and
            $this._readers.ContainsKey($extension)
        )
    }


    [string[]] GetSupportedExtensions() {
        return [string[]]$this._readers.Keys
    }


    # Eine Zeile pro Reader: welche Dateitypen es gibt und welche bereits
    # implementiert sind. Beispiel: $crawler.DocScanner.GetReaderOverview() | Format-Table
    [PSCustomObject[]] GetReaderOverview() {
        return [PSCustomObject[]]@(
            foreach ($reader in $this._allReaders) {
                [PSCustomObject][ordered]@{
                    Reader      = $reader.GetName()
                    Description = $reader.Description
                    Available   = $reader.IsAvailable()
                    Extensions  = $reader.Extensions -join " "
                }
            }
        )
    }


    # Gibt $true zurück, wenn der Inhalt der Datei gelesen werden soll: Es
    # gibt einen Reader und die Datei ist klein genug.
    [bool] ShouldRead([System.IO.FileInfo]$file) {
        if ($null -eq $file -or -not $this.CanRead($file.Extension)) {
            return $false
        }

        # Ein Reader kann eine eigene Grenze haben (ContentReader.MaxFileSizeBytes).
        $limit = $this._readers[$file.Extension].MaxFileSizeBytes

        if ($limit -le 0) {
            $limit = $this.MaxContentSizeBytes
        }

        return $file.Length -le $limit
    }


    # True, wenn der Reader dieser Datei nach dem Lesen im Hintergrund noch
    # etwas ergänzt (ContentReader.CanEnrich).
    [bool] CanEnrich([System.IO.FileInfo]$file) {
        return (
            $this.ShouldRead($file) -and
            $this._readers[$file.Extension].CanEnrich($file)
        )
    }


    # Ergänzungen für mehrere Dateien (ContentReader.Enrich), gleiche
    # Reihenfolge wie $files. Jeder Reader bekommt seine Dateien auf einmal.
    [string[]] Enrich([System.IO.FileInfo[]]$files) {
        $results = [string[]]::new($files.Length)
        $byReader = [System.Collections.Generic.Dictionary[ContentReader, System.Collections.Generic.List[int]]]::new()

        for ($i = 0; $i -lt $files.Length; $i++) {
            if (-not $this.CanEnrich($files[$i])) {
                continue
            }

            $reader = $this._readers[$files[$i].Extension]
            $indexes = $null

            if (-not $byReader.TryGetValue($reader, [ref]$indexes)) {
                $indexes = [System.Collections.Generic.List[int]]::new()
                $byReader[$reader] = $indexes
            }

            $indexes.Add($i)
        }

        foreach ($entry in $byReader.GetEnumerator()) {
            $subset = [System.IO.FileInfo[]]::new($entry.Value.Count)

            for ($j = 0; $j -lt $subset.Length; $j++) {
                $subset[$j] = $files[$entry.Value[$j]]
            }

            $texts = $entry.Key.Enrich($subset)

            for ($j = 0; $j -lt $subset.Length -and $j -lt $texts.Length; $j++) {
                $results[$entry.Value[$j]] = $texts[$j]
            }
        }

        return $results
    }


    # True, wenn der Reader dieser Datei im Hintergrund laufen soll
    # (ContentReader.RunsInBackground).
    [bool] RunsInBackground([System.IO.FileInfo]$file) {
        return (
            $null -ne $file -and
            $this.CanRead($file.Extension) -and
            $this._readers[$file.Extension].RunsInBackground
        )
    }


    # Kündigt den Readern ein Paket von Dateien an, die gleich einzeln
    # gelesen werden (siehe ContentReader.Prepare). Fehler hier sind nicht
    # schlimm: Dann liest ReadContent() die Datei wie ohne Vorbereitung.
    [void] Prepare([System.IO.FileInfo[]]$files) {
        $byReader = [System.Collections.Generic.Dictionary[ContentReader, System.Collections.Generic.List[System.IO.FileInfo]]]::new()

        foreach ($file in $files) {
            if (-not $this.ShouldRead($file)) {
                continue
            }

            $reader = $this._readers[$file.Extension]
            $list = $null

            if (-not $byReader.TryGetValue($reader, [ref]$list)) {
                $list = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
                $byReader[$reader] = $list
            }

            $list.Add($file)
        }

        foreach ($entry in $byReader.GetEnumerator()) {
            try {
                $entry.Key.Prepare($entry.Value.ToArray())
            }
            catch {
                # Die Dateien werden dann einzeln gelesen.
            }
        }
    }


    # Gibt den ausgelesenen Text zurück oder $null, wenn die Datei nicht
    # unterstützt wird. Lesefehler werden an den Aufrufer weitergegeben.
    [string] ReadContent([System.IO.FileInfo]$file) {
        if (-not $this.ShouldRead($file)) {
            return $null
        }

        return $this._readers[$file.Extension].ReadContent($file)
    }
}

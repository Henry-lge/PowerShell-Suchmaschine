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

#requires -Version 7.2


# =============================================================================
# DOCSCANNER
# =============================================================================

# Der DocScanner liest den Textinhalt einer einzelnen Datei. Er durchläuft
# keine Ordner (das ist Aufgabe des Crawlers), sondern wählt nur den Reader,
# der für die Dateiendung registriert ist, und gibt die Arbeit an ihn weiter.
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


    DocScanner() {
        $this.RegisterDefaultReaders()
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
        return (
            $null -ne $file -and
            $file.Length -le $this.MaxContentSizeBytes -and
            $this.CanRead($file.Extension)
        )
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

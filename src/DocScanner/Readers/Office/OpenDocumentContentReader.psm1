using module "../ContentReader.psm1"
using module "../Shared/XmlText.psm1"

#requires -Version 7.2


# =============================================================================
# READER FÜR OPENDOCUMENT
# =============================================================================

# Liest den Text von LibreOffice-/OpenOffice-Dokumenten. Die Datei ist ein
# ZIP-Archiv mit XML-Dateien, daher wird kein zusätzliches Tool benötigt.
#
# Alle Formate (Text, Tabelle, Präsentation, Zeichnung) speichern ihren
# Inhalt in content.xml mit denselben Textelementen:
#   <text:p>, <text:h>       Absatz, Überschrift
#   <text:tab/>              Tabulator
#   <text:line-break/>       Zeilenumbruch
#   <text:s text:c="3"/>     3 Leerzeichen (wiederholte Leerzeichen werden in
#                            ODF zusammengefasst)
# Tabellenzellen sind <table:table-cell> mit <text:p> darin.
#
# Gelöschter Text der Änderungsverfolgung (<text:tracked-changes>) wird
# übersprungen.
class OpenDocumentContentReader : ContentReader {

    hidden static [XmlTextRules]$TextRules = [OpenDocumentContentReader]::CreateRules()


    OpenDocumentContentReader() {
        $this.Description = "OpenDocument files (LibreOffice Writer, Calc, Impress, Draw)"
        $this.Extensions = @(
            ".odt", ".ott",
            ".ods", ".ots",
            ".odp", ".otp",
            ".odg"
        )
    }


    [string] ReadContent([System.IO.FileInfo]$file) {
        # Sperrdateien von LibreOffice (".~lock.Bericht.odt#") haben eine
        # andere Endung, aber andere Dateien können diese Endungen trotzdem
        # verwenden.
        if (-not $this.IsZipFile($file)) {
            return ""
        }

        $zip = $this.OpenZip($file)

        try {
            $reader = $this.OpenZipXml($zip, "content.xml")

            if ($null -eq $reader) {
                return ""
            }

            try {
                return [XmlText]::Extract($reader, [OpenDocumentContentReader]::TextRules)
            }
            finally {
                $reader.Dispose()
            }
        }
        finally {
            $zip.Dispose()
        }
    }


    hidden static [XmlTextRules] CreateRules() {
        $rules = [XmlTextRules]::new()

        # Der Text steht direkt in <text:p>/<text:h>/<text:span>, nicht in
        # einem eigenen Element, daher werden alle Textknoten verwendet.
        $rules.ParagraphElements = @("p", "h")
        $rules.TabElements = @("tab")
        $rules.BreakElements = @("line-break")
        $rules.SpaceElements = @("s")
        $rules.SkipElements = @("tracked-changes", "automatic-styles", "font-face-decls", "scripts")

        return $rules
    }
}

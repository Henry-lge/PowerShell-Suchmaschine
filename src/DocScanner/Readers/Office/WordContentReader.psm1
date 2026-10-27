using module "../ContentReader.psm1"
using module "../Shared/XmlText.psm1"
using module "../Shared/OpenXml.psm1"

#requires -Version 7.2


# =============================================================================
# READER FÜR WORD
# =============================================================================

# Liest den Text von Word-Dokumenten ab Office 2007. Die Datei ist ein
# ZIP-Archiv mit XML-Teilen, daher wird kein zusätzliches Tool benötigt.
#
# Wo der Text steht:
#   - Hauptdokument (meist word/document.xml, gefunden über _rels/.rels)
#   - word/footnotes.xml, endnotes.xml, comments.xml
#   - word/header*.xml, footer*.xml
#   Absätze sind <w:p>, der Text steht in <w:t>, <w:tab/> und <w:br/> sind
#   Tabulatoren und Zeilenumbrüche. Gelöschter Text (<w:delText>) und
#   Feldfunktionen (<w:instrText>) stehen nicht in <w:t> und werden daher
#   ignoriert.
#
# Textfelder werden doppelt gespeichert: als moderne Zeichnung (<mc:Choice>)
# und als Ersatz für alte Word-Versionen (<mc:Fallback>). Der Ersatz wird
# übersprungen.
class WordContentReader : ContentReader {

    hidden static [XmlTextRules]$TextRules = [WordContentReader]::CreateRules()


    WordContentReader() {
        $this.Description = "Word documents"
        $this.Extensions = @(".docx", ".docm", ".dotx", ".dotm")
    }


    [string] ReadContent([System.IO.FileInfo]$file) {
        # Sperrdateien ("~$Bericht.docx") sind keine ZIP-Archive.
        if (-not $this.IsZipFile($file)) {
            return ""
        }

        $zip = $this.OpenZip($file)

        try {
            $parts = [System.Collections.Generic.List[string]]::new()
            $parts.Add($this._FindMainDocument($zip))

            foreach ($name in @("word/footnotes.xml", "word/endnotes.xml", "word/comments.xml")) {
                $parts.Add($name)
            }

            foreach ($pattern in @("word/header*.xml", "word/footer*.xml")) {
                foreach ($name in $this.FindZipEntries($zip, $pattern)) {
                    $parts.Add($name)
                }
            }

            $texts = [System.Collections.Generic.List[string]]::new()

            foreach ($partName in $parts) {
                $text = $this._ReadPart($zip, $partName)

                if (-not [string]::IsNullOrWhiteSpace($text)) {
                    $texts.Add($text)
                }
            }

            return $texts -join "`n`n"
        }
        finally {
            $zip.Dispose()
        }
    }


    # Die Beziehungen des Pakets benennen den Hauptteil; "word/document.xml"
    # ist nur der übliche Name.
    hidden [string] _FindMainDocument([System.IO.Compression.ZipArchive]$zip) {
        $relationships = [OpenXmlPackage]::ParseRelationships($this.ReadZipEntry($zip, "_rels/.rels"), "")
        $main = [OpenXmlPackage]::FindByType($relationships, "/officeDocument")

        if ($null -ne $main -and $null -ne $zip.GetEntry($main.Target)) {
            return $main.Target
        }

        return "word/document.xml"
    }


    hidden [string] _ReadPart([System.IO.Compression.ZipArchive]$zip, [string]$partName) {
        $reader = $this.OpenZipXml($zip, $partName)

        if ($null -eq $reader) {
            return ""
        }

        try {
            return [XmlText]::Extract($reader, [WordContentReader]::TextRules)
        }
        finally {
            $reader.Dispose()
        }
    }


    hidden static [XmlTextRules] CreateRules() {
        $rules = [XmlTextRules]::new()
        $rules.TextElements = @("t")
        $rules.ParagraphElements = @("p")
        $rules.TabElements = @("tab")
        $rules.BreakElements = @("br", "cr")
        $rules.SkipElements = @("Fallback", "pPr")

        return $rules
    }
}

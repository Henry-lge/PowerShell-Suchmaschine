using module "../ContentReader.psm1"
using module "../Shared/XmlText.psm1"
using module "../Shared/OpenXml.psm1"

#requires -Version 7.2


# =============================================================================
# READER FÜR POWERPOINT
# =============================================================================

# Liest den Text aller Folien und Sprechernotizen von PowerPoint-Präsentationen
# ab Office 2007. Die Datei ist ein ZIP-Archiv mit XML-Teilen, daher wird kein
# zusätzliches Tool benötigt.
#
# Folienreihenfolge: ppt/presentation.xml listet die Folien in <p:sldIdLst>
# als Beziehungs-IDs (<p:sldId r:id="rId2"/>); ppt/_rels/presentation.xml.rels
# ordnet sie den Dateien zu. Die Dateinamen (slide1.xml, ...) müssen nicht
# zur Reihenfolge passen, z. B. nachdem Folien verschoben wurden.
#
# Die eigenen Beziehungen jeder Folie verweisen auf ihre Notizen
# (notesSlide). Absätze sind <a:p>, der Text steht in <a:t>, <a:br/> ist ein
# Zeilenumbruch.
class PowerPointContentReader : ContentReader {

    hidden static [XmlTextRules]$TextRules = [PowerPointContentReader]::CreateRules()


    PowerPointContentReader() {
        $this.Description = "PowerPoint presentations"
        $this.Extensions = @(".pptx", ".pptm", ".potx", ".ppsx")
    }


    [string] ReadContent([System.IO.FileInfo]$file) {
        if (-not $this.IsZipFile($file)) {
            return ""
        }

        $zip = $this.OpenZip($file)

        try {
            $texts = [System.Collections.Generic.List[string]]::new()

            foreach ($slidePath in $this._GetSlidePaths($zip)) {
                $slideText = $this._ReadPart($zip, $slidePath)

                if (-not [string]::IsNullOrWhiteSpace($slideText)) {
                    $texts.Add($slideText)
                }

                $notesPath = $this._GetNotesPath($zip, $slidePath)

                if (-not [string]::IsNullOrEmpty($notesPath)) {
                    $notesText = $this._ReadPart($zip, $notesPath)

                    if (-not [string]::IsNullOrWhiteSpace($notesText)) {
                        $texts.Add($notesText)
                    }
                }
            }

            return $texts -join "`n`n"
        }
        finally {
            $zip.Dispose()
        }
    }


    # Folienpfade in der Reihenfolge der Präsentation. Lässt sich der Teil der
    # Präsentation nicht lesen, werden die Dateinamen verwendet.
    hidden [string[]] _GetSlidePaths([System.IO.Compression.ZipArchive]$zip) {
        $packageRelationships = [OpenXmlPackage]::ParseRelationships($this.ReadZipEntry($zip, "_rels/.rels"), "")
        $main = [OpenXmlPackage]::FindByType($packageRelationships, "/officeDocument")
        $presentationPath = if ($null -ne $main) { $main.Target } else { "ppt/presentation.xml" }

        $slidePaths = [System.Collections.Generic.List[string]]::new()

        try {
            $presentation = [System.Xml.XmlDocument]::new()
            $presentation.XmlResolver = $null
            $presentation.LoadXml($this.ReadZipEntry($zip, $presentationPath))

            $relationships = [OpenXmlPackage]::ParseRelationships(
                $this.ReadZipEntry($zip, [OpenXmlPackage]::GetRelationshipsPath($presentationPath)),
                $presentationPath
            )

            foreach ($slideId in $presentation.SelectNodes("//*[local-name()='sldIdLst']/*[local-name()='sldId']")) {
                $relationshipId = [OpenXmlPackage]::GetRelationshipAttribute($slideId, "id")
                $relationship = [OpenXmlPackage]::FindById($relationships, $relationshipId)

                if ($null -ne $relationship -and $null -ne $zip.GetEntry($relationship.Target)) {
                    $slidePaths.Add($relationship.Target)
                }
            }
        }
        catch {
            $slidePaths.Clear()
        }

        if ($slidePaths.Count -eq 0) {
            return $this.FindZipEntries($zip, "ppt/slides/slide*.xml")
        }

        return $slidePaths.ToArray()
    }


    hidden [string] _GetNotesPath([System.IO.Compression.ZipArchive]$zip, [string]$slidePath) {
        $relationships = [OpenXmlPackage]::ParseRelationships(
            $this.ReadZipEntry($zip, [OpenXmlPackage]::GetRelationshipsPath($slidePath)),
            $slidePath
        )
        $notes = [OpenXmlPackage]::FindByType($relationships, "/notesSlide")

        if ($null -eq $notes) {
            return ""
        }

        return $notes.Target
    }


    hidden [string] _ReadPart([System.IO.Compression.ZipArchive]$zip, [string]$partName) {
        $reader = $this.OpenZipXml($zip, $partName)

        if ($null -eq $reader) {
            return ""
        }

        try {
            return [XmlText]::Extract($reader, [PowerPointContentReader]::TextRules)
        }
        finally {
            $reader.Dispose()
        }
    }


    hidden static [XmlTextRules] CreateRules() {
        $rules = [XmlTextRules]::new()
        $rules.TextElements = @("t")
        $rules.ParagraphElements = @("p")
        $rules.BreakElements = @("br")

        # Doppelt gespeicherter Inhalt für alte Versionen, siehe
        # WordContentReader.
        $rules.SkipElements = @("Fallback")

        return $rules
    }
}

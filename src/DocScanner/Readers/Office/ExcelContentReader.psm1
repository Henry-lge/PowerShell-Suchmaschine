using module "../ContentReader.psm1"
using module "../Shared/OpenXml.psm1"

#requires -Version 7.4


# =============================================================================
# READER FÜR EXCEL
# =============================================================================

# Liest die Zellwerte aller Blätter von Excel-Arbeitsmappen ab Office 2007.
# Die Datei ist ein ZIP-Archiv mit XML-Teilen, daher wird kein zusätzliches
# Tool benötigt.
#
# Ausgabe: pro Blatt eine Zeile mit dem Blattnamen, dann eine Zeile pro
# Tabellenzeile mit den nicht leeren Zellen, getrennt durch Tabulatoren.
#
# Wo die Daten stehen:
#   - xl/workbook.xml           <sheet name="..." r:id="rId1"/> in Reihenfolge
#   - xl/_rels/workbook.xml.rels ordnet die IDs xl/worksheets/sheetN.xml zu
#   - xl/sharedStrings.xml      alle Texte, <si>-Elemente, die per Index
#                               referenziert werden
#   - Blatt: <row> mit Zellen <c t="typ"><v>wert</v></c>
#       t="s"          Index in die gemeinsamen Texte (Shared Strings)
#       t="inlineStr"  Text direkt in <is><t>
#       t="b"          Wahrheitswert 0/1
#       t="str", "e"   Text-Ergebnis einer Formel, Fehler
#       kein t / "n"   Zahl (auch Datumswerte sind Zahlen, z. B. 45000)
[NoRunspaceAffinity()]
class ExcelContentReader : ContentReader {

    ExcelContentReader() {
        $this.Description = "Excel workbooks"
        $this.Extensions = @(".xlsx", ".xlsm", ".xltx", ".xltm")
    }


    [string] ReadContent([System.IO.FileInfo]$file) {
        if (-not $this.IsZipFile($file)) {
            return ""
        }

        $zip = $this.OpenZip($file)

        try {
            $packageRelationships = [OpenXmlPackage]::ParseRelationships($this.ReadZipEntry($zip, "_rels/.rels"), "")
            $main = [OpenXmlPackage]::FindByType($packageRelationships, "/officeDocument")
            $workbookPath = if ($null -ne $main) { $main.Target } else { "xl/workbook.xml" }

            $workbookRelationships = [OpenXmlPackage]::ParseRelationships(
                $this.ReadZipEntry($zip, [OpenXmlPackage]::GetRelationshipsPath($workbookPath)),
                $workbookPath
            )

            $sharedStringsPart = [OpenXmlPackage]::FindByType($workbookRelationships, "/sharedStrings")
            $sharedStringsPath = if ($null -ne $sharedStringsPart) { $sharedStringsPart.Target } else { "xl/sharedStrings.xml" }
            $sharedStrings = $this._ReadSharedStrings($zip, $sharedStringsPath)

            $output = [System.Collections.Generic.List[string]]::new()

            foreach ($sheet in $this._GetSheets($zip, $workbookPath, $workbookRelationships)) {
                $rows = $this._ReadSheet($zip, $sheet.Path, $sharedStrings)

                if ($rows.Count -gt 0) {
                    $output.Add($sheet.Name)
                    $output.AddRange($rows)
                    $output.Add("")
                }
            }

            return ($output -join "`n").Trim()
        }
        finally {
            $zip.Dispose()
        }
    }


    # Gibt Objekte mit Name und Path in der Reihenfolge der Arbeitsmappe
    # zurück. Lässt sich der Teil der Arbeitsmappe nicht lesen, werden die
    # Dateinamen verwendet.
    hidden [PSCustomObject[]] _GetSheets(
        [System.IO.Compression.ZipArchive]$zip,
        [string]$workbookPath,
        [OpenXmlRelationship[]]$workbookRelationships
    ) {
        $sheets = [System.Collections.Generic.List[PSCustomObject]]::new()

        try {
            $workbook = [System.Xml.XmlDocument]::new()
            $workbook.XmlResolver = $null
            $workbook.LoadXml($this.ReadZipEntry($zip, $workbookPath))

            foreach ($sheetNode in $workbook.SelectNodes("//*[local-name()='sheets']/*[local-name()='sheet']")) {
                $relationshipId = [OpenXmlPackage]::GetRelationshipAttribute($sheetNode, "id")
                $relationship = [OpenXmlPackage]::FindById($workbookRelationships, $relationshipId)

                # Diagrammblätter haben keine Zellen; nur Tabellenblätter
                # werden gelesen.
                if (
                    $null -ne $relationship -and
                    $relationship.Type.EndsWith("/worksheet") -and
                    $null -ne $zip.GetEntry($relationship.Target)
                ) {
                    $sheets.Add([PSCustomObject]@{
                        Name = $sheetNode.GetAttribute("name")
                        Path = $relationship.Target
                    })
                }
            }
        }
        catch {
            $sheets.Clear()
        }

        if ($sheets.Count -eq 0) {
            foreach ($path in $this.FindZipEntries($zip, "xl/worksheets/sheet*.xml")) {
                $sheets.Add([PSCustomObject]@{
                    Name = [System.IO.Path]::GetFileNameWithoutExtension($path)
                    Path = $path
                })
            }
        }

        return $sheets.ToArray()
    }


    # Jedes <si> ist ein Text. Er besteht aus allen <t> zusammen, außer den
    # Lesehilfen (<rPh>) für asiatische Sprachen.
    hidden [string[]] _ReadSharedStrings([System.IO.Compression.ZipArchive]$zip, [string]$path) {
        $strings = [System.Collections.Generic.List[string]]::new()
        $reader = $this.OpenZipXml($zip, $path)

        if ($null -eq $reader) {
            return $strings.ToArray()
        }

        try {
            $builder = [System.Text.StringBuilder]::new()
            $inText = $false
            $phoneticDepth = 0

            # Diese Schleife läuft für jeden XML-Knoten. Deshalb if/elseif
            # mit vorab geholten Knotentypen statt switch: Das ist in
            # PowerShell deutlich schneller.
            $elementType = [System.Xml.XmlNodeType]::Element
            $endElementType = [System.Xml.XmlNodeType]::EndElement

            while ($reader.Read()) {
                $nodeType = $reader.NodeType

                if ($nodeType -eq $elementType) {
                    $name = $reader.LocalName

                    if ($name -ceq "si") {
                        [void]$builder.Clear()
                    }
                    elseif ($name -ceq "t") {
                        $inText = -not $reader.IsEmptyElement
                    }
                    elseif ($name -ceq "rPh" -and -not $reader.IsEmptyElement) {
                        $phoneticDepth++
                    }
                }
                elseif ($nodeType -eq $endElementType) {
                    $name = $reader.LocalName

                    if ($name -ceq "t") {
                        $inText = $false
                    }
                    elseif ($name -ceq "si") {
                        $strings.Add($builder.ToString())
                    }
                    elseif ($name -ceq "rPh") {
                        $phoneticDepth--
                    }
                }
                elseif ($inText -and $phoneticDepth -eq 0) {
                    # Text, SignificantWhitespace oder Whitespace; andere
                    # Knoten kommen innerhalb von <t> nicht vor.
                    [void]$builder.Append($reader.Value)
                }
            }
        }
        finally {
            $reader.Dispose()
        }

        return $strings.ToArray()
    }


    # Gibt pro nicht leerer Tabellenzeile eine durch Tabulatoren getrennte
    # Zeile zurück.
    hidden [string[]] _ReadSheet(
        [System.IO.Compression.ZipArchive]$zip,
        [string]$path,
        [string[]]$sharedStrings
    ) {
        $lines = [System.Collections.Generic.List[string]]::new()
        $reader = $this.OpenZipXml($zip, $path)

        if ($null -eq $reader) {
            return $lines.ToArray()
        }

        try {
            $cells = [System.Collections.Generic.List[string]]::new()
            $value = [System.Text.StringBuilder]::new()
            $cellType = ""
            $inValue = $false

            # Wie in _ReadSharedStrings: if/elseif statt switch, weil diese
            # Schleife für jeden Knoten jeder Zelle läuft.
            $elementType = [System.Xml.XmlNodeType]::Element
            $endElementType = [System.Xml.XmlNodeType]::EndElement

            while ($reader.Read()) {
                $nodeType = $reader.NodeType

                if ($nodeType -eq $elementType) {
                    $name = $reader.LocalName

                    # <v> enthält den Wert, <t> den Text von Inline-Texten.
                    # Formeln (<f>) werden nicht gelesen.
                    if ($name -ceq "v" -or $name -ceq "t") {
                        $inValue = -not $reader.IsEmptyElement
                    }
                    elseif ($name -ceq "c") {
                        $cellType = $reader.GetAttribute("t")
                        [void]$value.Clear()
                    }
                    elseif ($name -ceq "row") {
                        $cells.Clear()
                    }
                }
                elseif ($nodeType -eq $endElementType) {
                    $name = $reader.LocalName

                    if ($name -ceq "v" -or $name -ceq "t") {
                        $inValue = $false
                    }
                    elseif ($name -ceq "c") {
                        if ($value.Length -gt 0) {
                            $cellText = [ExcelContentReader]::FormatCell($cellType, $value.ToString(), $sharedStrings)

                            if (-not [string]::IsNullOrWhiteSpace($cellText)) {
                                $cells.Add($cellText.Trim())
                            }
                        }
                    }
                    elseif ($name -ceq "row" -and $cells.Count -gt 0) {
                        $lines.Add([string]::Join("`t", $cells))
                    }
                }
                elseif ($inValue) {
                    [void]$value.Append($reader.Value)
                }
            }
        }
        finally {
            $reader.Dispose()
        }

        return $lines.ToArray()
    }


    static [string] FormatCell([string]$cellType, [string]$rawValue, [string[]]$sharedStrings) {
        switch ($cellType) {
            "s" {
                $index = 0

                if ([int]::TryParse($rawValue, [ref]$index) -and $index -ge 0 -and $index -lt $sharedStrings.Length) {
                    return $sharedStrings[$index]
                }

                return ""
            }
            "b" {
                if ($rawValue -eq "1") { return "TRUE" }
                return "FALSE"
            }
        }

        # Zahlen, Text-Ergebnisse von Formeln, Inline-Texte und Fehler so,
        # wie sie gespeichert sind.
        return $rawValue
    }
}

using module "../ContentReader.psm1"
using module "../Shared/OpenXml.psm1"

#requires -Version 7.2


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

            while ($reader.Read()) {
                switch ($reader.NodeType) {
                    ([System.Xml.XmlNodeType]::Element) {
                        switch ($reader.LocalName) {
                            "si" { [void]$builder.Clear() }
                            "rPh" { if (-not $reader.IsEmptyElement) { $phoneticDepth++ } }
                            "t" { $inText = -not $reader.IsEmptyElement }
                        }
                    }
                    ([System.Xml.XmlNodeType]::EndElement) {
                        switch ($reader.LocalName) {
                            "si" { $strings.Add($builder.ToString()) }
                            "rPh" { $phoneticDepth-- }
                            "t" { $inText = $false }
                        }
                    }
                    { $_ -in [System.Xml.XmlNodeType]::Text, [System.Xml.XmlNodeType]::SignificantWhitespace, [System.Xml.XmlNodeType]::Whitespace } {
                        if ($inText -and $phoneticDepth -eq 0) {
                            [void]$builder.Append($reader.Value)
                        }
                    }
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

            while ($reader.Read()) {
                switch ($reader.NodeType) {
                    ([System.Xml.XmlNodeType]::Element) {
                        switch ($reader.LocalName) {
                            "row" { $cells.Clear() }
                            "c" {
                                $cellType = "$($reader.GetAttribute('t'))"
                                [void]$value.Clear()
                            }
                            # <v> enthält den Wert, <t> den Text von
                            # Inline-Texten. Formeln (<f>) werden nicht gelesen.
                            "v" { $inValue = -not $reader.IsEmptyElement }
                            "t" { $inValue = -not $reader.IsEmptyElement }
                        }
                    }
                    ([System.Xml.XmlNodeType]::EndElement) {
                        switch ($reader.LocalName) {
                            "v" { $inValue = $false }
                            "t" { $inValue = $false }
                            "c" {
                                $cellText = [ExcelContentReader]::FormatCell($cellType, $value.ToString(), $sharedStrings)

                                if (-not [string]::IsNullOrWhiteSpace($cellText)) {
                                    $cells.Add($cellText.Trim())
                                }
                            }
                            "row" {
                                if ($cells.Count -gt 0) {
                                    $lines.Add($cells -join "`t")
                                }
                            }
                        }
                    }
                    { $_ -in [System.Xml.XmlNodeType]::Text, [System.Xml.XmlNodeType]::SignificantWhitespace, [System.Xml.XmlNodeType]::Whitespace } {
                        if ($inValue) {
                            [void]$value.Append($reader.Value)
                        }
                    }
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

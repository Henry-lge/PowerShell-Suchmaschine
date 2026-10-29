#requires -Version 7.2


# =============================================================================
# TEXT AUS XML AUSLESEN
# =============================================================================

# Die meisten Office-Formate speichern Text in XML. Die Formate unterscheiden
# sich nur in den Elementnamen, deshalb wird ein einziger Extraktor pro Format
# mit Regeln eingestellt. Alle Namen sind lokale Namen ohne Präfix ("t",
# nicht "w:t").
class XmlTextRules {

    # Nur Text innerhalb dieser Elemente wird verwendet. Leer: alle Textknoten.
    [string[]]$TextElements = @()

    # Nach dem Ende dieser Elemente wird ein Zeilenumbruch eingefügt.
    [string[]]$ParagraphElements = @()

    # Diese Elemente stehen für ein Tabulatorzeichen.
    [string[]]$TabElements = @()

    # Diese Elemente stehen für einen Zeilenumbruch.
    [string[]]$BreakElements = @()

    # Diese Elemente stehen für Leerzeichen; die Anzahl steht im Attribut "c"
    # (OpenDocument <text:s text:c="3"/>), standardmäßig 1.
    [string[]]$SpaceElements = @()

    # Der ganze Teilbaum dieser Elemente wird ignoriert (z. B. gelöschter Text
    # oder doppelt gespeicherter Ersatzinhalt).
    [string[]]$SkipElements = @()
}


class XmlText {

    # Liest den XML-Stream bis zum Ende und gibt den Text zurück. Zeilen
    # werden gekürzt, zwischen Absätzen bleibt höchstens eine leere Zeile.
    static [string] Extract([System.Xml.XmlReader]$reader, [XmlTextRules]$rules) {
        $textNames = [XmlText]::ToSet($rules.TextElements)
        $paragraphNames = [XmlText]::ToSet($rules.ParagraphElements)
        $tabNames = [XmlText]::ToSet($rules.TabElements)
        $breakNames = [XmlText]::ToSet($rules.BreakElements)
        $spaceNames = [XmlText]::ToSet($rules.SpaceElements)
        $skipNames = [XmlText]::ToSet($rules.SkipElements)

        $allText = $textNames.Count -eq 0
        $textDepth = 0
        $builder = [System.Text.StringBuilder]::new()

        [void]$reader.MoveToContent()

        while (-not $reader.EOF) {
            $nodeType = $reader.NodeType

            if ($nodeType -eq [System.Xml.XmlNodeType]::Element) {
                $name = $reader.LocalName

                if ($skipNames.Contains($name)) {
                    # Skip() springt hinter das Ende des Elements.
                    $reader.Skip()
                    continue
                }

                if ($tabNames.Contains($name)) {
                    [void]$builder.Append("`t")
                }
                elseif ($breakNames.Contains($name)) {
                    [void]$builder.Append("`n")
                }
                elseif ($spaceNames.Contains($name)) {
                    $count = 1
                    $countText = $reader.GetAttribute("c", $reader.NamespaceURI)

                    if ([string]::IsNullOrEmpty($countText)) {
                        $countText = $reader.GetAttribute("c")
                    }

                    if (-not [string]::IsNullOrEmpty($countText)) {
                        [void][int]::TryParse($countText, [ref]$count)
                    }

                    [void]$builder.Append([char]" ", [Math]::Max(1, [Math]::Min($count, 1000)))
                }

                if ($reader.IsEmptyElement) {
                    if ($paragraphNames.Contains($name)) {
                        [void]$builder.Append("`n")
                    }
                }
                elseif ($textNames.Contains($name)) {
                    $textDepth++
                }
            }
            elseif ($nodeType -eq [System.Xml.XmlNodeType]::EndElement) {
                $name = $reader.LocalName

                if ($textNames.Contains($name)) {
                    $textDepth--
                }

                if ($paragraphNames.Contains($name)) {
                    [void]$builder.Append("`n")
                }
            }
            elseif (
                $nodeType -eq [System.Xml.XmlNodeType]::Text -or
                $nodeType -eq [System.Xml.XmlNodeType]::CDATA -or
                $nodeType -eq [System.Xml.XmlNodeType]::SignificantWhitespace
            ) {
                if ($allText -or $textDepth -gt 0) {
                    [void]$builder.Append($reader.Value)
                }
            }

            [void]$reader.Read()
        }

        return [XmlText]::CleanUp($builder.ToString())
    }


    # Kürzt jede Zeile und behält höchstens eine leere Zeile hintereinander.
    static [string] CleanUp([string]$text) {
        $result = [regex]::Replace($text, "[ \t]*\r?\n[ \t]*", "`n")
        $result = [regex]::Replace($result, "\n{3,}", "`n`n")

        return $result.Trim()
    }


    hidden static [System.Collections.Generic.HashSet[string]] ToSet([string[]]$names) {
        $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

        foreach ($name in $names) {
            if (-not [string]::IsNullOrEmpty($name)) {
                [void]$set.Add($name)
            }
        }

        return $set
    }
}

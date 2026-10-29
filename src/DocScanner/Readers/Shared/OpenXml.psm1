#requires -Version 7.2


# =============================================================================
# OPEN-XML-PAKETE (docx, xlsx, pptx)
# =============================================================================

# Word-, Excel- und PowerPoint-Dateien sind ZIP-Archive ("Pakete") mit
# XML-"Teilen". Teile verweisen über Beziehungsdateien aufeinander: Der Teil
# "ppt/presentation.xml" hat seine Verweise in
# "ppt/_rels/presentation.xml.rels", z. B.
#   <Relationship Id="rId2" Type=".../slide" Target="slides/slide1.xml"/>
# Wer den Beziehungen folgt, erhält die echte Reihenfolge der Folien und
# Blätter, auch wenn ein Programm die Teile anders benannt hat.


class OpenXmlRelationship {
    [string]$Id

    # Die Typ-URL, z. B. ".../relationships/slide". Mit EndsWith() vergleichen.
    [string]$Type

    # Pfad des Ziels innerhalb des ZIP, bereits aufgelöst, z. B.
    # "ppt/slides/slide1.xml".
    [string]$Target
}


class OpenXmlPackage {

    # "ppt/presentation.xml" -> "ppt/_rels/presentation.xml.rels".
    # Das Paket selbst ("") hat seine Beziehungen in "_rels/.rels".
    static [string] GetRelationshipsPath([string]$partPath) {
        $lastSlash = $partPath.LastIndexOf("/")
        $folder = if ($lastSlash -ge 0) { $partPath.Substring(0, $lastSlash + 1) } else { "" }
        $fileName = $partPath.Substring($lastSlash + 1)

        return "${folder}_rels/$fileName.rels"
    }


    # Liest das XML einer .rels-Datei. Externe Ziele (Weblinks) werden
    # übersprungen. Bei fehlenden oder defekten Dateien wird eine leere Liste
    # zurückgegeben.
    static [OpenXmlRelationship[]] ParseRelationships([string]$relationshipsXml, [string]$partPath) {
        $relationships = [System.Collections.Generic.List[OpenXmlRelationship]]::new()

        if ([string]::IsNullOrWhiteSpace($relationshipsXml)) {
            return $relationships.ToArray()
        }

        try {
            $document = [System.Xml.XmlDocument]::new()
            $document.XmlResolver = $null
            $document.LoadXml($relationshipsXml)
        }
        catch {
            return $relationships.ToArray()
        }

        $lastSlash = $partPath.LastIndexOf("/")
        $baseFolder = if ($lastSlash -ge 0) { $partPath.Substring(0, $lastSlash + 1) } else { "" }

        foreach ($node in $document.SelectNodes("//*[local-name()='Relationship']")) {
            if ($node.GetAttribute("TargetMode") -eq "External") {
                continue
            }

            $relationship = [OpenXmlRelationship]::new()
            $relationship.Id = $node.GetAttribute("Id")
            $relationship.Type = $node.GetAttribute("Type")
            $relationship.Target = [OpenXmlPackage]::ResolvePath($baseFolder, $node.GetAttribute("Target"))
            $relationships.Add($relationship)
        }

        return $relationships.ToArray()
    }


    # Erste Beziehung, deren Typ mit dem angegebenen Namen endet (z. B.
    # "/officeDocument", "/sharedStrings"), oder $null.
    static [OpenXmlRelationship] FindByType([OpenXmlRelationship[]]$relationships, [string]$typeSuffix) {
        foreach ($relationship in $relationships) {
            if ($relationship.Type.EndsWith($typeSuffix, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $relationship
            }
        }

        return $null
    }


    static [OpenXmlRelationship] FindById([OpenXmlRelationship[]]$relationships, [string]$id) {
        foreach ($relationship in $relationships) {
            if ($relationship.Id -eq $id) {
                return $relationship
            }
        }

        return $null
    }


    # Wert eines Beziehungsattributs wie r:id oder r:embed. Der Namensraum
    # unterscheidet sich zwischen normalen und "strikten" Dateien, deshalb
    # wird jedes Attribut mit diesem lokalen Namen und einem Namensraum
    # akzeptiert.
    static [string] GetRelationshipAttribute([System.Xml.XmlElement]$element, [string]$localName) {
        foreach ($attribute in $element.Attributes) {
            if ($attribute.LocalName -eq $localName -and -not [string]::IsNullOrEmpty($attribute.NamespaceURI)) {
                return $attribute.Value
            }
        }

        return ""
    }


    # Setzt einen Ordner und ein Ziel wie "../media/a b.png" oder
    # "/xl/worksheets/sheet1.xml" zu einem ZIP-Eintragsnamen zusammen.
    static [string] ResolvePath([string]$baseFolder, [string]$target) {
        if ([string]::IsNullOrEmpty($target)) {
            return ""
        }

        $path = [System.Uri]::UnescapeDataString($target.Split("#")[0])

        # Ein führender Schrägstrich bedeutet: relativ zur Wurzel des Pakets.
        if ($path.StartsWith("/")) {
            $path = $path.TrimStart("/")
        }
        else {
            $path = $baseFolder + $path
        }

        $segments = [System.Collections.Generic.List[string]]::new()

        foreach ($segment in $path.Split("/")) {
            if ($segment -eq "..") {
                if ($segments.Count -gt 0) {
                    $segments.RemoveAt($segments.Count - 1)
                }
            }
            elseif ($segment -ne "." -and $segment -ne "") {
                $segments.Add($segment)
            }
        }

        return $segments -join "/"
    }
}

#requires -Version 7.4


# =============================================================================
# METADATEN AUS BILDDATEIEN
# =============================================================================

# Liest durchsuchbare Texte aus den Metadaten von Bildern, ohne die Pixel zu
# dekodieren und ohne externe Tools:
#
#   - Exif (JPEG, TIFF, PNG, WebP, HEIC): Beschreibung, Kamera, Künstler,
#     Copyright, Aufnahmedatum, Kommentar und die Windows-Felder Titel,
#     Betreff, Stichwörter, Autor und Kommentar ("XP...").
#   - XMP (alle Formate): Titel, Beschreibung, Stichwörter, Ersteller, Ort
#     und abgebildete Personen, wie sie Lightroom, Fotos, Bridge oder digiKam
#     schreiben.
#   - PNG-Textblöcke (tEXt, zTXt, iTXt): Title, Author, Description, ...
#   - JPEG-Kommentare (COM).
#
# Jeder Wert kommt als eigene Zeile "Bezeichnung: Wert" zurück, doppelte
# Werte nur einmal.
[NoRunspaceAffinity()]
class ImageMetadata {

    # Exif-Tags mit Text, die übernommen werden: Tag -> Bezeichnung.
    hidden static [hashtable]$TextTags = @{
        0x010E = "Description"
        0x010F = "Camera make"
        0x0110 = "Camera model"
        0x013B = "Artist"
        0x8298 = "Copyright"
        0x0132 = "Modified"
        0x9003 = "Taken"
        0xA434 = "Lens"
        0x9286 = "Comment"
        0x9C9B = "Title"
        0x9C9C = "Comment"
        0x9C9D = "Author"
        0x9C9E = "Keywords"
        0x9C9F = "Subject"
    }

    # XMP-Elemente (lokale Namen) -> Bezeichnung. Mit Beachtung der
    # Groß-/Kleinschreibung, weil "description" (dc) ein Wert ist,
    # "Description" (rdf) dagegen der Container aller Werte.
    hidden static [System.Collections.Generic.Dictionary[string, string]]$XmpFields = [ImageMetadata]::CreateXmpFields()

    hidden static [System.Collections.Generic.Dictionary[string, string]] CreateXmpFields() {
        $fields = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
        $fields["title"] = "Title"
        $fields["description"] = "Description"
        $fields["subject"] = "Keywords"
        $fields["hierarchicalSubject"] = "Keywords"
        $fields["creator"] = "Author"
        $fields["rights"] = "Copyright"
        $fields["Headline"] = "Headline"
        $fields["City"] = "City"
        $fields["State"] = "State"
        $fields["Country"] = "Country"
        $fields["Location"] = "Location"
        $fields["Sublocation"] = "Location"
        $fields["PersonInImage"] = "Person"
        $fields["Label"] = "Label"

        return $fields
    }


    # PNG-Textblöcke, die übernommen werden. Andere Schlüssel enthalten meist
    # technische Daten (Software, Farbprofile als Hex-Text).
    hidden static [string[]]$PngKeywords = @(
        "Title", "Author", "Description", "Copyright",
        "Comment", "Source", "Disclaimer", "Warning"
    )


    # Gibt die Metadaten als Text zurück; leer, wenn keine gefunden wurden.
    static [string] Read([byte[]]$bytes) {
        $lines = [System.Collections.Generic.List[string]]::new()

        if ($bytes.Length -lt 12) {
            return ""
        }

        if ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8) {
            [ImageMetadata]::ReadJpeg($bytes, $lines)
        }
        elseif ($bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50 -and $bytes[2] -eq 0x4E -and $bytes[3] -eq 0x47) {
            [ImageMetadata]::ReadPng($bytes, $lines)
        }
        elseif (
            ($bytes[0] -eq 0x49 -and $bytes[1] -eq 0x49 -and $bytes[2] -eq 0x2A) -or
            ($bytes[0] -eq 0x4D -and $bytes[1] -eq 0x4D -and $bytes[3] -eq 0x2A)
        ) {
            # Eine TIFF-Datei ist selbst ein Exif-Block.
            [ImageMetadata]::ReadExif($bytes, 0, $bytes.Length, $lines)
        }
        elseif ([System.Text.Encoding]::ASCII.GetString($bytes, 0, 4) -eq "RIFF" -and [System.Text.Encoding]::ASCII.GetString($bytes, 8, 4) -eq "WEBP") {
            [ImageMetadata]::ReadWebP($bytes, $lines)
        }
        else {
            # HEIC und andere: Exif-Block über seine Kennung suchen.
            [ImageMetadata]::FindExif($bytes, $lines)
        }

        # XMP ist ein XML-Paket, das in fast jedem Format unverschlüsselt im
        # Dateiinhalt steht; es wird deshalb für alle Formate gesucht.
        [ImageMetadata]::FindXmp($bytes, $lines)

        return [ImageMetadata]::Distinct($lines)
    }


    # =============================================================================
    # FORMATE
    # =============================================================================

    # JPEG besteht aus Segmenten "FF xx Länge(2, big-endian) Daten". Exif und
    # XMP stehen in APP1 (FFE1), Kommentare in COM (FFFE). Ab dem Bildinhalt
    # (SOS, FFDA) folgen keine Metadaten mehr.
    hidden static [void] ReadJpeg([byte[]]$bytes, [System.Collections.Generic.List[string]]$lines) {
        $position = 2

        while ($position + 4 -le $bytes.Length) {
            if ($bytes[$position] -ne 0xFF) {
                return
            }

            $marker = $bytes[$position + 1]

            # Füllbytes und Marker ohne Länge.
            if ($marker -eq 0xFF) {
                $position++
                continue
            }

            if ($marker -eq 0xD8 -or ($marker -ge 0xD0 -and $marker -le 0xD7) -or $marker -eq 0x01) {
                $position += 2
                continue
            }

            if ($marker -eq 0xDA -or $marker -eq 0xD9) {
                return
            }

            $length = ([int]$bytes[$position + 2] -shl 8) + $bytes[$position + 3]
            $dataStart = $position + 4
            $dataLength = $length - 2

            if ($length -lt 2 -or $dataStart + $dataLength -gt $bytes.Length) {
                return
            }

            if (
                $marker -eq 0xE1 -and
                $dataLength -gt 6 -and
                [System.Text.Encoding]::ASCII.GetString($bytes, $dataStart, 6) -eq "Exif`0`0"
            ) {
                [ImageMetadata]::ReadExif($bytes, $dataStart + 6, $dataLength - 6, $lines)
            }
            elseif ($marker -eq 0xFE) {
                [ImageMetadata]::AddLine($lines, "Comment", [ImageMetadata]::DecodeText($bytes, $dataStart, $dataLength))
            }

            $position = $dataStart + $dataLength
        }
    }


    # PNG besteht aus Blöcken "Länge(4) Typ(4) Daten CRC(4)".
    hidden static [void] ReadPng([byte[]]$bytes, [System.Collections.Generic.List[string]]$lines) {
        $position = 8

        while ($position + 12 -le $bytes.Length) {
            $length = [ImageMetadata]::ReadUInt32($bytes, $position, $false)
            $type = [System.Text.Encoding]::ASCII.GetString($bytes, $position + 4, 4)
            $dataStart = $position + 8

            if ($length -lt 0 -or $dataStart + $length -gt $bytes.Length) {
                return
            }

            switch ($type) {
                "tEXt" { [ImageMetadata]::ReadPngText($bytes, $dataStart, $length, $false, $lines) }
                "zTXt" { [ImageMetadata]::ReadPngText($bytes, $dataStart, $length, $true, $lines) }
                "iTXt" { [ImageMetadata]::ReadPngInternationalText($bytes, $dataStart, $length, $lines) }
                "eXIf" { [ImageMetadata]::ReadExif($bytes, $dataStart, $length, $lines) }
                "IEND" { return }
            }

            $position = $dataStart + $length + 4
        }
    }


    # tEXt: "Schlüssel\0Text" (Latin-1). zTXt: "Schlüssel\0" Methode(1),
    # danach zlib-komprimierter Text.
    hidden static [void] ReadPngText(
        [byte[]]$bytes,
        [int]$start,
        [int]$length,
        [bool]$compressed,
        [System.Collections.Generic.List[string]]$lines
    ) {
        $separator = [Array]::IndexOf($bytes, [byte]0, $start, $length)

        if ($separator -lt 0) {
            return
        }

        $keyword = [System.Text.Encoding]::Latin1.GetString($bytes, $start, $separator - $start)

        if ($keyword -notin [ImageMetadata]::PngKeywords) {
            return
        }

        $textStart = $separator + 1
        $textLength = $start + $length - $textStart

        if ($compressed) {
            $textStart++
            $textLength--
            $text = [System.Text.Encoding]::Latin1.GetString([ImageMetadata]::Inflate($bytes, $textStart, $textLength))
        }
        else {
            $text = [System.Text.Encoding]::Latin1.GetString($bytes, $textStart, $textLength)
        }

        [ImageMetadata]::AddLine($lines, $keyword, $text)
    }


    # iTXt: "Schlüssel\0" Komprimiert(1) Methode(1) "Sprache\0"
    # "übersetzter Schlüssel\0" Text (UTF-8, eventuell zlib). XMP steht hier
    # unter "XML:com.adobe.xmp" und wird von FindXmp gefunden, wenn es nicht
    # komprimiert ist; komprimiertes XMP wird direkt ausgewertet.
    hidden static [void] ReadPngInternationalText(
        [byte[]]$bytes,
        [int]$start,
        [int]$length,
        [System.Collections.Generic.List[string]]$lines
    ) {
        $end = $start + $length
        $keywordEnd = [Array]::IndexOf($bytes, [byte]0, $start, $length)

        if ($keywordEnd -lt 0 -or $keywordEnd + 3 -ge $end) {
            return
        }

        $keyword = [System.Text.Encoding]::Latin1.GetString($bytes, $start, $keywordEnd - $start)
        $isCompressed = $bytes[$keywordEnd + 1] -eq 1
        $languageEnd = [Array]::IndexOf($bytes, [byte]0, $keywordEnd + 3, $end - $keywordEnd - 3)

        if ($languageEnd -lt 0) {
            return
        }

        $translatedEnd = [Array]::IndexOf($bytes, [byte]0, $languageEnd + 1, $end - $languageEnd - 1)

        if ($translatedEnd -lt 0) {
            return
        }

        $isXmp = $keyword -eq "XML:com.adobe.xmp"

        if (-not $isXmp -and $keyword -notin [ImageMetadata]::PngKeywords) {
            return
        }

        # Unkomprimiertes XMP findet FindXmp im Dateiinhalt.
        if ($isXmp -and -not $isCompressed) {
            return
        }

        $textStart = $translatedEnd + 1

        if ($isCompressed) {
            $text = [System.Text.Encoding]::UTF8.GetString(
                [ImageMetadata]::Inflate($bytes, $textStart, $end - $textStart)
            )
        }
        else {
            $text = [System.Text.Encoding]::UTF8.GetString($bytes, $textStart, $end - $textStart)
        }

        if ($isXmp) {
            [ImageMetadata]::ReadXmp($text, $lines)
        }
        else {
            [ImageMetadata]::AddLine($lines, $keyword, $text)
        }
    }


    # WebP ist ein RIFF-Container mit Blöcken "Typ(4) Länge(4, little-endian)
    # Daten", auf gerade Länge aufgefüllt. Exif steht im Block "EXIF".
    hidden static [void] ReadWebP([byte[]]$bytes, [System.Collections.Generic.List[string]]$lines) {
        $position = 12

        while ($position + 8 -le $bytes.Length) {
            $type = [System.Text.Encoding]::ASCII.GetString($bytes, $position, 4)
            $length = [ImageMetadata]::ReadUInt32($bytes, $position + 4, $true)
            $dataStart = $position + 8

            if ($length -lt 0 -or $dataStart + $length -gt $bytes.Length) {
                return
            }

            if ($type -eq "EXIF") {
                # Manche Programme schreiben die JPEG-Kennung "Exif\0\0" davor.
                $offset = $dataStart
                $exifLength = $length

                if ($length -gt 6 -and [System.Text.Encoding]::ASCII.GetString($bytes, $dataStart, 6) -eq "Exif`0`0") {
                    $offset += 6
                    $exifLength -= 6
                }

                [ImageMetadata]::ReadExif($bytes, $offset, $exifLength, $lines)
            }

            $position = $dataStart + $length + ($length % 2)
        }
    }


    # Für Formate ohne eigenen Parser (HEIC/HEIF): Der Exif-Block beginnt
    # dort nach der Kennung "Exif\0\0" mit dem TIFF-Kopf "II*\0" oder "MM\0*".
    hidden static [void] FindExif([byte[]]$bytes, [System.Collections.Generic.List[string]]$lines) {
        $text = [System.Text.Encoding]::Latin1.GetString($bytes)
        $index = $text.IndexOf("Exif`0`0", [System.StringComparison]::Ordinal)

        while ($index -ge 0 -and $index + 14 -le $bytes.Length) {
            $tiff = $index + 6
            $header = $text.Substring($tiff, 4)

            if ($header -eq "II*`0" -or $header -eq "MM`0*") {
                [ImageMetadata]::ReadExif($bytes, $tiff, $bytes.Length - $tiff, $lines)
                return
            }

            $index = $text.IndexOf("Exif`0`0", $index + 1, [System.StringComparison]::Ordinal)
        }
    }


    # =============================================================================
    # EXIF
    # =============================================================================

    # Ein Exif-Block ist eine kleine TIFF-Struktur: Kopf mit Byte-Reihenfolge
    # ("II" little-endian, "MM" big-endian) und dem Offset des ersten
    # Verzeichnisses (IFD0). Jeder Eintrag hat 12 Bytes: Tag(2) Typ(2)
    # Anzahl(4) Wert oder Offset(4). Alle Offsets zählen ab dem Kopf. Das
    # Exif-Unterverzeichnis (Tag 0x8769) enthält Aufnahmedatum und Kommentar.
    hidden static [void] ReadExif(
        [byte[]]$bytes,
        [int]$start,
        [int]$length,
        [System.Collections.Generic.List[string]]$lines
    ) {
        if ($length -lt 8 -or $start + $length -gt $bytes.Length) {
            return
        }

        $littleEndian = $bytes[$start] -eq 0x49

        if (-not $littleEndian -and $bytes[$start] -ne 0x4D) {
            return
        }

        $firstIfd = [ImageMetadata]::ReadUInt32($bytes, $start + 4, $littleEndian)
        $exifIfd = [ImageMetadata]::ReadIfd($bytes, $start, $length, $firstIfd, $littleEndian, $lines)

        if ($exifIfd -gt 0) {
            [void][ImageMetadata]::ReadIfd($bytes, $start, $length, $exifIfd, $littleEndian, $lines)
        }
    }


    # Liest die Text-Tags eines Verzeichnisses und gibt den Offset des
    # Exif-Unterverzeichnisses zurück (0, wenn keines).
    hidden static [long] ReadIfd(
        [byte[]]$bytes,
        [int]$start,
        [int]$length,
        [long]$offset,
        [bool]$littleEndian,
        [System.Collections.Generic.List[string]]$lines
    ) {
        $exifIfd = 0

        if ($offset -lt 8 -or $offset + 2 -gt $length) {
            return 0
        }

        $count = [ImageMetadata]::ReadUInt16($bytes, $start + $offset, $littleEndian)

        # Unplausibel viele Einträge: beschädigter Block.
        if ($count -gt 1000) {
            return 0
        }

        for ($i = 0; $i -lt $count; $i++) {
            $entry = $start + $offset + 2 + ($i * 12)

            if ($entry + 12 -gt $start + $length) {
                break
            }

            $tag = [ImageMetadata]::ReadUInt16($bytes, $entry, $littleEndian)
            $type = [ImageMetadata]::ReadUInt16($bytes, $entry + 2, $littleEndian)
            $valueCount = [ImageMetadata]::ReadUInt32($bytes, $entry + 4, $littleEndian)

            if ($tag -eq 0x8769) {
                $exifIfd = [ImageMetadata]::ReadUInt32($bytes, $entry + 8, $littleEndian)
                continue
            }

            if (-not [ImageMetadata]::TextTags.ContainsKey([int]$tag)) {
                continue
            }

            # Nur Text (2 = ASCII) und Bytefolgen (1 = BYTE, 7 = UNDEFINED)
            # enthalten lesbaren Text.
            if ($type -notin 1, 2, 7 -or $valueCount -le 0 -or $valueCount -gt 65535) {
                continue
            }

            # Bis 4 Bytes steht der Wert direkt im Eintrag, sonst an einem
            # Offset.
            $valueStart = if ($valueCount -le 4) {
                $entry + 8
            }
            else {
                $start + [ImageMetadata]::ReadUInt32($bytes, $entry + 8, $littleEndian)
            }

            if ($valueStart -lt $start -or $valueStart + $valueCount -gt $start + $length) {
                continue
            }

            $text = [ImageMetadata]::DecodeExifValue($bytes, $valueStart, [int]$valueCount, [int]$tag, $littleEndian)
            [ImageMetadata]::AddLine($lines, [ImageMetadata]::TextTags[[int]$tag], $text)
        }

        return $exifIfd
    }


    hidden static [string] DecodeExifValue(
        [byte[]]$bytes,
        [int]$start,
        [int]$count,
        [int]$tag,
        [bool]$littleEndian
    ) {
        # Windows-Felder (XPTitle, XPKeywords, ...) sind immer UTF-16LE.
        if ($tag -ge 0x9C9B -and $tag -le 0x9C9F) {
            return [System.Text.Encoding]::Unicode.GetString($bytes, $start, $count - ($count % 2)).TrimEnd([char]0)
        }

        # UserComment: 8 Bytes Zeichensatz ("ASCII", "UNICODE", "JIS"), dann
        # der Text. UNICODE ist UTF-16 in der Byte-Reihenfolge des Blocks.
        if ($tag -eq 0x9286) {
            if ($count -le 8) {
                return ""
            }

            $charset = [System.Text.Encoding]::ASCII.GetString($bytes, $start, 8).TrimEnd([char]0, [char]" ")

            if ($charset -eq "UNICODE") {
                $encoding = if ($littleEndian) { [System.Text.Encoding]::Unicode } else { [System.Text.Encoding]::BigEndianUnicode }
                return $encoding.GetString($bytes, $start + 8, ($count - 8) - (($count - 8) % 2)).TrimEnd([char]0)
            }

            return [ImageMetadata]::DecodeText($bytes, $start + 8, $count - 8)
        }

        return [ImageMetadata]::DecodeText($bytes, $start, $count)
    }


    # =============================================================================
    # XMP
    # =============================================================================

    # Sucht das XMP-Paket "<x:xmpmeta ...>...</x:xmpmeta>" im Dateiinhalt.
    hidden static [void] FindXmp([byte[]]$bytes, [System.Collections.Generic.List[string]]$lines) {
        # Latin-1 bildet jedes Byte auf genau ein Zeichen ab, daher stimmen
        # die gefundenen Positionen mit den Bytepositionen überein.
        $text = [System.Text.Encoding]::Latin1.GetString($bytes)
        $start = $text.IndexOf("<x:xmpmeta", [System.StringComparison]::Ordinal)

        if ($start -lt 0) {
            return
        }

        $endTag = "</x:xmpmeta>"
        $end = $text.IndexOf($endTag, $start, [System.StringComparison]::Ordinal)

        if ($end -lt 0) {
            return
        }

        $xml = [System.Text.Encoding]::UTF8.GetString($bytes, $start, $end + $endTag.Length - $start)
        [ImageMetadata]::ReadXmp($xml, $lines)
    }


    # Werte stehen entweder als Element (<dc:title><rdf:Alt><rdf:li>...) oder
    # als Attribut von rdf:Description (photoshop:City="...").
    hidden static [void] ReadXmp([string]$xml, [System.Collections.Generic.List[string]]$lines) {
        $document = [System.Xml.XmlDocument]::new()
        $document.XmlResolver = $null

        try {
            $document.LoadXml($xml)
        }
        catch {
            # Beschädigtes XMP: die übrigen Metadaten bleiben erhalten.
            return
        }

        foreach ($node in $document.SelectNodes("//*")) {
            $label = $null

            if ([ImageMetadata]::XmpFields.TryGetValue($node.LocalName, [ref]$label)) {
                # Listen (rdf:Bag, rdf:Seq, rdf:Alt) enthalten mehrere
                # rdf:li; jedes wird ein eigener Wert.
                $items = $node.SelectNodes(".//*[local-name()='li']")

                if ($items.Count -gt 0) {
                    foreach ($item in $items) {
                        [ImageMetadata]::AddLine($lines, $label, $item.InnerText)
                    }
                }
                elseif (-not $node.HasChildNodes -or $node.FirstChild.NodeType -eq [System.Xml.XmlNodeType]::Text) {
                    [ImageMetadata]::AddLine($lines, $label, $node.InnerText)
                }
            }

            foreach ($attribute in $node.Attributes) {
                $attributeLabel = $null

                if (
                    $attribute.Prefix -ne "xmlns" -and
                    [ImageMetadata]::XmpFields.TryGetValue($attribute.LocalName, [ref]$attributeLabel)
                ) {
                    [ImageMetadata]::AddLine($lines, $attributeLabel, $attribute.Value)
                }
            }
        }
    }


    # =============================================================================
    # HILFSMETHODEN
    # =============================================================================

    # Text bis zum ersten Nullbyte. UTF-8, wenn gültig, sonst Latin-1 (ältere
    # Kameras schreiben Exif-Texte in einem Einzelbyte-Zeichensatz).
    hidden static [string] DecodeText([byte[]]$bytes, [int]$start, [int]$count) {
        $end = [Array]::IndexOf($bytes, [byte]0, $start, $count)
        $length = if ($end -ge 0) { $end - $start } else { $count }

        try {
            $strict = [System.Text.UTF8Encoding]::new($false, $true)
            return $strict.GetString($bytes, $start, $length)
        }
        catch {
            return [System.Text.Encoding]::Latin1.GetString($bytes, $start, $length)
        }
    }


    hidden static [byte[]] Inflate([byte[]]$bytes, [int]$start, [int]$length) {
        $source = [System.IO.MemoryStream]::new($bytes, $start, $length)
        $zlib = [System.IO.Compression.ZLibStream]::new($source, [System.IO.Compression.CompressionMode]::Decompress)
        $output = [System.IO.MemoryStream]::new()

        try {
            $zlib.CopyTo($output)
            return $output.ToArray()
        }
        catch {
            return [byte[]]@()
        }
        finally {
            $zlib.Dispose()
            $source.Dispose()
        }
    }


    hidden static [int] ReadUInt16([byte[]]$bytes, [long]$offset, [bool]$littleEndian) {
        if ($offset -lt 0 -or $offset + 2 -gt $bytes.Length) {
            return 0
        }

        if ($littleEndian) {
            return [int]$bytes[$offset] + ([int]$bytes[$offset + 1] -shl 8)
        }

        return ([int]$bytes[$offset] -shl 8) + [int]$bytes[$offset + 1]
    }


    hidden static [long] ReadUInt32([byte[]]$bytes, [long]$offset, [bool]$littleEndian) {
        if ($offset -lt 0 -or $offset + 4 -gt $bytes.Length) {
            return -1
        }

        $b0 = [long]$bytes[$offset]
        $b1 = [long]$bytes[$offset + 1]
        $b2 = [long]$bytes[$offset + 2]
        $b3 = [long]$bytes[$offset + 3]

        if ($littleEndian) {
            return $b0 + ($b1 * 0x100) + ($b2 * 0x10000) + ($b3 * 0x1000000)
        }

        return ($b0 * 0x1000000) + ($b1 * 0x10000) + ($b2 * 0x100) + $b3
    }


    # Fügt "Bezeichnung: Wert" hinzu, wenn der Wert nicht leer ist.
    hidden static [void] AddLine([System.Collections.Generic.List[string]]$lines, [string]$label, [string]$value) {
        if ([string]::IsNullOrWhiteSpace($value)) {
            return
        }

        # Steuerzeichen und Zeilenumbrüche würden das Format stören.
        $clean = [regex]::Replace($value, "[\x00-\x1F]+", " ").Trim()

        if ($clean.Length -gt 0) {
            $lines.Add("${label}: $clean")
        }
    }


    hidden static [string] Distinct([System.Collections.Generic.List[string]]$lines) {
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $result = [System.Collections.Generic.List[string]]::new()

        foreach ($line in $lines) {
            if ($seen.Add($line)) {
                $result.Add($line)
            }
        }

        return [string]::Join("`n", $result)
    }
}

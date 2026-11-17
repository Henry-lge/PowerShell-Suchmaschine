#requires -Version 7.4


# =============================================================================
# METADATEN AUS VIDEODATEIEN
# =============================================================================

# Liest Titel, Beschreibung, Stichwörter, Datum und Dauer aus Videodateien,
# ohne externe Tools und ohne die ganze Datei zu laden: Die Container
# bestehen aus verschachtelten Blöcken mit Längenangabe, daher springt der
# Leser über die großen Videodaten hinweg.
#
#   - MP4, M4V, MOV, 3GP (ISO Base Media / QuickTime): Blöcke ("Boxen") mit
#     4 Byte Länge und 4 Zeichen Typ. Metadaten stehen in moov/udta/meta/ilst
#     (iTunes-Stil, z. B. "©nam" für den Titel) oder in moov/meta mit
#     eigener Schlüsselliste (QuickTime, z. B. "com.apple.quicktime.title").
#     Die Dauer steht in moov/mvhd.
#   - MKV, WebM (Matroska/EBML): Elemente mit variabel langer ID und Länge.
#     Titel und Dauer stehen in Segment/Info, weitere Angaben in
#     Segment/Tags als Paare aus TagName und TagString.
#   - AVI (RIFF): Blöcke "LIST INFO" mit Unterblöcken wie INAM (Titel) oder
#     ICMT (Kommentar). Die Dauer ergibt sich aus dem Kopf "avih".
[NoRunspaceAffinity()]
class VideoMetadata {

    # Gelesener Text, eine Zeile "Bezeichnung: Wert" pro Angabe.
    [System.Collections.Generic.List[string]]$Lines = [System.Collections.Generic.List[string]]::new()

    # Dauer in Sekunden, 0 wenn unbekannt.
    [double]$DurationSeconds = 0

    # Blöcke mit Metadaten werden nur bis zu dieser Größe gelesen, damit eine
    # beschädigte Längenangabe nicht Gigabytes in den Speicher lädt.
    hidden static [long]$MaxBlockBytes = 64MB

    # iTunes-Tags (MP4) -> Bezeichnung. "©" ist in der Datei das Byte 0xA9.
    hidden static [hashtable]$Mp4Tags = @{
        "©nam" = "Title"
        "©ART" = "Artist"
        "©alb" = "Album"
        "©cmt" = "Comment"
        "desc" = "Description"
        "ldes" = "Description"
        "©des" = "Description"
        "©day" = "Date"
        "©gen" = "Genre"
        "©wrt" = "Composer"
        "keyw" = "Keywords"
        "©key" = "Keywords"
        "©aut" = "Author"
        "©dir" = "Director"
        "©inf" = "Information"
    }

    # QuickTime-Schlüssel (moov/meta/keys) -> Bezeichnung.
    hidden static [hashtable]$QuickTimeKeys = @{
        "com.apple.quicktime.title"         = "Title"
        "com.apple.quicktime.displayname"   = "Title"
        "com.apple.quicktime.description"   = "Description"
        "com.apple.quicktime.comment"       = "Comment"
        "com.apple.quicktime.keywords"      = "Keywords"
        "com.apple.quicktime.author"        = "Author"
        "com.apple.quicktime.artist"        = "Artist"
        "com.apple.quicktime.album"         = "Album"
        "com.apple.quicktime.genre"         = "Genre"
        "com.apple.quicktime.creationdate"  = "Date"
        "com.apple.quicktime.location.name" = "Location"
        "com.apple.quicktime.make"          = "Camera make"
        "com.apple.quicktime.model"         = "Camera model"
    }

    # 3GPP-Blöcke in udta (so schreibt z. B. AVFoundation MP4-Dateien) ->
    # Bezeichnung. Aufbau: Version/Flags(4), Sprache(2), Text mit Null am
    # Ende; "kywd" hat eine eigene Liste von Stichwörtern.
    hidden static [hashtable]$ThreeGppTags = @{
        "titl" = "Title"
        "dscp" = "Description"
        "auth" = "Author"
        "cprt" = "Copyright"
        "perf" = "Artist"
        "gnre" = "Genre"
        "albm" = "Album"
    }

    # RIFF-INFO (AVI) -> Bezeichnung.
    hidden static [hashtable]$AviTags = @{
        "INAM" = "Title"
        "IART" = "Artist"
        "ICMT" = "Comment"
        "ISBJ" = "Subject"
        "IKEY" = "Keywords"
        "ICRD" = "Date"
        "IGNR" = "Genre"
        "ICOP" = "Copyright"
        "IPRD" = "Album"
    }


    # Liest die Metadaten einer Datei. Unbekannte Formate ergeben ein leeres
    # Ergebnis; beschädigte Dateien liefern, was bis dahin lesbar war.
    static [VideoMetadata] Read([System.IO.Stream]$stream) {
        $result = [VideoMetadata]::new()
        $header = [byte[]]::new(12)

        if ([VideoMetadata]::ReadAt($stream, 0, $header, 12) -lt 12) {
            return $result
        }

        $ascii = [System.Text.Encoding]::ASCII

        if ($header[0] -eq 0x1A -and $header[1] -eq 0x45 -and $header[2] -eq 0xDF -and $header[3] -eq 0xA3) {
            $result.ReadMatroska($stream)
        }
        elseif ($ascii.GetString($header, 0, 4) -eq "RIFF" -and $ascii.GetString($header, 8, 4) -eq "AVI ") {
            $result.ReadAvi($stream)
        }
        else {
            # ISO-Dateien beginnen mit "ftyp", ältere QuickTime-Dateien
            # direkt mit "moov", "mdat", "wide" oder "free".
            $type = $ascii.GetString($header, 4, 4)

            if ($type -in "ftyp", "moov", "mdat", "wide", "free", "skip", "pnot") {
                $result.ReadIsoMedia($stream)
            }
        }

        return $result
    }


    # Gibt die Metadaten als Text zurück, doppelte Zeilen nur einmal.
    [string] ToText() {
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $result = [System.Collections.Generic.List[string]]::new()

        foreach ($line in $this.Lines) {
            if ($seen.Add($line)) {
                $result.Add($line)
            }
        }

        if ($this.DurationSeconds -gt 0) {
            $result.Add("Duration: " + [VideoMetadata]::FormatDuration($this.DurationSeconds))
        }

        return [string]::Join("`n", $result)
    }


    static [string] FormatDuration([double]$seconds) {
        $time = [TimeSpan]::FromSeconds([Math]::Round($seconds))

        if ($time.TotalHours -ge 1) {
            return "{0}:{1:00}:{2:00}" -f [int][Math]::Floor($time.TotalHours), $time.Minutes, $time.Seconds
        }

        return "{0}:{1:00}" -f $time.Minutes, $time.Seconds
    }


    # =============================================================================
    # MP4 / MOV
    # =============================================================================

    # Nur der Block "moov" enthält Metadaten. Er steht am Anfang oder am Ende
    # der Datei; die Videodaten ("mdat") werden übersprungen.
    hidden [void] ReadIsoMedia([System.IO.Stream]$stream) {
        $position = [long]0

        while ($position + 8 -le $stream.Length) {
            $box = [VideoMetadata]::ReadBoxHeader($stream, $position)

            if ($null -eq $box) {
                return
            }

            if ($box.Type -eq "moov") {
                if ($box.DataLength -le [VideoMetadata]::MaxBlockBytes) {
                    $data = [byte[]]::new($box.DataLength)
                    [void][VideoMetadata]::ReadAt($stream, $box.DataStart, $data, $box.DataLength)
                    $this.ReadMoov($data)
                }

                return
            }

            $position = $box.End
        }
    }


    # Kopf einer Box: Länge (4 Byte, big-endian), Typ (4 Zeichen). Länge 1:
    # danach folgt eine 8-Byte-Länge; Länge 0: bis zum Dateiende.
    hidden static [PSCustomObject] ReadBoxHeader([System.IO.Stream]$stream, [long]$position) {
        $header = [byte[]]::new(16)

        if ([VideoMetadata]::ReadAt($stream, $position, $header, 16) -lt 8) {
            return $null
        }

        $size = [VideoMetadata]::ReadUInt32BE($header, 0)
        $type = [System.Text.Encoding]::Latin1.GetString($header, 4, 4)
        $headerLength = 8

        if ($size -eq 1) {
            $size = [VideoMetadata]::ReadUInt64BE($header, 8)
            $headerLength = 16
        }
        elseif ($size -eq 0) {
            $size = $stream.Length - $position
        }

        if ($size -lt $headerLength -or $position + $size -gt $stream.Length) {
            return $null
        }

        return [PSCustomObject]@{
            Type       = $type
            DataStart  = $position + $headerLength
            DataLength = $size - $headerLength
            End        = $position + $size
        }
    }


    # Geht die Kinder eines Blocks im Speicher durch und gibt sie als
    # (Typ, Start, Länge) zurück.
    hidden static [PSCustomObject[]] ChildBoxes([byte[]]$data, [int]$start, [int]$end) {
        $boxes = [System.Collections.Generic.List[PSCustomObject]]::new()
        $position = $start

        while ($position + 8 -le $end) {
            $size = [VideoMetadata]::ReadUInt32BE($data, $position)
            $headerLength = 8

            if ($size -eq 1 -and $position + 16 -le $end) {
                $size = [VideoMetadata]::ReadUInt64BE($data, $position + 8)
                $headerLength = 16
            }
            elseif ($size -eq 0) {
                $size = $end - $position
            }

            if ($size -lt $headerLength -or $position + $size -gt $end) {
                break
            }

            $boxes.Add([PSCustomObject]@{
                Type   = [System.Text.Encoding]::Latin1.GetString($data, $position + 4, 4)
                Start  = $position + $headerLength
                Length = [int]($size - $headerLength)
            })

            $position += $size
        }

        return $boxes.ToArray()
    }


    hidden [void] ReadMoov([byte[]]$moov) {
        foreach ($box in [VideoMetadata]::ChildBoxes($moov, 0, $moov.Length)) {
            switch ($box.Type) {
                "mvhd" { $this.ReadMovieHeader($moov, $box.Start) }
                "udta" { $this.ReadUserData($moov, $box.Start, $box.Start + $box.Length) }
                "meta" { $this.ReadMeta($moov, $box.Start, $box.Start + $box.Length) }
            }
        }
    }


    # mvhd: Version 0 mit 4-Byte-Zeiten, Version 1 mit 8-Byte-Zeiten. Dauer
    # in Einheiten von 1/timescale Sekunden.
    hidden [void] ReadMovieHeader([byte[]]$data, [int]$start) {
        if ($start + 32 -gt $data.Length) {
            return
        }

        if ($data[$start] -eq 1) {
            $timescale = [VideoMetadata]::ReadUInt32BE($data, $start + 20)
            $duration = [VideoMetadata]::ReadUInt64BE($data, $start + 24)
        }
        else {
            $timescale = [VideoMetadata]::ReadUInt32BE($data, $start + 12)
            $duration = [VideoMetadata]::ReadUInt32BE($data, $start + 16)
        }

        if ($timescale -gt 0) {
            $this.DurationSeconds = $duration / $timescale
        }
    }


    # udta enthält entweder ein meta mit ilst (MP4) oder direkt
    # QuickTime-Textblöcke wie "©nam": je Eintrag Länge(2), Sprache(2), Text.
    hidden [void] ReadUserData([byte[]]$data, [int]$start, [int]$end) {
        foreach ($box in [VideoMetadata]::ChildBoxes($data, $start, $end)) {
            if ($box.Type -eq "meta") {
                $this.ReadMeta($data, $box.Start, $box.Start + $box.Length)
                continue
            }

            $threeGpp = [VideoMetadata]::ThreeGppTags[$box.Type]

            if ($null -ne $threeGpp -and $box.Length -gt 6) {
                $this.AddLine($threeGpp, [VideoMetadata]::Read3gppString($data, $box.Start + 6, $box.Start + $box.Length))
                continue
            }

            if ($box.Type -eq "kywd" -and $box.Length -gt 7) {
                $this.Read3gppKeywords($data, $box.Start, $box.Start + $box.Length)
                continue
            }

            $label = [VideoMetadata]::Mp4Tags[$box.Type]

            if ($null -eq $label -or $box.Length -lt 4) {
                continue
            }

            $length = ([int]$data[$box.Start] -shl 8) + $data[$box.Start + 1]

            if ($length -gt 0 -and $box.Start + 4 + $length -le $box.Start + $box.Length) {
                $this.AddLine($label, [System.Text.Encoding]::UTF8.GetString($data, $box.Start + 4, $length))
            }
        }
    }


    # Text bis zur abschließenden Null: UTF-16 mit BOM (FE FF), sonst UTF-8.
    hidden static [string] Read3gppString([byte[]]$data, [int]$start, [int]$end) {
        if ($start + 2 -le $end -and $data[$start] -eq 0xFE -and $data[$start + 1] -eq 0xFF) {
            $text = [System.Text.Encoding]::BigEndianUnicode.GetString($data, $start + 2, ($end - $start - 2) - (($end - $start - 2) % 2))
            return $text.TrimEnd([char]0)
        }

        $length = [Array]::IndexOf($data, [byte]0, $start, $end - $start) - $start

        if ($length -lt 0) {
            $length = $end - $start
        }

        return [System.Text.Encoding]::UTF8.GetString($data, $start, $length)
    }


    # kywd: Version/Flags(4), Sprache(2), Anzahl(1), dann je Stichwort
    # Länge(1) und Text.
    hidden [void] Read3gppKeywords([byte[]]$data, [int]$start, [int]$end) {
        $count = $data[$start + 6]
        $position = $start + 7

        for ($i = 0; $i -lt $count -and $position -lt $end; $i++) {
            $length = $data[$position]

            if ($position + 1 + $length -gt $end) {
                return
            }

            $this.AddLine("Keywords", [VideoMetadata]::Read3gppString($data, $position + 1, $position + 1 + $length))
            $position += 1 + $length
        }
    }


    # meta ist in MP4 eine "FullBox" mit 4 Byte Version/Flags vor den
    # Kindern, in QuickTime nicht. Steht dort gleich ein "hdlr", fehlen sie.
    hidden [void] ReadMeta([byte[]]$data, [int]$start, [int]$end) {
        $childStart = $start

        if ($start + 12 -le $end -and [System.Text.Encoding]::Latin1.GetString($data, $start + 4, 4) -ne "hdlr") {
            $childStart = $start + 4
        }

        $children = [VideoMetadata]::ChildBoxes($data, $childStart, $end)
        $keyNames = $null

        foreach ($box in $children) {
            if ($box.Type -eq "keys") {
                $keyNames = [VideoMetadata]::ReadKeys($data, $box.Start, $box.Start + $box.Length)
            }
        }

        foreach ($box in $children) {
            if ($box.Type -eq "ilst") {
                $this.ReadItemList($data, $box.Start, $box.Start + $box.Length, $keyNames)
            }
        }
    }


    # keys: Version/Flags(4), Anzahl(4), dann je Eintrag Länge(4),
    # Namensraum(4), Name. Die Einträge in ilst verweisen mit ihrem Typ als
    # Zahl (1-basiert) auf diese Liste.
    hidden static [string[]] ReadKeys([byte[]]$data, [int]$start, [int]$end) {
        $names = [System.Collections.Generic.List[string]]::new()
        $position = $start + 8

        while ($position + 8 -le $end) {
            $size = [VideoMetadata]::ReadUInt32BE($data, $position)

            if ($size -lt 8 -or $position + $size -gt $end) {
                break
            }

            $names.Add([System.Text.Encoding]::UTF8.GetString($data, $position + 8, $size - 8))
            $position += $size
        }

        return $names.ToArray()
    }


    # ilst: je Tag eine Box, darin "data": Typ(4), Sprache(4), Wert. Typ 1
    # ist UTF-8-Text, 2 UTF-16; andere Typen (Zahlen, Bilder) werden
    # übersprungen.
    hidden [void] ReadItemList([byte[]]$data, [int]$start, [int]$end, [string[]]$keyNames) {
        foreach ($item in [VideoMetadata]::ChildBoxes($data, $start, $end)) {
            $label = $null

            if ($null -ne $keyNames) {
                # QuickTime: Der Typ ist der 1-basierte Index in keys.
                $index = [VideoMetadata]::ReadUInt32BE($data, $item.Start - 4) - 1

                if ($index -ge 0 -and $index -lt $keyNames.Length) {
                    $label = [VideoMetadata]::QuickTimeKeys[$keyNames[$index]]
                }
            }
            else {
                $label = [VideoMetadata]::Mp4Tags[$item.Type]
            }

            if ($null -eq $label) {
                continue
            }

            foreach ($value in [VideoMetadata]::ChildBoxes($data, $item.Start, $item.Start + $item.Length)) {
                if ($value.Type -ne "data" -or $value.Length -lt 8) {
                    continue
                }

                $dataType = [VideoMetadata]::ReadUInt32BE($data, $value.Start) -band 0xFFFFFF
                $textStart = $value.Start + 8
                $textLength = $value.Length - 8

                if ($dataType -eq 1) {
                    $this.AddLine($label, [System.Text.Encoding]::UTF8.GetString($data, $textStart, $textLength))
                }
                elseif ($dataType -eq 2) {
                    $this.AddLine($label, [System.Text.Encoding]::BigEndianUnicode.GetString($data, $textStart, $textLength))
                }
            }
        }
    }


    # =============================================================================
    # MATROSKA / WEBM
    # =============================================================================

    # Struktur: EBML-Kopf, dann ein Segment mit Kindern (Info, Tracks,
    # Cluster mit den Videodaten, Tags, ...). Die Cluster werden anhand
    # ihrer Länge übersprungen; Tags stehen oft erst dahinter.
    hidden [void] ReadMatroska([System.IO.Stream]$stream) {
        $position = [long]0
        $segmentStart = -1
        $segmentEnd = [long]0

        while ($position -lt $stream.Length) {
            $element = [VideoMetadata]::ReadEbmlHeader($stream, $position)

            if ($null -eq $element) {
                return
            }

            if ($element.Id -eq 0x18538067) {
                $segmentStart = $element.DataStart
                $segmentEnd = if ($element.Size -lt 0) { $stream.Length } else { [Math]::Min($stream.Length, $element.DataStart + $element.Size) }
                break
            }

            if ($element.Size -lt 0) {
                return
            }

            $position = $element.DataStart + $element.Size
        }

        if ($segmentStart -lt 0) {
            return
        }

        $timecodeScale = 1000000.0
        $durationTicks = 0.0
        $position = $segmentStart

        while ($position -lt $segmentEnd) {
            $element = [VideoMetadata]::ReadEbmlHeader($stream, $position)

            # Unbekannte Länge (Live-Aufnahmen): Danach lässt sich nichts
            # mehr zuverlässig überspringen.
            if ($null -eq $element -or $element.Size -lt 0) {
                break
            }

            $isInfo = $element.Id -eq 0x1549A966
            $isTags = $element.Id -eq 0x1254C367

            if (($isInfo -or $isTags) -and $element.Size -le [VideoMetadata]::MaxBlockBytes) {
                $data = [byte[]]::new($element.Size)
                [void][VideoMetadata]::ReadAt($stream, $element.DataStart, $data, $element.Size)

                if ($isInfo) {
                    foreach ($child in [VideoMetadata]::EbmlChildren($data, 0, $data.Length)) {
                        switch ($child.Id) {
                            0x7BA9 { $this.AddLine("Title", [System.Text.Encoding]::UTF8.GetString($data, $child.Start, $child.Size)) }
                            0x2AD7B1 { $timecodeScale = [VideoMetadata]::ReadUnsigned($data, $child.Start, $child.Size) }
                            0x4489 { $durationTicks = [VideoMetadata]::ReadFloat($data, $child.Start, $child.Size) }
                        }
                    }
                }
                else {
                    $this.ReadMatroskaTags($data)
                }
            }

            $position = $element.DataStart + $element.Size
        }

        if ($durationTicks -gt 0) {
            $this.DurationSeconds = $durationTicks * $timecodeScale / 1e9
        }
    }


    # Tags > Tag > SimpleTag mit TagName (z. B. "DESCRIPTION") und
    # TagString. SimpleTags können verschachtelt sein.
    hidden [void] ReadMatroskaTags([byte[]]$data) {
        foreach ($tag in [VideoMetadata]::EbmlChildren($data, 0, $data.Length)) {
            if ($tag.Id -ne 0x7373) {
                continue
            }

            foreach ($simple in [VideoMetadata]::EbmlChildren($data, $tag.Start, $tag.Start + $tag.Size)) {
                if ($simple.Id -eq 0x67C8) {
                    $this.ReadSimpleTag($data, $simple.Start, $simple.Start + $simple.Size)
                }
            }
        }
    }


    hidden [void] ReadSimpleTag([byte[]]$data, [int]$start, [int]$end) {
        $name = ""
        $value = ""

        foreach ($child in [VideoMetadata]::EbmlChildren($data, $start, $end)) {
            switch ($child.Id) {
                0x45A3 { $name = [System.Text.Encoding]::UTF8.GetString($data, $child.Start, $child.Size) }
                0x4487 { $value = [System.Text.Encoding]::UTF8.GetString($data, $child.Start, $child.Size) }
                0x67C8 { $this.ReadSimpleTag($data, $child.Start, $child.Start + $child.Size) }
            }
        }

        # Technische Angaben (z. B. ENCODER, DURATION pro Spur) bringen bei
        # der Suche nichts.
        if ($name -notin "ENCODER", "DURATION", "NUMBER_OF_FRAMES", "NUMBER_OF_BYTES", "BPS", "_STATISTICS_TAGS", "_STATISTICS_WRITING_APP", "_STATISTICS_WRITING_DATE_UTC") {
            $label = (Get-Culture).TextInfo.ToTitleCase($name.ToLowerInvariant().Replace("_", " "))
            $this.AddLine($label, $value)
        }
    }


    # Kopf eines EBML-Elements: ID und Länge sind Zahlen variabler Länge.
    # Die Anzahl führender Nullbits im ersten Byte gibt die Länge an. Bei der
    # ID bleibt das Markierungsbit erhalten, bei der Länge nicht. Alle
    # Datenbits 1 bedeutet "unbekannte Länge" (Size = -1).
    hidden static [PSCustomObject] ReadEbmlHeader([System.IO.Stream]$stream, [long]$position) {
        $buffer = [byte[]]::new(12)
        $read = [VideoMetadata]::ReadAt($stream, $position, $buffer, 12)

        if ($read -lt 2) {
            return $null
        }

        $element = [VideoMetadata]::ParseEbml($buffer, 0, $read)

        if ($null -eq $element) {
            return $null
        }

        return [PSCustomObject]@{
            Id        = $element.Id
            Size      = $element.Size
            DataStart = $position + $element.HeaderLength
        }
    }


    hidden static [PSCustomObject[]] EbmlChildren([byte[]]$data, [int]$start, [int]$end) {
        $children = [System.Collections.Generic.List[PSCustomObject]]::new()
        $position = $start

        while ($position -lt $end) {
            $element = [VideoMetadata]::ParseEbml($data, $position, $end)

            if ($null -eq $element -or $element.Size -lt 0) {
                break
            }

            $dataStart = $position + $element.HeaderLength

            if ($dataStart + $element.Size -gt $end) {
                break
            }

            $children.Add([PSCustomObject]@{
                Id    = $element.Id
                Start = $dataStart
                Size  = [int]$element.Size
            })

            $position = $dataStart + $element.Size
        }

        return $children.ToArray()
    }


    hidden static [PSCustomObject] ParseEbml([byte[]]$data, [int]$position, [int]$end) {
        if ($position -ge $end) {
            return $null
        }

        $idLength = [VideoMetadata]::VarIntLength($data[$position])

        if ($idLength -eq 0 -or $idLength -gt 4 -or $position + $idLength -ge $end) {
            return $null
        }

        [long]$id = 0

        for ($i = 0; $i -lt $idLength; $i++) {
            $id = ($id * 256) + $data[$position + $i]
        }

        $sizeStart = $position + $idLength
        $sizeLength = [VideoMetadata]::VarIntLength($data[$sizeStart])

        if ($sizeLength -eq 0 -or $sizeStart + $sizeLength -gt $end) {
            return $null
        }

        # Erstes Byte ohne Markierungsbit, danach die übrigen Bytes.
        [long]$size = $data[$sizeStart] -band ((0xFF -shr $sizeLength))
        $allOnes = $size -eq ((0xFF -shr $sizeLength))

        for ($i = 1; $i -lt $sizeLength; $i++) {
            $size = ($size * 256) + $data[$sizeStart + $i]
            $allOnes = $allOnes -and $data[$sizeStart + $i] -eq 0xFF
        }

        return [PSCustomObject]@{
            Id           = $id
            Size         = if ($allOnes) { [long]-1 } else { $size }
            HeaderLength = $idLength + $sizeLength
        }
    }


    # Anzahl der Bytes einer EBML-Zahl: Position des ersten gesetzten Bits.
    hidden static [int] VarIntLength([byte]$first) {
        for ($i = 0; $i -lt 8; $i++) {
            if (($first -band (0x80 -shr $i)) -ne 0) {
                return $i + 1
            }
        }

        return 0
    }


    hidden static [double] ReadUnsigned([byte[]]$data, [int]$start, [int]$length) {
        [double]$value = 0

        for ($i = 0; $i -lt $length; $i++) {
            $value = ($value * 256) + $data[$start + $i]
        }

        return $value
    }


    # Gleitkommazahl mit 4 oder 8 Byte, big-endian.
    hidden static [double] ReadFloat([byte[]]$data, [int]$start, [int]$length) {
        $bytes = [byte[]]::new($length)
        [Array]::Copy($data, $start, $bytes, 0, $length)

        if ([BitConverter]::IsLittleEndian) {
            [Array]::Reverse($bytes)
        }

        if ($length -eq 4) {
            return [BitConverter]::ToSingle($bytes, 0)
        }

        if ($length -eq 8) {
            return [BitConverter]::ToDouble($bytes, 0)
        }

        return 0
    }


    # =============================================================================
    # AVI
    # =============================================================================

    # RIFF-Blöcke: Typ(4), Länge(4, little-endian), Daten, auf gerade Länge
    # aufgefüllt. "LIST" enthält nach der Länge einen Listentyp(4) und
    # Unterblöcke. Der Block "movi" mit den Videodaten wird übersprungen.
    hidden [void] ReadAvi([System.IO.Stream]$stream) {
        $position = [long]12
        $header = [byte[]]::new(12)

        while ($position + 12 -le $stream.Length) {
            [void][VideoMetadata]::ReadAt($stream, $position, $header, 12)
            $type = [System.Text.Encoding]::ASCII.GetString($header, 0, 4)
            $size = [long][BitConverter]::ToUInt32($header, 4)

            if ($position + 8 + $size -gt $stream.Length) {
                return
            }

            if ($type -eq "LIST") {
                $listType = [System.Text.Encoding]::ASCII.GetString($header, 8, 4)

                if ($listType -in "INFO", "hdrl" -and $size -le [VideoMetadata]::MaxBlockBytes) {
                    $data = [byte[]]::new($size - 4)
                    [void][VideoMetadata]::ReadAt($stream, $position + 12, $data, $size - 4)

                    if ($listType -eq "INFO") {
                        $this.ReadAviInfo($data)
                    }
                    else {
                        $this.ReadAviHeader($data)
                    }
                }
            }

            $position += 8 + $size + ($size % 2)
        }
    }


    hidden [void] ReadAviInfo([byte[]]$data) {
        $position = 0

        while ($position + 8 -le $data.Length) {
            $type = [System.Text.Encoding]::ASCII.GetString($data, $position, 4)
            $size = [int][BitConverter]::ToUInt32($data, $position + 4)

            if ($size -lt 0 -or $position + 8 + $size -gt $data.Length) {
                return
            }

            $label = [VideoMetadata]::AviTags[$type]

            if ($null -ne $label) {
                $text = [System.Text.Encoding]::UTF8.GetString($data, $position + 8, $size)
                $this.AddLine($label, $text)
            }

            $position += 8 + $size + ($size % 2)
        }
    }


    # avih: Mikrosekunden pro Bild (Offset 0) und Anzahl Bilder (Offset 16).
    hidden [void] ReadAviHeader([byte[]]$data) {
        if ($data.Length -lt 32 -or [System.Text.Encoding]::ASCII.GetString($data, 0, 4) -ne "avih") {
            return
        }

        $microSecondsPerFrame = [BitConverter]::ToUInt32($data, 8)
        $frames = [BitConverter]::ToUInt32($data, 24)
        $this.DurationSeconds = $microSecondsPerFrame * [double]$frames / 1e6
    }


    # =============================================================================
    # HILFSMETHODEN
    # =============================================================================

    hidden [void] AddLine([string]$label, [string]$value) {
        if ([string]::IsNullOrWhiteSpace($value)) {
            return
        }

        $clean = [regex]::Replace($value, "[\x00-\x1F]+", " ").Trim()

        if ($clean.Length -gt 0) {
            $this.Lines.Add("${label}: $clean")
        }
    }


    # Liest ab einer Position; gibt die Anzahl gelesener Bytes zurück.
    hidden static [int] ReadAt([System.IO.Stream]$stream, [long]$position, [byte[]]$buffer, [long]$count) {
        if ($position -lt 0 -or $position -ge $stream.Length) {
            return 0
        }

        [void]$stream.Seek($position, [System.IO.SeekOrigin]::Begin)
        $total = 0

        while ($total -lt $count) {
            $read = $stream.Read($buffer, $total, [int]($count - $total))

            if ($read -le 0) {
                break
            }

            $total += $read
        }

        return $total
    }


    hidden static [long] ReadUInt32BE([byte[]]$data, [long]$offset) {
        return ([long]$data[$offset] -shl 24) + ([long]$data[$offset + 1] -shl 16) + ([long]$data[$offset + 2] -shl 8) + [long]$data[$offset + 3]
    }


    hidden static [long] ReadUInt64BE([byte[]]$data, [long]$offset) {
        [long]$value = 0

        for ($i = 0; $i -lt 8; $i++) {
            $value = ($value -shl 8) + $data[$offset + $i]
        }

        return $value
    }
}

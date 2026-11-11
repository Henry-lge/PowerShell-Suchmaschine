using module "../ContentReader.psm1"

#requires -Version 7.4


# =============================================================================
# READER FÜR ARCHIVE
# =============================================================================

# Gibt die Namen der Dateien in einem Archiv zurück, eine pro Zeile. So findet
# eine Suche nach einem Dateinamen auch das Archiv, das die Datei enthält. Die
# Dateien werden nur aufgelistet, nie entpackt.
#
# Tools:
#   - .zip                   in .NET eingebaut, alle Plattformen
#   - .tar, .tgz, .tar.gz    eigener Leser der Tar-Köpfe, gzip über .NET;
#                            "tar" nur, falls das Archiv so nicht lesbar ist
#   - .tbz2, .txz, ...       "tar" (Windows 10+, macOS, Linux)
#   - .7z, .rar              "tar", wenn es bsdtar/libarchive ist (macOS,
#                            Windows), sonst 7-Zip ("7z", "7zz", "7za")
# Die unterstützten Endungen werden im Konstruktor abhängig von den
# installierten Tools gewählt, damit fehlende Tools nie zu Fehlern im Scan
# führen.
#
# Eine einzelne komprimierte Datei wie "notes.txt.gz" ist kein Archiv; ihr
# Inhalt ist der Name der inneren Datei ("notes.txt").
[NoRunspaceAffinity()]
class ArchiveContentReader : ContentReader {

    # Sehr große Archive werden nach so vielen Namen abgeschnitten.
    [int]$MaxEntries = 10000

    hidden [string]$_tarTool
    hidden [bool]$_tarIsLibarchive
    hidden [string]$_sevenZipTool


    ArchiveContentReader() {
        $this.Description = "Archives (file list)"

        $supported = [System.Collections.Generic.List[string]]::new()
        $supported.AddRange([string[]]@(".zip", ".tar", ".tgz", ".gz"))

        $this._tarTool = $this.FindTool(@("bsdtar", "tar"))
        $this._sevenZipTool = $this.FindTool(@("7z", "7zz", "7za"))

        if (-not [string]::IsNullOrEmpty($this._tarTool)) {
            $supported.AddRange([string[]]@(".tbz2", ".txz", ".bz2", ".xz"))

            # bsdtar (libarchive) listet auch 7z und RAR auf, GNU tar nicht.
            try {
                $version = $this.RunTool($this._tarTool, @("--version"), 10)
                $this._tarIsLibarchive = $version -match "bsdtar|libarchive"
            }
            catch {
                $this._tarIsLibarchive = $false
            }
        }

        if ($this._tarIsLibarchive -or -not [string]::IsNullOrEmpty($this._sevenZipTool)) {
            $supported.AddRange([string[]]@(".7z", ".rar"))
        }

        $this.Extensions = $supported.ToArray()
    }


    [string] ReadContent([System.IO.FileInfo]$file) {
        $extension = $file.Extension.ToLowerInvariant()

        if ($extension -eq ".zip") {
            return $this._FormatNames($this._ListZip($file))
        }

        # "x.txt.gz" ist eine einzelne komprimierte Datei, "x.tar.gz" ein Archiv.
        if (
            $extension -in @(".gz", ".bz2", ".xz") -and
            $file.Name -notmatch "\.tar\.(gz|bz2|xz)$"
        ) {
            return [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        }

        # Tar und gzip-komprimiertes Tar werden selbst gelesen. Das spart pro
        # Archiv einen externen Prozess, der weit mehr Zeit kostet als das
        # Auflisten.
        $isGzipTar = $extension -eq ".tgz" -or $file.Name -match "\.tar\.gz$"

        if ($extension -eq ".tar" -or $isGzipTar) {
            try {
                return $this._FormatNames($this._ListTar($file, $isGzipTar))
            }
            catch {
                # Exotische Tar-Varianten kann "tar" eventuell trotzdem lesen.
                if ([string]::IsNullOrEmpty($this._tarTool)) {
                    throw
                }
            }
        }

        if ($extension -in @(".7z", ".rar") -and -not $this._tarIsLibarchive) {
            return $this._FormatNames($this._ListSevenZip($file))
        }

        $output = $this.RunTool($this._tarTool, @("-tf", $file.FullName), 60)

        return $this._FormatNames($output -split "\r?\n")
    }


    hidden [string[]] _ListZip([System.IO.FileInfo]$file) {
        $zip = $this.OpenZip($file)

        try {
            $names = [System.Collections.Generic.List[string]]::new()

            foreach ($entry in $zip.Entries) {
                $names.Add($entry.FullName)
            }

            return $names.ToArray()
        }
        finally {
            $zip.Dispose()
        }
    }


    # Liest nur die Kopfzeilen der Einträge; der Inhalt wird übersprungen.
    # Bei gzip wird der Datenstrom unterwegs entpackt.
    #
    # Aufbau: Jeder Eintrag beginnt mit einem Kopf aus 512 Bytes, danach
    # folgt der Inhalt, aufgefüllt auf ein Vielfaches von 512. Zwei leere
    # Köpfe markieren das Ende. Im Kopf stehen:
    #   0..99     Name (bei ustar ergänzt um das Präfix in 345..499)
    #   124..135  Größe des Inhalts, oktal
    #   156       Typ: "5" Ordner, "x" PAX-Kopf für den nächsten Eintrag,
    #             "g" globaler PAX-Kopf, "L" langer GNU-Name des nächsten
    #             Eintrags, "K" langes GNU-Linkziel
    #   257..262  "ustar" bei ustar und PAX
    #
    # Nicht System.Formats.Tar: Es ignoriert das ustar-Präfix in PAX-Archiven
    # ohne eigenen "path"-Eintrag, wie sie tar unter macOS erzeugt, und kürzt
    # so lange Pfade.
    hidden [string[]] _ListTar([System.IO.FileInfo]$file, [bool]$isGzip) {
        $names = [System.Collections.Generic.List[string]]::new()
        $stream = $this.OpenFile($file)
        $source = $stream

        try {
            if ($isGzip) {
                $source = [System.IO.Compression.GZipStream]::new(
                    $stream,
                    [System.IO.Compression.CompressionMode]::Decompress
                )
            }

            $utf8 = [System.Text.Encoding]::UTF8
            $header = [byte[]]::new(512)
            $nextName = $null

            # Ein Eintrag mehr als MaxEntries reicht, damit _FormatNames
            # "... more" anzeigt.
            while ($names.Count -le $this.MaxEntries) {
                if (-not [ArchiveContentReader]::ReadFully($source, $header, 512)) {
                    break
                }

                # Leerer Kopf: Ende des Archivs.
                if ($header[0] -eq 0) {
                    break
                }

                $type = [char]$header[156]
                $size = [ArchiveContentReader]::ParseTarSize($header)
                $paddedSize = [long]([Math]::Ceiling($size / 512.0) * 512)

                if ($type -eq [char]"x" -or $type -eq [char]"L") {
                    if ($size -gt 1MB) {
                        throw "Tar header too large."
                    }

                    $data = [byte[]]::new($paddedSize)

                    if (-not [ArchiveContentReader]::ReadFully($source, $data, $paddedSize)) {
                        break
                    }

                    if ($type -eq [char]"L") {
                        $nextName = $utf8.GetString($data, 0, $size).TrimEnd([char]0)
                    }
                    else {
                        $path = [ArchiveContentReader]::FindPaxPath($utf8.GetString($data, 0, $size))

                        # [string]-Methoden liefern "" statt $null.
                        if (-not [string]::IsNullOrEmpty($path)) {
                            $nextName = $path
                        }
                    }

                    continue
                }

                [ArchiveContentReader]::SkipBytes($source, $paddedSize)

                # Globale PAX-Köpfe und GNU-Linkziele sind keine Einträge.
                if ($type -eq [char]"g" -or $type -eq [char]"K") {
                    continue
                }

                $name = $nextName
                $nextName = $null

                if ($null -eq $name) {
                    $name = [ArchiveContentReader]::ReadTarString($header, 0, 100)
                    $isUstar = [ArchiveContentReader]::ReadTarString($header, 257, 6) -eq "ustar"
                    $prefix = if ($isUstar) { [ArchiveContentReader]::ReadTarString($header, 345, 155) } else { "" }

                    if ($prefix.Length -gt 0) {
                        $name = "$prefix/$name"
                    }
                }

                # "._name" sind AppleDouble-Einträge, in denen macOS
                # Zusatzdaten einer Datei ablegt; tar blendet sie aus.
                if (
                    $type -ne [char]"5" -and
                    -not [System.IO.Path]::GetFileName($name).StartsWith("._")
                ) {
                    $names.Add($name)
                }
            }
        }
        finally {
            $source.Dispose()
            $stream.Dispose()
        }

        return $names.ToArray()
    }


    # Liest genau $count Bytes; $false, wenn der Datenstrom vorher endet.
    hidden static [bool] ReadFully([System.IO.Stream]$stream, [byte[]]$buffer, [long]$count) {
        $offset = 0

        while ($offset -lt $count) {
            $read = $stream.Read($buffer, $offset, $count - $offset)

            if ($read -le 0) {
                return $false
            }

            $offset += $read
        }

        return $true
    }


    # Überspringt den Inhalt eines Eintrags. Eine Datei wird per Seek
    # übersprungen, ein entpackter gzip-Strom muss gelesen werden.
    hidden static [void] SkipBytes([System.IO.Stream]$stream, [long]$count) {
        if ($count -le 0) {
            return
        }

        if ($stream.CanSeek) {
            [void]$stream.Seek($count, [System.IO.SeekOrigin]::Current)
            return
        }

        $buffer = [byte[]]::new(81920)

        while ($count -gt 0) {
            $read = $stream.Read($buffer, 0, [int][Math]::Min($buffer.Length, $count))

            if ($read -le 0) {
                return
            }

            $count -= $read
        }
    }


    # Größenfeld: oktaler Text, bei sehr großen Dateien binär (erstes Byte
    # mit gesetztem höchsten Bit, danach big-endian).
    hidden static [long] ParseTarSize([byte[]]$header) {
        if (($header[124] -band 0x80) -ne 0) {
            [long]$value = 0

            for ($i = 128; $i -lt 136; $i++) {
                $value = ($value * 256) + $header[$i]
            }

            return $value
        }

        $text = [ArchiveContentReader]::ReadTarString($header, 124, 12).Trim()

        if ($text.Length -eq 0) {
            return 0
        }

        return [Convert]::ToInt64($text, 8)
    }


    # Textfeld bis zum ersten Nullbyte, als UTF-8.
    hidden static [string] ReadTarString([byte[]]$header, [int]$offset, [int]$length) {
        $end = [Array]::IndexOf($header, [byte]0, $offset, $length)

        if ($end -lt 0) {
            $end = $offset + $length
        }

        return [System.Text.Encoding]::UTF8.GetString($header, $offset, $end - $offset)
    }


    # PAX-Daten bestehen aus Zeilen "<Länge> <Schlüssel>=<Wert>". Gibt den
    # Wert von "path" zurück oder $null.
    hidden static [string] FindPaxPath([string]$data) {
        foreach ($line in $data.Split([char]"`n")) {
            $space = $line.IndexOf([char]" ")

            if ($space -ge 0 -and $line.Substring($space + 1).StartsWith("path=")) {
                return $line.Substring($space + 6)
            }
        }

        return $null
    }


    # "7z l -slt" gibt pro Eintrag eine Zeile "Path = ..." aus; -ba blendet
    # den Kopfbereich mit dem Pfad des Archivs selbst aus.
    hidden [string[]] _ListSevenZip([System.IO.FileInfo]$file) {
        $output = $this.RunTool($this._sevenZipTool, @("l", "-ba", "-slt", $file.FullName), 60)

        return [string[]]@(
            $output -split "\r?\n" |
                Where-Object { $_.StartsWith("Path = ") } |
                ForEach-Object { $_.Substring(7) }
        )
    }


    # Ein Name pro Zeile ohne Ordnereinträge, begrenzt auf MaxEntries.
    # Als Schleife statt Pipeline, weil Archive Tausende Einträge haben können.
    hidden [string] _FormatNames([string[]]$names) {
        $files = [System.Collections.Generic.List[string]]::new()

        foreach ($name in $names) {
            if (
                [string]::IsNullOrWhiteSpace($name) -or
                $name.EndsWith("/") -or
                $name.EndsWith("\")
            ) {
                continue
            }

            # tar gibt "./name" aus; macOS speichert Umlaute zerlegt
            # (o + kombinierendes Zeichen), Normalize() setzt sie wieder
            # zusammen.
            if ($name.StartsWith("./")) {
                $name = $name.Substring(2)
            }

            $files.Add($name.Normalize())
        }

        if ($files.Count -le $this.MaxEntries) {
            return [string]::Join("`n", $files)
        }

        $shown = [string]::Join("`n", $files.GetRange(0, $this.MaxEntries))

        return "$shown`n... ($($files.Count - $this.MaxEntries) more)"
    }
}

using module "../ContentReader.psm1"
using module "../Shared/CompoundFile.psm1"

#requires -Version 7.2


# =============================================================================
# READER FÜR ALTE EXCEL-DATEIEN (.xls, Excel 97-2003)
# =============================================================================

# Liest die Zellwerte binärer Excel-Arbeitsmappen mit einem eigenen Parser
# (MS-XLS, "BIFF8"). Die Datei ist eine OLE-Verbunddatei (siehe
# Shared/CompoundFile.psm1) mit dem Stream "Workbook".
#
# Der Stream ist eine Liste von Records: 2 Bytes Typ, 2 Bytes Länge, Daten.
#   - BOF (0x0809) / EOF (0x000A) umschließen die globalen Daten der Mappe
#     und jedes Blatt
#   - BOUNDSHEET (0x0085) Name und Stream-Position jedes Blatts
#   - SST (0x00FC) Tabelle der gemeinsamen Texte; lange Tabellen gehen in
#     CONTINUE-Records (0x003C) weiter
#   - Zellen: LABELSST (0x00FD) Index in die SST, LABEL (0x0204) Text,
#     NUMBER (0x0203), RK (0x027E) und MULRK (0x00BD) komprimierte Zahlen,
#     BOOLERR (0x0205), FORMULA (0x0006) mit gespeichertem Ergebnis; ein
#     Text-Ergebnis folgt in einem STRING-Record (0x0207)
#
# Ausgabe: pro Blatt eine Zeile mit dem Blattnamen, dann eine Zeile pro
# Tabellenzeile mit den nicht leeren Zellen, getrennt durch Tabulatoren.
# Verschlüsselte Mappen (Record FILEPASS) und Dateien von Excel 5/95 liefern
# keinen Text.
class LegacyExcelContentReader : ContentReader {

    LegacyExcelContentReader() {
        $this.Description = "Excel 97-2003 workbooks"
        $this.Extensions = @(".xls", ".xlt")
    }


    [string] ReadContent([System.IO.FileInfo]$file) {
        $data = $this.ReadFileBytes($file)

        # Manche Programme speichern HTML oder CSV mit der Endung .xls.
        if (-not [CompoundFile]::IsCompoundFile($data)) {
            return ""
        }

        $compoundFile = [CompoundFile]::new($data)
        $workbookEntry = $compoundFile.FindChild($compoundFile.GetRoot(), "Workbook")

        # Excel 5/95 verwendet den Stream "Book" mit einem älteren Format.
        if ($null -eq $workbookEntry) {
            return ""
        }

        return [LegacyExcelContentReader]::ReadWorkbook($compoundFile.ReadStream($workbookEntry))
    }


    static [string] ReadWorkbook([byte[]]$stream) {
        $sheetNamesByPosition = @{}
        $sheetOrder = [System.Collections.Generic.List[string]]::new()
        $sheets = @{}
        $sharedStrings = [string[]]@()

        $currentSheet = $null
        $pendingFormulaCell = $null
        $position = 0

        while ($position + 4 -le $stream.Length) {
            $recordType = [System.BitConverter]::ToUInt16($stream, $position)
            $size = [System.BitConverter]::ToUInt16($stream, $position + 2)
            $dataStart = $position + 4

            if ($dataStart + $size -gt $stream.Length) {
                break
            }

            switch ($recordType) {
                0x0809 {
                    # BOF: Version 0x0600 = BIFF8. Ein Blatt beginnt an der
                    # Position, die in seinem BOUNDSHEET-Record steht.
                    if ($position -eq 0 -and [System.BitConverter]::ToUInt16($stream, $dataStart) -ne 0x0600) {
                        return ""
                    }

                    $currentSheet = $null

                    if ($sheetNamesByPosition.ContainsKey($position)) {
                        $currentSheet = [System.Collections.Generic.SortedDictionary[int, System.Collections.Generic.SortedDictionary[int, string]]]::new()
                        $sheets[$sheetNamesByPosition[$position]] = $currentSheet
                    }
                }
                0x002F {
                    # FILEPASS: Die Arbeitsmappe ist verschlüsselt.
                    return ""
                }
                0x0085 {
                    # BOUNDSHEET: Stream-Position (4), Flags (2), Name.
                    $sheetPosition = [System.BitConverter]::ToInt32($stream, $dataStart)
                    $nameLength = $stream[$dataStart + 6]
                    $isUnicode = ($stream[$dataStart + 7] -band 0x01) -ne 0
                    $name = [LegacyExcelContentReader]::DecodeChars($stream, $dataStart + 8, $nameLength, $isUnicode)

                    $sheetNamesByPosition[$sheetPosition] = $name
                    $sheetOrder.Add($name)
                }
                0x00FC {
                    # SST und alle direkt folgenden CONTINUE-Records.
                    $segments = [System.Collections.Generic.List[byte[]]]::new()
                    $segments.Add([LegacyExcelContentReader]::Slice($stream, $dataStart, $size))

                    $nextPosition = $dataStart + $size

                    while (
                        $nextPosition + 4 -le $stream.Length -and
                        [System.BitConverter]::ToUInt16($stream, $nextPosition) -eq 0x003C
                    ) {
                        $continueSize = [System.BitConverter]::ToUInt16($stream, $nextPosition + 2)
                        $segments.Add([LegacyExcelContentReader]::Slice($stream, $nextPosition + 4, $continueSize))
                        $nextPosition += 4 + $continueSize
                    }

                    $sharedStrings = [LegacyExcelContentReader]::ReadSharedStrings($segments)
                }
                0x00FD {
                    # LABELSST: Zeile, Spalte, Format, Index des Textes.
                    $index = [System.BitConverter]::ToInt32($stream, $dataStart + 6)

                    if ($index -ge 0 -and $index -lt $sharedStrings.Length) {
                        [LegacyExcelContentReader]::SetCell($currentSheet, $stream, $dataStart, $sharedStrings[$index])
                    }
                }
                0x0204 {
                    # LABEL: Text direkt im Record.
                    $reader = [BiffStringReader]::new([System.Collections.Generic.List[byte[]]]@(, [LegacyExcelContentReader]::Slice($stream, $dataStart + 6, $size - 6)))
                    [LegacyExcelContentReader]::SetCell($currentSheet, $stream, $dataStart, $reader.ReadString($false))
                }
                0x0203 {
                    $number = [System.BitConverter]::ToDouble($stream, $dataStart + 6)
                    [LegacyExcelContentReader]::SetCell($currentSheet, $stream, $dataStart, [LegacyExcelContentReader]::FormatNumber($number))
                }
                0x027E {
                    $number = [LegacyExcelContentReader]::DecodeRk([System.BitConverter]::ToUInt32($stream, $dataStart + 6))
                    [LegacyExcelContentReader]::SetCell($currentSheet, $stream, $dataStart, [LegacyExcelContentReader]::FormatNumber($number))
                }
                0x00BD {
                    # MULRK: Zeile, erste Spalte, (Format + RK) pro Zelle,
                    # letzte Spalte.
                    if ($null -ne $currentSheet) {
                        $row = [System.BitConverter]::ToUInt16($stream, $dataStart)
                        $firstColumn = [System.BitConverter]::ToUInt16($stream, $dataStart + 2)
                        $cellCount = [int](($size - 6) / 6)

                        for ($cell = 0; $cell -lt $cellCount; $cell++) {
                            $rk = [System.BitConverter]::ToUInt32($stream, $dataStart + 4 + $cell * 6 + 2)
                            $text = [LegacyExcelContentReader]::FormatNumber([LegacyExcelContentReader]::DecodeRk($rk))
                            [LegacyExcelContentReader]::PutCell($currentSheet, $row, $firstColumn + $cell, $text)
                        }
                    }
                }
                0x0205 {
                    # BOOLERR: Byte mit dem Wert und Fehler-Flag.
                    if ($stream[$dataStart + 7] -eq 0) {
                        $text = if ($stream[$dataStart + 6] -ne 0) { "TRUE" } else { "FALSE" }
                        [LegacyExcelContentReader]::SetCell($currentSheet, $stream, $dataStart, $text)
                    }
                }
                0x0006 {
                    # FORMULA: gespeichertes Ergebnis in Bytes 6-13. 0xFFFF in
                    # Bytes 12-13 kennzeichnet keine Zahl; Byte 6 ist dann
                    # ihr Typ.
                    $pendingFormulaCell = $null

                    if ([System.BitConverter]::ToUInt16($stream, $dataStart + 12) -ne 0xFFFF) {
                        $number = [System.BitConverter]::ToDouble($stream, $dataStart + 6)
                        [LegacyExcelContentReader]::SetCell($currentSheet, $stream, $dataStart, [LegacyExcelContentReader]::FormatNumber($number))
                    }
                    elseif ($stream[$dataStart + 6] -eq 0) {
                        # Text-Ergebnis: folgt im nächsten STRING-Record.
                        $pendingFormulaCell = $dataStart
                    }
                    elseif ($stream[$dataStart + 6] -eq 1) {
                        $text = if ($stream[$dataStart + 8] -ne 0) { "TRUE" } else { "FALSE" }
                        [LegacyExcelContentReader]::SetCell($currentSheet, $stream, $dataStart, $text)
                    }
                }
                0x0207 {
                    if ($null -ne $pendingFormulaCell) {
                        $reader = [BiffStringReader]::new([System.Collections.Generic.List[byte[]]]@(, [LegacyExcelContentReader]::Slice($stream, $dataStart, $size)))
                        [LegacyExcelContentReader]::SetCell($currentSheet, $stream, $pendingFormulaCell, $reader.ReadString($false))
                        $pendingFormulaCell = $null
                    }
                }
            }

            $position = $dataStart + $size
        }

        return [LegacyExcelContentReader]::FormatSheets($sheetOrder, $sheets)
    }


    hidden static [string[]] ReadSharedStrings([System.Collections.Generic.List[byte[]]]$segments) {
        $reader = [BiffStringReader]::new($segments)
        $strings = [System.Collections.Generic.List[string]]::new()

        try {
            [void]$reader.ReadInt32()
            $uniqueCount = $reader.ReadInt32()

            for ($i = 0; $i -lt $uniqueCount; $i++) {
                $strings.Add($reader.ReadString($true))
            }
        }
        catch {
            # Bei einer beschädigten Tabelle bleiben die bisher gelesenen
            # Texte erhalten.
        }

        return $strings.ToArray()
    }


    # Zeile und Spalte sind die ersten 4 Bytes jedes Zell-Records.
    hidden static [void] SetCell($sheet, [byte[]]$stream, [int]$dataStart, [string]$text) {
        if ($null -eq $sheet) {
            return
        }

        $row = [System.BitConverter]::ToUInt16($stream, $dataStart)
        $column = [System.BitConverter]::ToUInt16($stream, $dataStart + 2)
        [LegacyExcelContentReader]::PutCell($sheet, $row, $column, $text)
    }


    hidden static [void] PutCell($sheet, [int]$row, [int]$column, [string]$text) {
        if ([string]::IsNullOrWhiteSpace($text)) {
            return
        }

        if (-not $sheet.ContainsKey($row)) {
            $sheet[$row] = [System.Collections.Generic.SortedDictionary[int, string]]::new()
        }

        $sheet[$row][$column] = $text.Trim()
    }


    hidden static [string] FormatSheets([System.Collections.Generic.List[string]]$sheetOrder, [hashtable]$sheets) {
        $lines = [System.Collections.Generic.List[string]]::new()

        foreach ($sheetName in $sheetOrder) {
            $sheet = $sheets[$sheetName]

            if ($null -eq $sheet -or $sheet.Count -eq 0) {
                continue
            }

            $lines.Add($sheetName)

            foreach ($row in $sheet.Values) {
                $lines.Add(($row.Values -join "`t"))
            }

            $lines.Add("")
        }

        return ($lines -join "`n").Trim()
    }


    # RK: komprimierte Zahl. Bit 0: durch 100 teilen, Bit 1: 30-Bit-Ganzzahl,
    # sonst die oberen 30 Bits eines Double.
    static [double] DecodeRk([uint32]$rk) {
        if (($rk -band 0x02) -ne 0) {
            # Die Bits als vorzeichenbehaftet deuten; die arithmetische
            # Verschiebung erhält das Vorzeichen negativer Ganzzahlen. Ein
            # Cast würde über 2^31 fehlschlagen.
            $signed = [System.BitConverter]::ToInt32([System.BitConverter]::GetBytes($rk), 0)
            $value = [double]($signed -shr 2)
        }
        else {
            $bits = [long]($rk -band 0xFFFFFFFC) -shl 32
            $value = [System.BitConverter]::Int64BitsToDouble($bits)
        }

        if (($rk -band 0x01) -ne 0) {
            $value = $value / 100
        }

        return $value
    }


    static [string] FormatNumber([double]$number) {
        return $number.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }


    hidden static [string] DecodeChars([byte[]]$bytes, [int]$offset, [int]$count, [bool]$isUnicode) {
        if ($isUnicode) {
            return [System.Text.Encoding]::Unicode.GetString($bytes, $offset, [Math]::Min($count * 2, $bytes.Length - $offset))
        }

        return [System.Text.Encoding]::Latin1.GetString($bytes, $offset, [Math]::Min($count, $bytes.Length - $offset))
    }


    hidden static [byte[]] Slice([byte[]]$bytes, [int]$offset, [int]$count) {
        $result = [byte[]]::new([Math]::Max(0, [Math]::Min($count, $bytes.Length - $offset)))
        [System.Array]::Copy($bytes, $offset, $result, 0, $result.Length)

        return $result
    }
}


# Liest BIFF8-Texte, die über CONTINUE-Records hinweg weitergehen können. Wird
# der Zeichenteil eines Textes geteilt, beginnt der nächste Record mit einem
# neuen Flag-Byte, das angibt, ob der Rest 8-Bit oder UTF-16 ist.
class BiffStringReader {

    hidden [System.Collections.Generic.List[byte[]]]$_segments
    hidden [int]$_segment = 0
    hidden [int]$_offset = 0


    BiffStringReader([System.Collections.Generic.List[byte[]]]$segments) {
        $this._segments = $segments
    }


    [byte] ReadByte() {
        while ($this._offset -ge $this._segments[$this._segment].Length) {
            $this._NextSegment()
        }

        $value = $this._segments[$this._segment][$this._offset]
        $this._offset++

        return $value
    }


    [int] ReadUInt16() {
        $low = $this.ReadByte()
        $high = $this.ReadByte()

        return [int]$low -bor ([int]$high -shl 8)
    }


    [int] ReadInt32() {
        $low = $this.ReadUInt16()
        $high = $this.ReadUInt16()

        return [int]([long]$low -bor ([long]$high -shl 16))
    }


    [void] Skip([long]$count) {
        for ($i = 0; $i -lt $count; $i++) {
            [void]$this.ReadByte()
        }
    }


    # XLUnicodeRichExtendedString (SST) oder XLUnicodeString (LABEL, STRING).
    [string] ReadString([bool]$isExtended) {
        $charCount = $this.ReadUInt16()
        $flags = $this.ReadByte()
        $isUnicode = ($flags -band 0x01) -ne 0

        $runCount = 0
        $extendedSize = 0

        if ($isExtended -and ($flags -band 0x08) -ne 0) {
            $runCount = $this.ReadUInt16()
        }

        if ($isExtended -and ($flags -band 0x04) -ne 0) {
            $extendedSize = $this.ReadInt32()
        }

        $builder = [System.Text.StringBuilder]::new($charCount)
        $remaining = $charCount

        while ($remaining -gt 0) {
            # Die Zeichen gehen im nächsten Record mit einem neuen Flag-Byte
            # weiter.
            if ($this._offset -ge $this._segments[$this._segment].Length) {
                $this._NextSegment()
                $isUnicode = ($this._segments[$this._segment][$this._offset] -band 0x01) -ne 0
                $this._offset++
            }

            $current = $this._segments[$this._segment]
            $bytesPerChar = if ($isUnicode) { 2 } else { 1 }
            $available = [int][Math]::Floor(($current.Length - $this._offset) / $bytesPerChar)
            $chunk = [Math]::Min($remaining, $available)

            if ($chunk -le 0) {
                # Beschädigte Daten: ein einzelnes Byte übrig in einem
                # UTF-16-Abschnitt.
                $this._offset = $current.Length
                continue
            }

            if ($isUnicode) {
                [void]$builder.Append([System.Text.Encoding]::Unicode.GetString($current, $this._offset, $chunk * 2))
            }
            else {
                [void]$builder.Append([System.Text.Encoding]::Latin1.GetString($current, $this._offset, $chunk))
            }

            $this._offset += $chunk * $bytesPerChar
            $remaining -= $chunk
        }

        # Formatierungsläufe und Lesehilfen werden nicht benötigt.
        $this.Skip($runCount * 4 + $extendedSize)

        return $builder.ToString()
    }


    hidden [void] _NextSegment() {
        if ($this._segment + 1 -ge $this._segments.Count) {
            throw "Unexpected end of BIFF data."
        }

        $this._segment++
        $this._offset = 0
    }
}

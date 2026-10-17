using module "../ContentReader.psm1"
using module "../Shared/CompoundFile.psm1"

#requires -Version 7.2


# =============================================================================
# READER FÜR ALTE WORD-DATEIEN (.doc, Word 97-2003)
# =============================================================================

# Liest den Text binärer Word-Dokumente mit einem eigenen Parser (MS-DOC).
# Die Datei ist eine OLE-Verbunddatei (siehe Shared/CompoundFile.psm1) mit:
#   - "WordDocument"          Stream, der mit dem FIB (File Information Block)
#                             beginnt; dieser enthält Positionen im Tabellen-
#                             Stream
#   - "0Table" oder "1Table"  Tabellen-Stream; ein Flag im FIB sagt, welcher
#
# Der Text ist nicht am Stück gespeichert. Die "Piece Table" (in der
# CLX-Struktur des Tabellen-Streams) listet die Textstücke in Reihenfolge:
#   - Zeichenpositionen: n+1 Zahlen, Stück i umfasst [cp(i), cp(i+1))
#   - Stückbeschreibungen: je 8 Bytes, Bytes 2-5 enthalten die Dateiposition
#     fc. Ist Bit 30 von fc gesetzt, ist das Stück 8-Bit (Windows-1252) an
#     Position fc/2, sonst UTF-16 an Position fc.
#
# Sonderzeichen im Text:
#   \r Absatzende, \v Zeilenumbruch, \f Seitenumbruch, 0x07 Ende einer
#   Tabellenzelle, 0x13 Feldanfang, 0x14 Feldtrenner, 0x15 Feldende. Ein Feld
#   sieht so aus: 0x13 HYPERLINK "url" 0x14 angezeigter Text 0x15; nur der
#   angezeigte Text bleibt erhalten.
#
# Verschlüsselte Dokumente und Dateien von Word 6/95 liefern keinen Text.
class LegacyWordContentReader : ContentReader {

    LegacyWordContentReader() {
        $this.Description = "Word 97-2003 documents"
        $this.Extensions = @(".doc", ".dot")
    }


    [string] ReadContent([System.IO.FileInfo]$file) {
        $data = $this.ReadFileBytes($file)

        # Sperrdateien und andere ".doc"-Dateien (z. B. Klartext) werden
        # übersprungen.
        if (-not [CompoundFile]::IsCompoundFile($data)) {
            return ""
        }

        $compoundFile = [CompoundFile]::new($data)
        $root = $compoundFile.GetRoot()
        $wordEntry = $compoundFile.FindChild($root, "WordDocument")

        if ($null -eq $wordEntry) {
            return ""
        }

        $wordStream = $compoundFile.ReadStream($wordEntry)

        # FIB-Grundteil: wIdent 0xA5EC, nFib (Version), Flags.
        if ($wordStream.Length -lt 0x200 -or [System.BitConverter]::ToUInt16($wordStream, 0) -ne 0xA5EC) {
            return ""
        }

        $version = [System.BitConverter]::ToUInt16($wordStream, 2)
        $flags = [System.BitConverter]::ToUInt16($wordStream, 0x0A)

        # Word 97 hat nFib 0x00C1; ältere Versionen haben einen anderen Aufbau.
        $isEncrypted = ($flags -band 0x0100) -ne 0

        if ($version -lt 0x00C1 -or $isEncrypted) {
            return ""
        }

        $tableName = if (($flags -band 0x0200) -ne 0) { "1Table" } else { "0Table" }
        $tableEntry = $compoundFile.FindChild($root, $tableName)

        if ($null -eq $tableEntry) {
            return ""
        }

        $tableStream = $compoundFile.ReadStream($tableEntry)

        $clxOffset = [LegacyWordContentReader]::GetClxPosition($wordStream)
        $fcClx = [System.BitConverter]::ToInt32($wordStream, $clxOffset)
        $lcbClx = [System.BitConverter]::ToInt32($wordStream, $clxOffset + 4)

        if ($fcClx -lt 0 -or $lcbClx -le 0 -or $fcClx + $lcbClx -gt $tableStream.Length) {
            throw "Piece table is outside the table stream."
        }

        $rawText = [LegacyWordContentReader]::ReadPieces($wordStream, $tableStream, $fcClx, $lcbClx)

        return [LegacyWordContentReader]::CleanText($rawText)
    }


    # Position von fcClx im FIB. Vor der Positionstabelle (FibRgFcLcb) liegen
    # Blöcke mit variabler Größe; fcClx ist ihr 34. Eintrag (Index 33), jeder
    # Eintrag ist 8 Bytes groß (fc + lcb).
    static [int] GetClxPosition([byte[]]$wordStream) {
        $position = 32

        $wordCount = [System.BitConverter]::ToUInt16($wordStream, $position)
        $position += 2 + $wordCount * 2

        $longCount = [System.BitConverter]::ToUInt16($wordStream, $position)
        $position += 2 + $longCount * 4

        # cbRgFcLcb (Anzahl der Einträge) überspringen.
        $position += 2

        return $position + 33 * 8
    }


    static [string] ReadPieces([byte[]]$wordStream, [byte[]]$tableStream, [int]$fcClx, [int]$lcbClx) {
        $position = $fcClx
        $end = $fcClx + $lcbClx

        # CLX = optionale Eigenschaftsblöcke (0x01), gefolgt von der Piece
        # Table (0x02).
        while ($position -lt $end -and $tableStream[$position] -eq 0x01) {
            $size = [System.BitConverter]::ToInt16($tableStream, $position + 1)
            $position += 3 + $size
        }

        if ($position -ge $end -or $tableStream[$position] -ne 0x02) {
            throw "Piece table not found."
        }

        $pieceTableSize = [System.BitConverter]::ToInt32($tableStream, $position + 1)
        $pieceTable = $position + 5

        # n+1 Zeichenpositionen (4 Bytes) und n Beschreibungen (8 Bytes).
        $pieceCount = [int](($pieceTableSize - 4) / 12)
        $descriptorStart = $pieceTable + ($pieceCount + 1) * 4

        $builder = [System.Text.StringBuilder]::new()
        $windows1252 = [System.Text.Encoding]::GetEncoding(1252)

        for ($piece = 0; $piece -lt $pieceCount; $piece++) {
            $cpStart = [System.BitConverter]::ToInt32($tableStream, $pieceTable + $piece * 4)
            $cpEnd = [System.BitConverter]::ToInt32($tableStream, $pieceTable + ($piece + 1) * 4)
            $charCount = $cpEnd - $cpStart

            $fcValue = [System.BitConverter]::ToUInt32($tableStream, $descriptorStart + $piece * 8 + 2)
            $isCompressed = ($fcValue -band 0x40000000) -ne 0
            $fc = [long]($fcValue -band 0x3FFFFFFF)

            if ($charCount -le 0) {
                continue
            }

            if ($isCompressed) {
                $offset = [long]($fc / 2)
                $byteCount = $charCount
            }
            else {
                $offset = $fc
                $byteCount = $charCount * 2
            }

            if ($offset + $byteCount -gt $wordStream.Length) {
                throw "Text piece $piece is outside the WordDocument stream."
            }

            if ($isCompressed) {
                [void]$builder.Append($windows1252.GetString($wordStream, $offset, $byteCount))
            }
            else {
                [void]$builder.Append([System.Text.Encoding]::Unicode.GetString($wordStream, $offset, $byteCount))
            }
        }

        return $builder.ToString()
    }


    # Ersetzt die Steuerzeichen von Word und behält bei Feldern nur den
    # angezeigten Text.
    static [string] CleanText([string]$rawText) {
        $builder = [System.Text.StringBuilder]::new($rawText.Length)

        # Ein Eintrag pro offenem Feld: $true, solange man im
        # Anweisungsteil ist.
        $fields = [System.Collections.Generic.Stack[bool]]::new()

        foreach ($char in $rawText.ToCharArray()) {
            $code = [int]$char

            if ($code -eq 0x13) {
                $fields.Push($true)
                continue
            }

            if ($code -eq 0x14) {
                if ($fields.Count -gt 0) {
                    [void]$fields.Pop()
                    $fields.Push($false)
                }

                continue
            }

            if ($code -eq 0x15) {
                if ($fields.Count -gt 0) {
                    [void]$fields.Pop()
                }

                continue
            }

            # Innerhalb einer Feldanweisung (z. B. HYPERLINK "url").
            if ($fields.Count -gt 0 -and $fields.Peek()) {
                continue
            }

            switch ($code) {
                0x0D { [void]$builder.Append("`n") }
                0x0B { [void]$builder.Append("`n") }
                0x0C { [void]$builder.Append("`n") }
                0x07 { [void]$builder.Append("`t") }
                0x09 { [void]$builder.Append("`t") }
                0x1E { [void]$builder.Append("-") }
                0xA0 { [void]$builder.Append(" ") }
                default {
                    # Andere Steuerzeichen markieren Bilder,
                    # Fußnotenverweise usw. und haben keinen sichtbaren Text.
                    if ($code -ge 0x20) {
                        [void]$builder.Append($char)
                    }
                }
            }
        }

        $text = [regex]::Replace($builder.ToString(), "[ \t]*\n[ \t]*", "`n")
        $text = [regex]::Replace($text, "\n{3,}", "`n`n")

        return $text.Trim()
    }
}

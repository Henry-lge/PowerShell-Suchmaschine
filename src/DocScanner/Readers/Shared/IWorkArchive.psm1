#requires -Version 7.2


# =============================================================================
# APPLE-IWORK-ARCHIVE (.iwa)
# =============================================================================

# Pages, Numbers und Keynote (seit 2013) speichern ihren Inhalt in
# Index/*.iwa-Dateien innerhalb des ZIP. Eine .iwa-Datei ist:
#   1. eine Liste von Blöcken: 1 Byte Typ (0), 3 Bytes Länge,
#      Snappy-komprimierte Daten (schnelle Komprimierung von Google, siehe
#      [Snappy])
#   2. entpackt: eine Liste von Objekten, jeweils geschrieben als
#        Varint-Länge + ArchiveInfo (Protobuf) + die Nutzdaten der Nachrichten
#      ArchiveInfo listet jede Nachricht mit ihrer Typnummer und Länge.
#   3. Die Nutzdaten sind Protobuf-Nachrichten (siehe [ProtoReader]). Die
#      Typnummer gibt an, welche Nachricht es ist, z. B. 2001 = Textspeicher.
# Protobuf und Snappy sind hier implementiert, es wird keine Bibliothek
# benötigt.


# Ein Feld einer Protobuf-Nachricht. Felder mit Längenangabe (Texte,
# verschachtelte Nachrichten) merken sich ihre Position im Puffer, statt
# kopiert zu werden.
class ProtoField {
    [int]$Number
    [int]$WireType
    [long]$Value
    [int]$Offset
    [int]$Length
}


class ProtoReader {

    # Liest einen Varint (7 Bits pro Byte, oberstes Bit = es folgen weitere
    # Bytes). $position ist ein Array mit einem Element, das als Referenz
    # dient.
    static [long] ReadVarint([byte[]]$buffer, [int[]]$position) {
        $result = [long]0
        $shift = 0

        while ($true) {
            if ($position[0] -ge $buffer.Length) {
                throw "Unexpected end of Protobuf data."
            }

            $current = $buffer[$position[0]]
            $position[0]++
            $result = $result -bor ([long]($current -band 0x7F) -shl $shift)

            if (($current -band 0x80) -eq 0) {
                return $result
            }

            $shift += 7

            if ($shift -gt 63) {
                throw "Invalid varint."
            }
        }

        return $result
    }


    # Alle Felder einer Nachricht in [offset, offset + length).
    static [ProtoField[]] ReadFields([byte[]]$buffer, [int]$offset, [int]$length) {
        $fields = [System.Collections.Generic.List[ProtoField]]::new()
        $position = [int[]]@($offset)
        $end = $offset + $length

        while ($position[0] -lt $end) {
            $key = [ProtoReader]::ReadVarint($buffer, $position)
            $field = [ProtoField]::new()
            $field.Number = [int]($key -shr 3)
            $field.WireType = [int]($key -band 0x07)

            switch ($field.WireType) {
                0 { $field.Value = [ProtoReader]::ReadVarint($buffer, $position) }
                1 { $position[0] += 8 }
                2 {
                    $field.Length = [int][ProtoReader]::ReadVarint($buffer, $position)
                    $field.Offset = $position[0]
                    $position[0] += $field.Length
                }
                5 { $position[0] += 4 }
                default { throw "Unsupported Protobuf wire type $($field.WireType)." }
            }

            if ($position[0] -gt $end) {
                throw "Protobuf field exceeds its message."
            }

            $fields.Add($field)
        }

        return $fields.ToArray()
    }


    static [string] GetString([byte[]]$buffer, [ProtoField]$field) {
        return [System.Text.Encoding]::UTF8.GetString($buffer, $field.Offset, $field.Length)
    }
}


class Snappy {

    # Entpackt einen rohen Snappy-Block (ohne Rahmenformat).
    static [byte[]] Decompress([byte[]]$source, [int]$offset, [int]$length) {
        $position = [int[]]@($offset)
        $end = $offset + $length
        $outputLength = [int][ProtoReader]::ReadVarint($source, $position)
        $output = [byte[]]::new($outputLength)
        $written = 0

        while ($position[0] -lt $end) {
            # Als [int]: Das Verschieben eines [byte] bleibt in PowerShell ein
            # Byte und läuft über (z. B. ergäbe 7 -shl 8 den Wert 0).
            $tag = [int]$source[$position[0]]
            $position[0]++

            $tagType = $tag -band 0x03

            # Literal: Bytes aus der Eingabe kopieren. Die Länge steht im Tag
            # oder bei längeren Literalen in 1-4 zusätzlichen Bytes.
            if ($tagType -eq 0) {
                $literalLength = ($tag -shr 2) + 1

                if ($literalLength -gt 60) {
                    $extraBytes = $literalLength - 60
                    $literalLength = 0

                    for ($i = 0; $i -lt $extraBytes; $i++) {
                        $literalLength = $literalLength -bor ([int]$source[$position[0] + $i] -shl (8 * $i))
                    }

                    $literalLength++
                    $position[0] += $extraBytes
                }

                if ($position[0] + $literalLength -gt $end -or $written + $literalLength -gt $outputLength) {
                    throw "Invalid Snappy data."
                }

                [System.Array]::Copy($source, $position[0], $output, $written, $literalLength)
                $position[0] += $literalLength
                $written += $literalLength
                continue
            }

            # Kopie: frühere Ausgabe wiederholen; die Größe der Positionsangabe
            # hängt vom Typ ab.
            $copyLength = 0
            $copyOffset = 0

            if ($tagType -eq 1) {
                $copyLength = (($tag -shr 2) -band 0x07) + 4
                $copyOffset = (($tag -shr 5) -shl 8) -bor $source[$position[0]]
                $position[0] += 1
            }
            elseif ($tagType -eq 2) {
                $copyLength = ($tag -shr 2) + 1
                $copyOffset = [System.BitConverter]::ToUInt16($source, $position[0])
                $position[0] += 2
            }
            else {
                $copyLength = ($tag -shr 2) + 1
                $copyOffset = [System.BitConverter]::ToInt32($source, $position[0])
                $position[0] += 4
            }

            if ($copyOffset -le 0 -or $copyOffset -gt $written -or $written + $copyLength -gt $outputLength) {
                throw "Invalid Snappy data."
            }

            # Kopien dürfen ihre eigene Ausgabe überlappen (wiederholte
            # Muster), deshalb erfolgen sie in Schritten von höchstens
            # $copyOffset Bytes.
            $remaining = $copyLength

            while ($remaining -gt 0) {
                $step = [Math]::Min($remaining, $copyOffset)
                [System.Array]::Copy($output, $written - $copyOffset, $output, $written, $step)
                $written += $step
                $remaining -= $step
            }
        }

        return $output
    }
}


# Eine Nachricht innerhalb einer .iwa-Datei.
class IWorkMessage {
    [int]$Type
    [int]$Offset
    [int]$Length
}


class IWorkArchive {

    # Entpackt alle Blöcke einer .iwa-Datei in einen Puffer.
    static [byte[]] Decompress([byte[]]$iwa) {
        $output = [System.IO.MemoryStream]::new()
        $position = 0

        while ($position + 4 -le $iwa.Length) {
            $chunkLength = [int]$iwa[$position + 1] -bor ([int]$iwa[$position + 2] -shl 8) -bor ([int]$iwa[$position + 3] -shl 16)
            $chunkStart = $position + 4

            if ($iwa[$position] -ne 0 -or $chunkStart + $chunkLength -gt $iwa.Length) {
                throw "Invalid IWA chunk."
            }

            $chunk = [Snappy]::Decompress($iwa, $chunkStart, $chunkLength)
            $output.Write($chunk, 0, $chunk.Length)
            $position = $chunkStart + $chunkLength
        }

        return $output.ToArray()
    }


    # Listet alle Nachrichten (Typ und Position) eines entpackten
    # .iwa-Puffers auf.
    static [IWorkMessage[]] ReadMessages([byte[]]$buffer) {
        $messages = [System.Collections.Generic.List[IWorkMessage]]::new()
        $position = [int[]]@(0)

        while ($position[0] -lt $buffer.Length) {
            $infoLength = [int][ProtoReader]::ReadVarint($buffer, $position)
            $infoOffset = $position[0]
            $payloadPosition = $infoOffset + $infoLength

            # ArchiveInfo Feld 2 = MessageInfo: 1 = Typ, 3 = Länge.
            foreach ($infoField in [ProtoReader]::ReadFields($buffer, $infoOffset, $infoLength)) {
                if ($infoField.Number -ne 2 -or $infoField.WireType -ne 2) {
                    continue
                }

                $message = [IWorkMessage]::new()

                foreach ($messageField in [ProtoReader]::ReadFields($buffer, $infoField.Offset, $infoField.Length)) {
                    if ($messageField.Number -eq 1) { $message.Type = [int]$messageField.Value }
                    if ($messageField.Number -eq 3) { $message.Length = [int]$messageField.Value }
                }

                $message.Offset = $payloadPosition
                $payloadPosition += $message.Length

                if ($payloadPosition -gt $buffer.Length) {
                    throw "IWA message exceeds the archive."
                }

                $messages.Add($message)
            }

            $position[0] = $payloadPosition
        }

        return $messages.ToArray()
    }
}

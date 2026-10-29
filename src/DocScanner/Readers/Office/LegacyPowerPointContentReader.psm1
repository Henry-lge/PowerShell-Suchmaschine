using module "../ContentReader.psm1"
using module "../Shared/CompoundFile.psm1"

#requires -Version 7.2


# =============================================================================
# READER FÜR ALTE POWERPOINT-DATEIEN (.ppt, PowerPoint 97-2003)
# =============================================================================

# Liest den Text binärer PowerPoint-Präsentationen mit einem eigenen Parser
# (MS-PPT). Die Datei ist eine OLE-Verbunddatei (siehe
# Shared/CompoundFile.psm1) mit dem Stream "PowerPoint Document".
#
# Der Stream ist ein Baum aus Records mit einem 8 Byte großen Kopf:
#   2 Bytes  Version (untere 4 Bits) und Instanz; Version 0xF = Container
#   2 Bytes  Record-Typ
#   4 Bytes  Länge der Daten
# Container enthalten weitere Records, Atome enthalten Daten. Text steht in:
#   - TextCharsAtom (0x0FA0)   UTF-16
#   - TextBytesAtom (0x0FA8)   8 Bit pro Zeichen (Latin-1)
# Im Text beendet \r einen Absatz und \v ist ein Zeilenumbruch.
#
# Die Masterfolien (MainMaster 0x03F8) enthalten nur Platzhaltertexte wie
# "Click to edit Master title style" und werden übersprungen.
# Verschlüsselte Präsentationen liefern keinen Text.
class LegacyPowerPointContentReader : ContentReader {

    hidden static [int]$TextCharsAtom = 0x0FA0
    hidden static [int]$TextBytesAtom = 0x0FA8
    hidden static [int]$MainMaster = 0x03F8


    LegacyPowerPointContentReader() {
        $this.Description = "PowerPoint 97-2003 presentations"
        $this.Extensions = @(".ppt", ".pps", ".pot")
    }


    [string] ReadContent([System.IO.FileInfo]$file) {
        $data = $this.ReadFileBytes($file)

        if (-not [CompoundFile]::IsCompoundFile($data)) {
            return ""
        }

        $compoundFile = [CompoundFile]::new($data)
        $root = $compoundFile.GetRoot()

        # Verschlüsselte Präsentationen speichern ihren Inhalt in einem
        # verschlüsselten Stream.
        if ($null -ne $compoundFile.FindChild($root, "EncryptedSummary")) {
            return ""
        }

        $documentEntry = $compoundFile.FindChild($root, "PowerPoint Document")

        if ($null -eq $documentEntry) {
            return ""
        }

        return [LegacyPowerPointContentReader]::ExtractText($compoundFile.ReadStream($documentEntry))
    }


    static [string] ExtractText([byte[]]$stream) {
        $texts = [System.Collections.Generic.List[string]]::new()
        $position = 0

        # In Container wird einfach hinter ihrem Kopf weitergelesen, weil
        # ihre Kinder direkt folgen. Atome werden nach dem Lesen als Ganzes
        # übersprungen.
        while ($position + 8 -le $stream.Length) {
            $versionAndInstance = [System.BitConverter]::ToUInt16($stream, $position)
            $recordType = [System.BitConverter]::ToUInt16($stream, $position + 2)
            $length = [System.BitConverter]::ToUInt32($stream, $position + 4)
            $dataStart = $position + 8

            if ($dataStart + $length -gt $stream.Length) {
                break
            }

            $isContainer = ($versionAndInstance -band 0x000F) -eq 0x000F

            if ($recordType -eq [LegacyPowerPointContentReader]::MainMaster) {
                $position = $dataStart + $length
                continue
            }

            if ($isContainer) {
                $position = $dataStart
                continue
            }

            $text = $null

            if ($recordType -eq [LegacyPowerPointContentReader]::TextCharsAtom) {
                $text = [System.Text.Encoding]::Unicode.GetString($stream, $dataStart, $length)
            }
            elseif ($recordType -eq [LegacyPowerPointContentReader]::TextBytesAtom) {
                $text = [System.Text.Encoding]::Latin1.GetString($stream, $dataStart, $length)
            }

            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $texts.Add($text.Replace("`r", "`n").Replace("`v", "`n").Trim())
            }

            $position = $dataStart + $length
        }

        $result = [regex]::Replace(($texts -join "`n"), "[ \t]*\n[ \t]*", "`n")

        return [regex]::Replace($result, "\n{3,}", "`n`n").Trim()
    }
}

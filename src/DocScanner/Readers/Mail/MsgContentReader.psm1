using module "../ContentReader.psm1"
using module "../Shared/CompoundFile.psm1"

#requires -Version 7.2


# =============================================================================
# READER FÜR OUTLOOK-MSG
# =============================================================================

# Liest Betreff, Absender, Empfänger, Text und Anhangnamen von Outlook-Mails.
# Eine .msg-Datei ist eine OLE-Verbunddatei; jede Eigenschaft ist ein Stream
# mit dem Namen "__substg1.0_" + Eigenschafts-ID + Typ, z. B.
#   __substg1.0_0037001F   Betreff, Typ 001F = UTF-16-Text
#   __substg1.0_0037001E   Betreff, Typ 001E = 8-Bit-Text (ältere Dateien)
# Anhänge sind Storages "__attach_version1.0_#00000000" mit eigenen
# Eigenschafts-Streams. Es wird weder Outlook noch eine zusätzliche
# Bibliothek benötigt.
#
# Auch andere Programme verwenden ".msg" (z. B. Tcl-Sprachkataloge); Dateien
# ohne die Signatur einer Verbunddatei liefern einen leeren Text.
class MsgContentReader : ContentReader {

    # Eigenschafts-IDs (hexadezimal) der Werte, die ausgelesen werden.
    hidden static [string]$SubjectId = "0037"
    hidden static [string]$SenderNameId = "0C1A"
    hidden static [string]$SenderEmailId = "0C1F"
    hidden static [string]$DisplayToId = "0E04"
    hidden static [string]$DisplayCcId = "0E03"
    hidden static [string]$BodyId = "1000"
    hidden static [string]$HtmlBodyId = "1013"
    hidden static [string]$AttachLongFilenameId = "3707"
    hidden static [string]$AttachFilenameId = "3704"


    MsgContentReader() {
        $this.Description = "Outlook e-mails"
        $this.Extensions = @(".msg")
    }


    [string] ReadContent([System.IO.FileInfo]$file) {
        $data = $this.ReadFileBytes($file)

        if (-not [CompoundFile]::IsCompoundFile($data)) {
            return ""
        }

        $compoundFile = [CompoundFile]::new($data)
        $root = $compoundFile.GetRoot()

        $lines = [System.Collections.Generic.List[string]]::new()

        $this._AddLine($lines, "Subject", $this._GetText($compoundFile, $root, [MsgContentReader]::SubjectId))

        $sender = $this._GetText($compoundFile, $root, [MsgContentReader]::SenderNameId)
        $senderEmail = $this._GetText($compoundFile, $root, [MsgContentReader]::SenderEmailId)

        if (-not [string]::IsNullOrEmpty($senderEmail) -and $senderEmail -ne $sender) {
            $sender = "$sender <$senderEmail>".Trim()
        }

        $this._AddLine($lines, "From", $sender)
        $this._AddLine($lines, "To", $this._GetText($compoundFile, $root, [MsgContentReader]::DisplayToId))
        $this._AddLine($lines, "Cc", $this._GetText($compoundFile, $root, [MsgContentReader]::DisplayCcId))
        $this._AddLine($lines, "Attachments", ($this._GetAttachmentNames($compoundFile) -join ", "))

        $body = $this._GetText($compoundFile, $root, [MsgContentReader]::BodyId)

        # Manche Mails haben nur einen HTML-Inhalt (binäre Eigenschaft 0102).
        if ([string]::IsNullOrWhiteSpace($body)) {
            $htmlStream = $compoundFile.FindChild($root, "__substg1.0_$([MsgContentReader]::HtmlBodyId)0102")

            if ($null -ne $htmlStream) {
                $html = [System.Text.Encoding]::UTF8.GetString($compoundFile.ReadStream($htmlStream))
                $body = $this.ConvertHtmlToText($html)
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($body)) {
            $lines.Add("")
            $lines.Add($body.Trim())
        }

        return $lines -join "`n"
    }


    # Text-Eigenschaft eines Storages; prüft die UTF-16- und die 8-Bit-Variante.
    hidden [string] _GetText(
        [CompoundFile]$compoundFile,
        [CompoundFileEntry]$storage,
        [string]$propertyId
    ) {
        $unicode = $compoundFile.FindChild($storage, "__substg1.0_${propertyId}001F")

        if ($null -ne $unicode) {
            $text = [System.Text.Encoding]::Unicode.GetString($compoundFile.ReadStream($unicode))
            return $text.TrimEnd([char]0).Trim()
        }

        $ansi = $compoundFile.FindChild($storage, "__substg1.0_${propertyId}001E")

        if ($null -ne $ansi) {
            $text = [System.Text.Encoding]::GetEncoding(1252).GetString($compoundFile.ReadStream($ansi))
            return $text.TrimEnd([char]0).Trim()
        }

        return ""
    }


    hidden [string[]] _GetAttachmentNames([CompoundFile]$compoundFile) {
        $names = [System.Collections.Generic.List[string]]::new()

        foreach ($child in $compoundFile.GetChildren($compoundFile.GetRoot())) {
            if (-not $child.IsStorage() -or -not $child.Name.StartsWith("__attach_version1.0_")) {
                continue
            }

            $name = $this._GetText($compoundFile, $child, [MsgContentReader]::AttachLongFilenameId)

            if ([string]::IsNullOrEmpty($name)) {
                $name = $this._GetText($compoundFile, $child, [MsgContentReader]::AttachFilenameId)
            }

            if (-not [string]::IsNullOrEmpty($name)) {
                $names.Add($name)
            }
        }

        return $names.ToArray()
    }


    hidden [void] _AddLine(
        [System.Collections.Generic.List[string]]$lines,
        [string]$label,
        [string]$value
    ) {
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $lines.Add("${label}: $value")
        }
    }
}

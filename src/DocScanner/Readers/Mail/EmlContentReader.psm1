using module "../ContentReader.psm1"

#requires -Version 7.2


# =============================================================================
# READER FÜR EML
# =============================================================================

# Liest Betreff, Absender, Empfänger, Datum, Text und Anhangnamen von E-Mails
# im MIME-Format (Thunderbird, Apple Mail, Outlook "Speichern unter"). Es wird
# kein zusätzliches Tool benötigt.
#
# Aufbau einer MIME-Nachricht:
#   - Kopfzeilen "Name: Wert" bis zur ersten leeren Zeile. Lange Werte gehen
#     in Zeilen weiter, die mit einem Leerzeichen beginnen. Text außerhalb
#     von ASCII steht als "encoded words" darin: =?UTF-8?B?w6Q=?= (Base64)
#     oder =?UTF-8?Q?=C3=A4?=.
#   - Der Inhalt ist entweder Text oder, bei "multipart/...", mehrere Teile,
#     getrennt durch "--" + Boundary. Jeder Teil hat eigene Kopfzeilen.
#   - Content-Transfer-Encoding: base64, quoted-printable (=C3=A4 ist ein
#     Byte, "=" am Zeilenende verbindet Zeilen) oder einfaches 7bit/8bit.
#
# Die Nachricht wird zuerst als Latin-1 dekodiert, das jedes Byte auf genau
# ein Zeichen abbildet. Jeder Textteil wird wieder in Bytes umgewandelt und
# mit dem Zeichensatz dekodiert, den er angibt.
class EmlContentReader : ContentReader {

    # Tiefer verschachtelte Multiparts werden ignoriert (Schutz vor defekten
    # oder bösartigen Mails).
    hidden static [int]$MaxDepth = 20


    EmlContentReader() {
        $this.Description = "E-mails (MIME)"
        $this.Extensions = @(".eml")
    }


    [string] ReadContent([System.IO.FileInfo]$file) {
        $raw = [System.Text.Encoding]::Latin1.GetString(
            $this.ReadFileBytes($file)
        )

        $mail = [MailParts]::new()
        $this._ParsePart($raw, $mail, 0)

        $headers = [EmlContentReader]::ParseHeaders([EmlContentReader]::SplitPart($raw)[0])
        $lines = [System.Collections.Generic.List[string]]::new()

        foreach ($name in @("Subject", "From", "To", "Cc", "Date")) {
            $value = [EmlContentReader]::DecodeHeader($headers[$name])

            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $lines.Add("${name}: $value")
            }
        }

        if ($mail.Attachments.Count -gt 0) {
            $lines.Add("Attachments: " + ($mail.Attachments -join ", "))
        }

        # Den Klartext bevorzugen; sonst die HTML-Version verwenden.
        $body = ($mail.PlainTexts -join "`n`n").Trim()

        if ($body.Length -eq 0) {
            $body = (
                $mail.HtmlTexts | ForEach-Object { $this.ConvertHtmlToText($_) }
            ) -join "`n`n"
        }

        if (-not [string]::IsNullOrWhiteSpace($body)) {
            $lines.Add("")
            $lines.Add($body.Trim())
        }

        return $lines -join "`n"
    }


    # =============================================================================
    # MIME-STRUKTUR
    # =============================================================================

    hidden [void] _ParsePart([string]$raw, [MailParts]$mail, [int]$depth) {
        if ($depth -gt [EmlContentReader]::MaxDepth) {
            return
        }

        $split = [EmlContentReader]::SplitPart($raw)
        $headers = [EmlContentReader]::ParseHeaders($split[0])
        $partBody = $split[1]

        $contentType = $headers["Content-Type"]

        if ([string]::IsNullOrWhiteSpace($contentType)) {
            $contentType = "text/plain"
        }

        $mediaType = $contentType.Split(";")[0].Trim().ToLowerInvariant()
        $parameters = [EmlContentReader]::ParseParameters($contentType)

        if ($mediaType.StartsWith("multipart/") -and $parameters.ContainsKey("boundary")) {
            foreach ($subPart in [EmlContentReader]::SplitMultipart($partBody, $parameters["boundary"])) {
                $this._ParsePart($subPart, $mail, $depth + 1)
            }

            return
        }

        # Weitergeleitete Mail als Anhang: wie eine Nachricht lesen.
        if ($mediaType -eq "message/rfc822") {
            $this._ParsePart($partBody, $mail, $depth + 1)
            return
        }

        $disposition = $headers["Content-Disposition"]
        $fileName = [EmlContentReader]::GetFileName($disposition, $parameters)
        $isAttachment = (
            ($null -ne $disposition -and $disposition.TrimStart().StartsWith("attachment", [System.StringComparison]::OrdinalIgnoreCase)) -or
            (-not [string]::IsNullOrEmpty($fileName) -and -not $mediaType.StartsWith("text/"))
        )

        if (-not [string]::IsNullOrEmpty($fileName)) {
            $mail.Attachments.Add($fileName)
        }

        if ($isAttachment) {
            return
        }

        if ($mediaType -eq "text/plain" -or $mediaType -eq "text/html") {
            $bytes = [EmlContentReader]::DecodeTransfer($partBody, $headers["Content-Transfer-Encoding"])
            $text = [EmlContentReader]::DecodeBytes($bytes, $parameters["charset"])

            if ($mediaType -eq "text/plain") {
                $mail.PlainTexts.Add($text)
            }
            else {
                $mail.HtmlTexts.Add($text)
            }
        }
    }


    # Gibt @(Kopftext, Inhaltstext) zurück, getrennt an der ersten leeren Zeile.
    static [string[]] SplitPart([string]$raw) {
        $match = [regex]::Match($raw, "\r?\n\r?\n")

        if (-not $match.Success) {
            return @($raw, "")
        }

        return @(
            $raw.Substring(0, $match.Index),
            $raw.Substring($match.Index + $match.Length)
        )
    }


    # Namen von Kopfzeilen unterscheiden nicht zwischen Groß- und
    # Kleinschreibung; das erste Vorkommen gilt.
    static [hashtable] ParseHeaders([string]$headerText) {
        $headers = @{}

        # Umbrochene Zeilen setzen die vorherige Kopfzeile fort.
        $unfolded = [regex]::Replace($headerText, "\r?\n[ \t]+", " ")

        foreach ($line in $unfolded -split "\r?\n") {
            $colon = $line.IndexOf(":")

            if ($colon -le 0) {
                continue
            }

            $name = $line.Substring(0, $colon).Trim()

            if (-not $headers.ContainsKey($name)) {
                $headers[$name] = $line.Substring($colon + 1).Trim()
            }
        }

        return $headers
    }


    # Parameter eines Kopfzeilenwerts wie: text/plain; charset="utf-8"
    static [hashtable] ParseParameters([string]$headerValue) {
        $parameters = @{}

        if ([string]::IsNullOrEmpty($headerValue)) {
            return $parameters
        }

        $pattern = ';\s*([^=\s;]+)\s*=\s*("([^"]*)"|[^;]*)'

        foreach ($match in [regex]::Matches($headerValue, $pattern)) {
            $name = $match.Groups[1].Value.ToLowerInvariant()
            $value = if ($match.Groups[3].Success) { $match.Groups[3].Value } else { $match.Groups[2].Value.Trim() }

            if (-not $parameters.ContainsKey($name)) {
                $parameters[$name] = $value
            }
        }

        return $parameters
    }


    static [string[]] SplitMultipart([string]$partBody, [string]$boundary) {
        $parts = [System.Collections.Generic.List[string]]::new()
        # Der Lookahead stellt sicher, dass die ganze Zeile das Trennzeichen
        # ist, damit eine Boundary "abc" nicht zu einer verschachtelten
        # Boundary "abc-1" passt.
        $delimiter = "(?m)^--" + [regex]::Escape($boundary) + "(?=--|[ \t]*\r?$)"
        $segments = [regex]::Split($partBody, $delimiter)

        # Der Text vor dem ersten Trennzeichen (Präambel) gehört nicht zur
        # Mail. Ein Abschnitt, der mit "--" beginnt, folgt auf das
        # abschließende Trennzeichen.
        for ($i = 1; $i -lt $segments.Length; $i++) {
            $segment = $segments[$i]

            if ($segment.StartsWith("--")) {
                break
            }

            # Den Rest der Trennzeile entfernen sowie den Zeilenumbruch, der
            # zum nächsten Trennzeichen gehört.
            $lineEnd = $segment.IndexOf("`n")

            if ($lineEnd -lt 0) {
                continue
            }

            $segment = [regex]::Replace($segment.Substring($lineEnd + 1), "\r?\n$", "")

            if (-not [string]::IsNullOrWhiteSpace($segment)) {
                $parts.Add($segment)
            }
        }

        return $parts.ToArray()
    }


    # Dateiname aus Content-Disposition (filename=) oder Content-Type (name=).
    static [string] GetFileName([string]$disposition, [hashtable]$typeParameters) {
        $parameters = [EmlContentReader]::ParseParameters($disposition)

        # RFC 2231: filename*=UTF-8''Gr%C3%B6%C3%9Fe.pdf
        $extended = $parameters["filename*"]

        if (-not [string]::IsNullOrEmpty($extended)) {
            $quote = $extended.IndexOf("''")
            $encoded = if ($quote -ge 0) { $extended.Substring($quote + 2) } else { $extended }

            return [System.Uri]::UnescapeDataString($encoded)
        }

        foreach ($candidate in @($parameters["filename"], $typeParameters["name"])) {
            if (-not [string]::IsNullOrEmpty($candidate)) {
                return [EmlContentReader]::DecodeHeader($candidate)
            }
        }

        return ""
    }


    # =============================================================================
    # DEKODIERUNG
    # =============================================================================

    static [byte[]] DecodeTransfer([string]$partBody, [string]$transferEncoding) {
        $encoding = "$transferEncoding".Trim().ToLowerInvariant()

        if ($encoding -eq "base64") {
            $clean = [regex]::Replace($partBody, "[^A-Za-z0-9+/=]", "")

            try {
                return [System.Convert]::FromBase64String($clean)
            }
            catch {
                return [byte[]]@()
            }
        }

        if ($encoding -eq "quoted-printable") {
            return [EmlContentReader]::DecodeQuotedPrintable($partBody, $false)
        }

        # 7bit, 8bit, binary: Latin-1 wandelt die Zeichen wieder in Bytes um.
        return [System.Text.Encoding]::Latin1.GetBytes($partBody)
    }


    # In Kopfzeilen ($isHeader) steht "_" für ein Leerzeichen.
    static [byte[]] DecodeQuotedPrintable([string]$text, [bool]$isHeader) {
        $bytes = [System.Collections.Generic.List[byte]]::new($text.Length)
        $i = 0

        while ($i -lt $text.Length) {
            $char = $text[$i]

            if ($char -eq "=") {
                if (
                    $i + 2 -lt $text.Length -and
                    [System.Uri]::IsHexDigit($text[$i + 1]) -and
                    [System.Uri]::IsHexDigit($text[$i + 2])
                ) {
                    $bytes.Add([System.Convert]::ToByte($text.Substring($i + 1, 2), 16))
                    $i += 3
                    continue
                }

                # Weicher Zeilenumbruch: "=" am Zeilenende verbindet die Zeilen.
                $softBreak = [regex]::Match($text.Substring($i + 1), "^[ \t]*\r?\n")

                if ($softBreak.Success) {
                    $i += 1 + $softBreak.Length
                    continue
                }
            }

            if ($isHeader -and $char -eq "_") {
                $bytes.Add(0x20)
            }
            else {
                $bytes.Add([byte]([int]$char -band 0xFF))
            }

            $i++
        }

        return $bytes.ToArray()
    }


    # Dekodiert "encoded words" wie =?UTF-8?B?...?= und rohes UTF-8 in
    # Kopfzeilen.
    static [string] DecodeHeader([string]$value) {
        if ([string]::IsNullOrEmpty($value)) {
            return ""
        }

        # Leerraum zwischen zwei "encoded words" gehört nicht zum Text.
        $text = [regex]::Replace($value, "(\?=)\s+(=\?)", '$1$2')

        $text = [regex]::Replace(
            $text,
            "=\?([^?]+)\?([BbQq])\?([^?]*)\?=",
            {
                param($match)

                $charset = $match.Groups[1].Value.Split("*")[0]
                $payload = $match.Groups[3].Value

                if ($match.Groups[2].Value -in @("B", "b")) {
                    try {
                        $bytes = [System.Convert]::FromBase64String($payload)
                    }
                    catch {
                        return $match.Value
                    }
                }
                else {
                    $bytes = [EmlContentReader]::DecodeQuotedPrintable($payload, $true)
                }

                return [EmlContentReader]::DecodeBytes($bytes, $charset)
            }
        )

        # Manche Mailprogramme schreiben UTF-8 direkt in Kopfzeilen (nicht
        # standardkonform).
        return [EmlContentReader]::DecodeBytes(
            [System.Text.Encoding]::Latin1.GetBytes($text),
            ""
        )
    }


    # Dekodiert mit dem angegebenen Zeichensatz. Fehlt er, wird zuerst UTF-8
    # versucht und Windows-1252 verwendet, wenn die Bytes kein gültiges UTF-8
    # sind.
    static [string] DecodeBytes([byte[]]$bytes, [string]$charset) {
        if (-not [string]::IsNullOrWhiteSpace($charset)) {
            try {
                return [System.Text.Encoding]::GetEncoding($charset.Trim().Trim('"')).GetString($bytes)
            }
            catch {
                # Unbekannter Zeichensatz: weiter mit der Erkennung.
            }
        }

        try {
            return [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        }
        catch {
            return [System.Text.Encoding]::GetEncoding(1252).GetString($bytes)
        }
    }
}


# Gesammelte Teile einer Mail beim Durchlaufen des MIME-Baums.
class MailParts {
    [System.Collections.Generic.List[string]]$PlainTexts = [System.Collections.Generic.List[string]]::new()
    [System.Collections.Generic.List[string]]$HtmlTexts = [System.Collections.Generic.List[string]]::new()
    [System.Collections.Generic.List[string]]$Attachments = [System.Collections.Generic.List[string]]::new()
}

using module "../ContentReader.psm1"

#requires -Version 7.2


# =============================================================================
# READER FÜR KLARTEXT
# =============================================================================

# Liest Dateien, die bereits als Text gespeichert sind. Auszeichnungssprachen
# (HTML, XML, JSON) werden unverändert zurückgegeben.
class TextContentReader : ContentReader {

    # Wirft bei ungültigen Bytefolgen eine Ausnahme, statt "?" einzufügen,
    # damit Dateien erkannt werden, die nicht UTF-8 sind.
    hidden static [System.Text.Encoding]$StrictUtf8 = (
        [System.Text.UTF8Encoding]::new($false, $true)
    )

    # Übliche Kodierung älterer deutscher Windows-Textdateien.
    hidden static [System.Text.Encoding]$Windows1252 = (
        [System.Text.Encoding]::GetEncoding(1252)
    )


    TextContentReader() {
        $this.Description = "Plain text, markup and data files"
        $this.Extensions = @(
            # Klartext und Notizen
            ".txt", ".text", ".log",
            # Auszeichnungssprachen
            ".md", ".markdown", ".rst", ".tex",
            ".html", ".htm", ".xhtml", ".xml",
            # Daten und Konfiguration
            ".csv", ".tsv", ".json", ".yaml", ".yml",
            ".ini", ".cfg", ".conf", ".toml",
            # Untertitel, Kalender und Kontakte
            ".srt", ".vtt", ".ics", ".vcf"
        )
    }


    [string] ReadContent([System.IO.FileInfo]$file) {
        $bytes = $this.ReadFileBytes($file)

        return [TextContentReader]::Decode($bytes)
    }


    # Reihenfolge: Byte Order Mark, dann UTF-8, dann Windows-1252 als Ersatz.
    static [string] Decode([byte[]]$bytes) {
        $encoding = [TextContentReader]::DetectByteOrderMark($bytes)

        if ($null -ne $encoding) {
            $preambleLength = $encoding.GetPreamble().Length

            return $encoding.GetString(
                $bytes,
                $preambleLength,
                $bytes.Length - $preambleLength
            )
        }

        try {
            return [TextContentReader]::StrictUtf8.GetString($bytes)
        }
        catch {
            # Kein gültiges UTF-8: Jedes Byte ist ein gültiges Zeichen in
            # Windows-1252.
            return [TextContentReader]::Windows1252.GetString($bytes)
        }
    }


    # Gibt die Kodierung zurück, die ein Byte Order Mark ankündigt, oder $null.
    hidden static [System.Text.Encoding] DetectByteOrderMark([byte[]]$bytes) {
        $length = $bytes.Length

        if (
            $length -ge 3 -and
            $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        ) {
            return [System.Text.UTF8Encoding]::new($true)
        }

        # UTF-32 LE muss vor UTF-16 LE geprüft werden: Beide beginnen mit FF FE.
        if (
            $length -ge 4 -and
            $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and
            $bytes[2] -eq 0x00 -and $bytes[3] -eq 0x00
        ) {
            return [System.Text.UTF32Encoding]::new($false, $true)
        }

        if (
            $length -ge 4 -and
            $bytes[0] -eq 0x00 -and $bytes[1] -eq 0x00 -and
            $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF
        ) {
            return [System.Text.UTF32Encoding]::new($true, $true)
        }

        if ($length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            return [System.Text.UnicodeEncoding]::new($false, $true)
        }

        if ($length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
            return [System.Text.UnicodeEncoding]::new($true, $true)
        }

        return $null
    }
}

#requires -Version 7.2


# =============================================================================
# BASISKLASSE FÜR READER
# =============================================================================

# Jeder Dateityp, aus dem der DocScanner Text lesen kann, bekommt einen eigenen
# Reader. Ein Reader gibt an, welche Endungen er verarbeitet, und wandelt eine
# Datei in Klartext um.
#
# Einen vorbereiteten Reader implementieren:
#   1. ReadContent() im Modul des Readers schreiben.
#   2. IsAvailable() $true zurückgeben lassen (oder das benötigte Tool prüfen).
#   Der Reader ist bereits in DocScanner.RegisterDefaultReaders() registriert.
#
# Einen ganz neuen Dateityp hinzufügen:
#   1. Ein Modul in einem passenden Unterordner anlegen, von [ContentReader]
#      erben und im Konstruktor $this.Extensions setzen.
#   2. Es in DocScanner.psm1 mit "using module" laden und in
#      RegisterDefaultReaders() registrieren.
#
# PowerShell kennt keine abstrakten Klassen, deshalb werfen die Methoden der
# Basisklasse stattdessen eine Ausnahme.
class ContentReader {

    # Endungen in Kleinbuchstaben mit Punkt, z. B. ".pdf".
    [string[]]$Extensions = @()

    # Kurze Beschreibung für Übersichten, z. B. "Word documents".
    [string]$Description = ""


    # Lesbarer Name für Log- und Debug-Ausgaben.
    [string] GetName() {
        return $this.GetType().Name
    }

    # Nicht verfügbare Reader werden nicht registriert, ihre Dateien werden
    # also ohne Inhalt indexiert. $false zurückgeben, solange ReadContent()
    # nicht implementiert ist oder ein benötigtes externes Tool fehlt.
    [bool] IsAvailable() {
        return $true
    }

    # Gibt den ausgelesenen Klartext der Datei zurück. Bei Lesefehlern eine
    # Ausnahme werfen; der Crawler protokolliert sie und versucht die Datei
    # beim nächsten Scan erneut.
    [string] ReadContent([System.IO.FileInfo]$file) {
        throw [System.NotImplementedException]::new(
            "ReadContent() is not implemented in $($this.GetName())."
        )
    }


    # =============================================================================
    # HILFSMETHODEN: DATEIZUGRIFF
    # =============================================================================

    # Öffnet eine Datei nur zum Lesen, während andere Programme sie geöffnet
    # haben dürfen. Windows verweigert [System.IO.File]::OpenRead() und
    # ReadAllBytes(), wenn ein anderes Programm die Datei zum Schreiben
    # geöffnet hat (eine offene Excel-Datei, eine Logdatei, in die gerade
    # geschrieben wird); gemeinsamer Lese- und Schreibzugriff verhindert das.
    # macOS und Linux sperren keine Dateien, dort verhält es sich wie
    # OpenRead().
    [System.IO.FileStream] OpenFile([System.IO.FileInfo]$file) {
        return [System.IO.FileStream]::new(
            $file.FullName,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        )
    }


    # Liest die ganze Datei wie [System.IO.File]::ReadAllBytes(), aber mit dem
    # gemeinsamen Zugriff von OpenFile().
    [byte[]] ReadFileBytes([System.IO.FileInfo]$file) {
        $stream = $this.OpenFile($file)

        try {
            $memory = [System.IO.MemoryStream]::new()
            $stream.CopyTo($memory)

            return $memory.ToArray()
        }
        finally {
            $stream.Dispose()
        }
    }


    # =============================================================================
    # HILFSMETHODEN: ZIP-CONTAINER (docx, xlsx, pptx, odt, epub, ...)
    # =============================================================================

    # Öffnet ein ZIP-basiertes Dokument nur zum Lesen. Das Ergebnis danach
    # freigeben:
    #   $zip = $this.OpenZip($file)
    #   try { ... } finally { $zip.Dispose() }
    [System.IO.Compression.ZipArchive] OpenZip([System.IO.FileInfo]$file) {
        # Beim Freigeben des Archivs wird auch der Dateistream geschlossen.
        return [System.IO.Compression.ZipArchive]::new(
            $this.OpenFile($file),
            [System.IO.Compression.ZipArchiveMode]::Read,
            $false
        )
    }


    # True, wenn die Datei mit einer ZIP-Signatur ("PK") beginnt.
    # Sperrdateien wie "~$Bericht.docx" oder fremde Dateien mit derselben
    # Endung (eine Lizenzdatei ".key") sind keine ZIP-Archive; Reader geben
    # für sie keinen Text zurück, statt bei jedem Scan einen Fehler zu melden.
    [bool] IsZipFile([System.IO.FileInfo]$file) {
        $header = [byte[]]::new(4)
        $count = 0
        $stream = $this.OpenFile($file)

        try {
            $count = $stream.Read($header, 0, 4)
        }
        finally {
            $stream.Dispose()
        }

        # "PK\3\4" beginnt einen Dateieintrag, "PK\5\6" ein leeres Archiv.
        return (
            $count -eq 4 -and
            $header[0] -eq 0x50 -and $header[1] -eq 0x4B -and
            (($header[2] -eq 3 -and $header[3] -eq 4) -or ($header[2] -eq 5 -and $header[3] -eq 6))
        )
    }


    # Öffnet einen XML-Eintrag zum streamenden Lesen mit einem XmlReader oder
    # gibt $null zurück, wenn der Eintrag nicht existiert. Beim Freigeben des
    # Readers wird der Eintrag geschlossen. Streaming hält den Speicherbedarf
    # bei großen Dokumenten niedrig.
    [System.Xml.XmlReader] OpenZipXml(
        [System.IO.Compression.ZipArchive]$zip,
        [string]$entryName
    ) {
        $entry = $zip.GetEntry($entryName)

        if ($null -eq $entry) {
            return $null
        }

        $settings = [System.Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Ignore
        $settings.IgnoreComments = $true
        $settings.IgnoreProcessingInstructions = $true
        $settings.CloseInput = $true

        return [System.Xml.XmlReader]::Create($entry.Open(), $settings)
    }


    # Gibt den Text eines Eintrags zurück, z. B. "word/document.xml", oder
    # einen leeren String, wenn der Eintrag nicht existiert (prüfen mit
    # [string]::IsNullOrEmpty).
    [string] ReadZipEntry(
        [System.IO.Compression.ZipArchive]$zip,
        [string]$entryName
    ) {
        $entry = $zip.GetEntry($entryName)

        if ($null -eq $entry) {
            return $null
        }

        $reader = [System.IO.StreamReader]::new($entry.Open())

        try {
            return $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
    }


    # Gibt die Namen aller Einträge zurück, die zu einem Platzhalter passen,
    # z. B. "ppt/slides/slide*.xml". Natürlich sortiert, also "slide2" vor
    # "slide10".
    [string[]] FindZipEntries(
        [System.IO.Compression.ZipArchive]$zip,
        [string]$pattern
    ) {
        $wildcard = [System.Management.Automation.WildcardPattern]::new(
            $pattern,
            [System.Management.Automation.WildcardOptions]::IgnoreCase
        )

        $names = @(
            $zip.Entries |
                Where-Object { $wildcard.IsMatch($_.FullName) } |
                ForEach-Object { $_.FullName }
        )

        # Alle Zahlen auffüllen, damit die Textsortierung der Zahlenreihenfolge
        # entspricht.
        return [string[]]@(
            $names | Sort-Object {
                [regex]::Replace($_, "\d+", { $args[0].Value.PadLeft(10, "0") })
            }
        )
    }


    # =============================================================================
    # HILFSMETHODEN: HTML (EPUB-Kapitel, HTML-Mails, ...)
    # =============================================================================

    # Wandelt HTML in lesbaren Klartext um: entfernt Skripte, Styles und Tags,
    # behält die Zeilenumbrüche von Blockelementen und dekodiert Entities wie
    # &auml;.
    [string] ConvertHtmlToText([string]$html) {
        if ([string]::IsNullOrEmpty($html)) {
            return ""
        }

        $text = $html

        # Unsichtbare Teile. <head> enthält auch den <title>, der meist die
        # erste Überschrift wiederholt.
        $text = [regex]::Replace($text, "(?is)<(script|style|head)\b.*?</\1\s*>", " ")
        $text = [regex]::Replace($text, "(?s)<!--.*?-->", " ")

        # Blockelemente beenden eine Zeile, Tabellenzellen werden durch ein
        # Leerzeichen getrennt.
        $text = [regex]::Replace($text, "(?i)<br\s*/?>", "`n")
        $text = [regex]::Replace(
            $text,
            "(?i)</(p|div|h[1-6]|li|tr|table|section|article|blockquote|pre|title|dt|dd)\s*>",
            "`n"
        )
        $text = [regex]::Replace($text, "(?i)</(td|th)\s*>", " ")

        # Die übrigen Tags sind Inline-Tags (<b>, <span>, ...) und werden ohne
        # Leerzeichen entfernt, damit durch Formatierung getrennte Wörter
        # zusammenbleiben.
        $text = [regex]::Replace($text, "(?s)<[^>]*>", "")

        $text = [System.Net.WebUtility]::HtmlDecode($text)

        # Leerzeichen zusammenfassen, Zeilen kürzen und höchstens eine leere
        # Zeile zulassen.
        $text = [regex]::Replace($text, "[ \t\u00A0]+", " ")
        $text = [regex]::Replace($text, " *\r?\n *", "`n")
        $text = [regex]::Replace($text, "\n{3,}", "`n`n")

        return $text.Trim()
    }


    # =============================================================================
    # HILFSMETHODEN: EXTERNE TOOLS (tesseract, ffprobe, ...)
    # =============================================================================

    # Gibt den vollständigen Pfad des ersten im PATH gefundenen Tools zurück
    # oder einen leeren String, wenn keines installiert ist.
    [string] FindTool([string[]]$names) {
        foreach ($name in $names) {
            $command = Get-Command -Name $name -CommandType Application `
                -ErrorAction SilentlyContinue |
                Select-Object -First 1

            if ($null -ne $command) {
                return $command.Source
            }
        }

        return $null
    }


    # True, wenn mindestens eines der Tools installiert ist. Zur Verwendung in
    # IsAvailable():
    #   return $this.HasTool(@("tesseract"))
    [bool] HasTool([string[]]$names) {
        return -not [string]::IsNullOrEmpty($this.FindTool($names))
    }


    # Führt ein Tool aus und gibt seine Standardausgabe als UTF-8-Text zurück.
    # Wirft eine Ausnahme, wenn das Tool fehlschlägt oder länger als das
    # Zeitlimit braucht, damit eine defekte Datei nicht den ganzen Scan
    # aufhält.
    [string] RunTool([string]$toolPath, [string[]]$arguments) {
        return $this.RunTool($toolPath, $arguments, 60)
    }


    [string] RunTool(
        [string]$toolPath,
        [string[]]$arguments,
        [int]$timeoutSeconds
    ) {
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new($toolPath)
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8

        # Ohne UTF-8-Locale geben viele Tools (z. B. bsdtar) Umlaute als
        # "\303\274" aus. Windows-Tools ignorieren diese Variablen.
        if (-not $global:IsWindows) {
            $locale = if ($global:IsMacOS) { "en_US.UTF-8" } else { "C.UTF-8" }
            $startInfo.Environment["LC_ALL"] = $locale
        }

        # ArgumentList setzt jedes Argument in Anführungszeichen, damit Pfade
        # mit Leerzeichen funktionieren.
        foreach ($argument in $arguments) {
            $startInfo.ArgumentList.Add($argument)
        }

        $process = [System.Diagnostics.Process]::Start($startInfo)

        try {
            # Beide Streams asynchron lesen; ein voller Puffer würde das Tool
            # sonst blockieren.
            $outputTask = $process.StandardOutput.ReadToEndAsync()
            $errorTask = $process.StandardError.ReadToEndAsync()

            if (-not $process.WaitForExit($timeoutSeconds * 1000)) {
                $process.Kill($true)
                throw "$([System.IO.Path]::GetFileName($toolPath)) timed out after $timeoutSeconds seconds."
            }

            if ($process.ExitCode -ne 0) {
                throw (
                    "{0} failed with exit code {1}: {2}" -f
                    [System.IO.Path]::GetFileName($toolPath),
                    $process.ExitCode,
                    $errorTask.Result.Trim()
                )
            }

            return $outputTask.Result
        }
        finally {
            $process.Dispose()
        }
    }
}

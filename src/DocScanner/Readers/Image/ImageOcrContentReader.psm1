using module "../ContentReader.psm1"
using module "../Shared/XmlText.psm1"
using module "./ImageMetadata.psm1"
using module "./YoloObjectDetector.psm1"

#requires -Version 7.4


# =============================================================================
# READER FÜR BILDER (METADATEN UND TEXTERKENNUNG)
# =============================================================================

# Macht Bilder auf drei Wegen durchsuchbar:
#
# 1. Metadaten (immer, ohne Tool, siehe ImageMetadata): Titel,
#    Beschreibung, Stichwörter, Autor, Kamera, Aufnahmedatum, Ort, Personen
#    aus Exif, XMP, PNG-Textblöcken und JPEG-Kommentaren.
#
# 2. Texterkennung (OCR) für Text im Bild, z. B. Scans, Screenshots oder
#    abfotografierte Dokumente. Verwendet wird, was das System mitbringt:
#      - macOS:   Vision-Framework über osascript (JavaScript for
#                 Automation), ab macOS 11 eingebaut.
#      - Windows: Windows.Media.Ocr (ab Windows 10 eingebaut) über Windows
#                 PowerShell 5.1, weil PowerShell 7 die nötigen
#                 WinRT-Typen nicht laden kann. Erkannt werden die Sprachen
#                 des Benutzerprofils.
#      - sonst:   Tesseract, falls installiert ("tesseract"), mit Deutsch
#                 und Englisch, soweit die Sprachdaten vorhanden sind.
#    Gibt es nichts davon (z. B. Linux ohne Tesseract), werden nur die
#    Metadaten gelesen.
#
# 3. Objekterkennung: was auf dem Foto zu sehen ist, z. B.
#    "Objects: cat (Katze), sofa (Sofa)". Sie läuft nach dem Scan im
#    Hintergrund (CanEnrich/Enrich), damit der Index nicht darauf wartet.
#      - macOS:   eingebaute Bildklassifizierung von Vision
#                 (VNClassifyImageRequest, über 1.000 Begriffe).
#      - sonst:   YOLO26n über ONNX Runtime (YoloObjectDetector, 80
#                 Objektklassen). Die Bibliotheken werden beim ersten
#                 Gebrauch heruntergeladen; ohne Internet bleibt es bei den
#                 übrigen Inhalten.
#    Begriffe, die zu den 80 YOLO-Klassen gehören, bekommen den deutschen
#    Namen dazu, damit auch die Suche nach "Katze" ein Foto findet.
#
# SVG-Grafiken sind XML; ihr Text (<title>, <desc>, <text>) wird direkt
# gelesen.
#
# Ausgabe: zuerst die Metadaten als Zeilen "Bezeichnung: Wert", nach einer
# Leerzeile der erkannte Text, später ergänzt um die Zeile "Objects: ...".
[NoRunspaceAffinity()]
class ImageOcrContentReader : ContentReader {

    # Texterkennung ein- oder ausschalten. Sie dauert etwa 0,3 bis 1 Sekunde
    # pro Bild; ohne sie werden nur Metadaten gelesen.
    [bool]$UseOcr = $true

    # Kleinere Bilder (Icons, Vorschaubilder) werden nicht erkannt; in ihnen
    # steht selten lesbarer Text, sie kosten aber genauso einen Toolstart.
    [long]$MinOcrBytes = 10KB

    [int]$OcrTimeoutSeconds = 60

    # Objekterkennung ein- oder ausschalten.
    [bool]$DetectObjects = $true

    # "Auto" (macOS: Vision, sonst YOLO), "Vision" oder "Yolo".
    [string]$ObjectDetector = "Auto"

    # Mindestwahrscheinlichkeit eines Treffers. Vision und YOLO bewerten
    # unterschiedlich streng, daher getrennt.
    [double]$MinVisionConfidence = 0.3
    [double]$MinYoloConfidence = 0.4

    # Höchstens so viele Begriffe pro Bild (Vision liefert sonst sehr
    # allgemeine wie "structure" oder "material").
    [int]$MaxObjectLabels = 8

    # Gescheiterte YOLO-Einrichtung (z. B. kein Internet): nicht bei jedem
    # Bild erneut versuchen.
    hidden [bool]$_yoloFailed = $false

    # "Vision", "WindowsOcr", "Tesseract" oder leer.
    hidden [string]$_ocrEngine = ""
    hidden [string]$_ocrTool = ""
    hidden [string]$_tesseractLanguages = ""

    # Formate, die die jeweilige Texterkennung selbst dekodieren kann.
    hidden [string[]]$_ocrExtensions = @()

    # Ergebnisse aus Prepare(): Pfad -> erkannter Text bzw. Fehlermeldung.
    # Gilt nur für das gerade gelesene Paket.
    hidden [System.Collections.Generic.Dictionary[string, string]]$_preparedText = (
        [System.Collections.Generic.Dictionary[string, string]]::new()
    )
    hidden [System.Collections.Generic.Dictionary[string, string]]$_preparedError = (
        [System.Collections.Generic.Dictionary[string, string]]::new()
    )


    ImageOcrContentReader() {
        $this.Description = "Images (metadata and text recognition)"
        $this.Extensions = @(
            ".png", ".jpg", ".jpeg",
            ".tif", ".tiff", ".bmp",
            ".gif", ".webp", ".heic", ".heif",
            ".svg"
        )

        $this._DetectOcrEngine()
    }


    # Metadaten gehen immer, daher ist der Reader immer verfügbar.
    [bool] IsAvailable() {
        return $true
    }


    # Name der verwendeten Texterkennung, leer ohne Texterkennung.
    [string] GetOcrEngine() {
        return $this._ocrEngine
    }


    [string] ReadContent([System.IO.FileInfo]$file) {
        $extension = $file.Extension.ToLowerInvariant()

        if ($extension -eq ".svg") {
            return $this._ReadSvg($file)
        }

        $metadata = [ImageMetadata]::Read($this.ReadFileBytes($file))
        $recognized = ""

        if ($this._ShouldRunOcr($file, $extension)) {
            try {
                $recognized = $this._RecognizeText($file)
            }
            catch {
                # Ohne Metadaten ist der Fehler das einzige Ergebnis und wird
                # gemeldet. Sonst reichen die Metadaten; ein einzelnes nicht
                # erkennbares Bild soll den Inhalt nicht verwerfen.
                if ([string]::IsNullOrEmpty($metadata)) {
                    throw
                }
            }
        }

        if ([string]::IsNullOrEmpty($recognized)) {
            return $metadata
        }

        if ([string]::IsNullOrEmpty($metadata)) {
            return $recognized
        }

        return "$metadata`n`n$recognized"
    }


    # =============================================================================
    # TEXTERKENNUNG
    # =============================================================================

    # Unter macOS werden alle Bilder eines Pakets in einem einzigen
    # osascript-Aufruf erkannt. Ein eigener Prozess pro Bild kostet etwa
    # 330 ms, davon gut die Hälfte für Start und Laden von Vision; im selben
    # Prozess sind es etwa 110 ms pro Bild. ReadContent() holt danach nur
    # noch das Ergebnis ab.
    [void] Prepare([System.IO.FileInfo[]]$files) {
        $this._preparedText.Clear()
        $this._preparedError.Clear()

        if ($this._ocrEngine -ne "Vision") {
            return
        }

        $paths = [System.Collections.Generic.List[string]]::new()

        foreach ($file in $files) {
            if ($this._ShouldRunOcr($file, $file.Extension.ToLowerInvariant())) {
                $paths.Add($file.FullName)
            }
        }

        # Ein einzelnes Bild wird ohnehin mit einem Aufruf erkannt.
        if ($paths.Count -lt 2) {
            return
        }

        $arguments = [System.Collections.Generic.List[string]]::new()
        $arguments.AddRange([string[]]@("-l", "JavaScript", "-e", [ImageOcrContentReader]::VisionBatchScript))
        $arguments.AddRange($paths)

        # Zeitlimit wächst mit der Anzahl der Bilder.
        $timeout = $this.OcrTimeoutSeconds + (10 * $paths.Count)
        $output = $this.RunTool($this._ocrTool, $arguments.ToArray(), $timeout)
        $results = @($output | ConvertFrom-Json)

        if ($results.Count -ne $paths.Count) {
            return
        }

        for ($i = 0; $i -lt $paths.Count; $i++) {
            if ($null -ne $results[$i].error) {
                $this._preparedError[$paths[$i]] = [string]$results[$i].error
            }
            else {
                $this._preparedText[$paths[$i]] = [string]$results[$i].text
            }
        }
    }


    # Nimmt das Ergebnis aus Prepare(), sonst wird das Bild einzeln erkannt.
    hidden [string] _RecognizeText([System.IO.FileInfo]$file) {
        $path = $file.FullName
        $text = $null

        if ($this._preparedText.Remove($path, [ref]$text)) {
            return [ImageOcrContentReader]::CleanUp($text)
        }

        $message = $null

        if ($this._preparedError.Remove($path, [ref]$message)) {
            throw "Vision: $message"
        }

        return $this._RunOcr($file)
    }

    hidden [void] _DetectOcrEngine() {
        if ($global:IsMacOS) {
            $tool = $this.FindTool(@("osascript"))

            if (-not [string]::IsNullOrEmpty($tool)) {
                $this._ocrEngine = "Vision"
                $this._ocrTool = $tool
                $this._ocrExtensions = @(".png", ".jpg", ".jpeg", ".tif", ".tiff", ".bmp", ".gif", ".webp", ".heic", ".heif")
                return
            }
        }

        if ($global:IsWindows) {
            $tool = $this.FindTool(@("powershell"))

            if (-not [string]::IsNullOrEmpty($tool)) {
                $this._ocrEngine = "WindowsOcr"
                $this._ocrTool = $tool

                # HEIC und WebP brauchen unter Windows Zusatz-Codecs aus dem
                # Store; ohne sie würde jedes solche Bild einen Fehler melden.
                $this._ocrExtensions = @(".png", ".jpg", ".jpeg", ".tif", ".tiff", ".bmp", ".gif")
                return
            }
        }

        $tesseract = $this.FindTool(@("tesseract"))

        if (-not [string]::IsNullOrEmpty($tesseract)) {
            $languages = $this._GetTesseractLanguages($tesseract)

            if (-not [string]::IsNullOrEmpty($languages)) {
                $this._ocrEngine = "Tesseract"
                $this._ocrTool = $tesseract
                $this._tesseractLanguages = $languages
                $this._ocrExtensions = @(".png", ".jpg", ".jpeg", ".tif", ".tiff", ".bmp", ".gif", ".webp")
            }
        }
    }


    # Deutsch und Englisch, soweit installiert; sonst die erste installierte
    # Sprache. "osd" ist keine Sprache, sondern die Erkennung der Ausrichtung.
    hidden [string] _GetTesseractLanguages([string]$tool) {
        try {
            $output = $this.RunTool($tool, @("--list-langs"), 10)
        }
        catch {
            return ""
        }

        $installed = @(
            $output -split "\r?\n" |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ -match "^[A-Za-z_]+$" -and $_ -ne "osd" }
        )

        $preferred = @($installed | Where-Object { $_ -in "deu", "eng" })

        if ($preferred.Count -gt 0) {
            return $preferred -join "+"
        }

        if ($installed.Count -gt 0) {
            return $installed[0]
        }

        return ""
    }


    hidden [bool] _ShouldRunOcr([System.IO.FileInfo]$file, [string]$extension) {
        return (
            $this.UseOcr -and
            -not [string]::IsNullOrEmpty($this._ocrEngine) -and
            $file.Length -ge $this.MinOcrBytes -and
            $extension -in $this._ocrExtensions
        )
    }


    hidden [string] _RunOcr([System.IO.FileInfo]$file) {
        $output = ""

        switch ($this._ocrEngine) {
            "Vision" {
                # Das Skript bekommt den Pfad als Argument; der
                # Rückgabewert von run() landet in der Standardausgabe.
                $output = $this.RunTool(
                    $this._ocrTool,
                    @("-l", "JavaScript", "-e", [ImageOcrContentReader]::VisionScript, $file.FullName),
                    $this.OcrTimeoutSeconds
                )
            }
            "WindowsOcr" {
                $output = $this._RunWindowsOcr($file)
            }
            "Tesseract" {
                $output = $this.RunTool(
                    $this._ocrTool,
                    @($file.FullName, "stdout", "-l", $this._tesseractLanguages),
                    $this.OcrTimeoutSeconds
                )
            }
        }

        return [ImageOcrContentReader]::CleanUp($output)
    }


    # -EncodedCommand erwartet das Skript als Base64 von UTF-16LE. Der Pfad
    # wird als Text in einfachen Anführungszeichen eingesetzt; darin muss nur
    # das Anführungszeichen selbst verdoppelt werden.
    hidden [string] _RunWindowsOcr([System.IO.FileInfo]$file) {
        $quotedPath = "'" + $file.FullName.Replace("'", "''") + "'"
        $script = "`$path = $quotedPath`n" + [ImageOcrContentReader]::WindowsOcrScript
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($script))

        try {
            return $this.RunTool(
                $this._ocrTool,
                @("-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $encoded),
                $this.OcrTimeoutSeconds
            )
        }
        catch {
            # Ohne installiertes OCR-Sprachpaket scheitert jedes Bild gleich;
            # dann wird die Texterkennung für den Rest des Scans abgeschaltet.
            if ($_.Exception.Message -match "NoOcrLanguage") {
                $this._ocrEngine = ""
            }

            throw
        }
    }


    # Kürzt jede Zeile und entfernt leere Zeilen.
    hidden static [string] CleanUp([string]$text) {
        if ([string]::IsNullOrWhiteSpace($text)) {
            return ""
        }

        $lines = [System.Collections.Generic.List[string]]::new()

        foreach ($line in $text -split "\r?\n") {
            $trimmed = $line.Trim()

            if ($trimmed.Length -gt 0) {
                $lines.Add($trimmed)
            }
        }

        return [string]::Join("`n", $lines)
    }


    # =============================================================================
    # OBJEKTERKENNUNG (IM HINTERGRUND)
    # =============================================================================

    [bool] CanEnrich([System.IO.FileInfo]$file) {
        $engine = $this._GetObjectEngine()

        if ([string]::IsNullOrEmpty($engine) -or $file.Length -lt $this.MinOcrBytes) {
            return $false
        }

        $extension = $file.Extension.ToLowerInvariant()

        if ($engine -eq "Vision") {
            return $extension -in $this._visionObjectExtensions
        }

        return Test-YoloExtension -Extension $extension
    }


    # Gibt pro Bild "Objects: ..." zurück, leer wenn nichts erkannt wurde.
    [string[]] Enrich([System.IO.FileInfo[]]$files) {
        $results = [string[]]::new($files.Length)
        $engine = $this._GetObjectEngine()

        if ($engine -eq "Vision") {
            $labels = $this._ClassifyWithVision($files)

            for ($i = 0; $i -lt $files.Length -and $i -lt $labels.Length; $i++) {
                $results[$i] = [ImageOcrContentReader]::FormatObjects($labels[$i])
            }

            return $results
        }

        if ($engine -eq "Yolo") {
            try {
                Initialize-YoloDetector
            }
            catch {
                # Einmal melden (der Crawler zeigt den Fehler an), danach
                # ohne Objekterkennung weiter.
                $this._yoloFailed = $true
                throw "YOLO object detection is not available: $($_.Exception.Message)"
            }

            for ($i = 0; $i -lt $files.Length; $i++) {
                try {
                    $classes = Find-YoloObject -Path $files[$i].FullName -MinConfidence $this.MinYoloConfidence
                    $text = Format-YoloLabel -Classes ($classes | Select-Object -First $this.MaxObjectLabels)

                    if (-not [string]::IsNullOrEmpty($text)) {
                        $results[$i] = "Objects: $text"
                    }
                }
                catch {
                    # Ein nicht dekodierbares Bild behält seinen bisherigen
                    # Inhalt.
                }
            }
        }

        return $results
    }


    # Welche Objekterkennung verwendet wird; leer, wenn keine.
    hidden [string] _GetObjectEngine() {
        if (-not $this.DetectObjects) {
            return ""
        }

        $useVision = $this.ObjectDetector -eq "Vision" -or ($this.ObjectDetector -eq "Auto" -and $global:IsMacOS)

        if ($useVision) {
            if ($global:IsMacOS -and -not [string]::IsNullOrEmpty($this._ocrTool) -and $this._ocrEngine -eq "Vision") {
                return "Vision"
            }

            return ""
        }

        if (-not $this._yoloFailed -and (Test-YoloModel)) {
            return "Yolo"
        }

        return ""
    }


    # Formate, die Vision zur Klassifizierung lesen kann.
    hidden [string[]]$_visionObjectExtensions = @(".png", ".jpg", ".jpeg", ".tif", ".tiff", ".bmp", ".gif", ".webp", ".heic", ".heif")


    # Alle Bilder in einem osascript-Aufruf; Ergebnis pro Bild eine Liste
    # von Begriffen, nach Wahrscheinlichkeit sortiert.
    hidden [object[]] _ClassifyWithVision([System.IO.FileInfo[]]$files) {
        $arguments = [System.Collections.Generic.List[string]]::new()
        $arguments.AddRange([string[]]@(
            "-l", "JavaScript", "-e", [ImageOcrContentReader]::VisionClassifyScript,
            $this.MinVisionConfidence.ToString([System.Globalization.CultureInfo]::InvariantCulture),
            [string]$this.MaxObjectLabels
        ))

        foreach ($file in $files) {
            $arguments.Add($file.FullName)
        }

        $output = $this.RunTool($this._ocrTool, $arguments.ToArray(), $this.OcrTimeoutSeconds + 5 * $files.Length)

        return @($output | ConvertFrom-Json)
    }


    # "Objects: cat (Katze), sofa (Sofa)" aus einer Liste englischer Begriffe.
    hidden static [string] FormatObjects([object]$labels) {
        $parts = foreach ($label in @($labels)) {
            if (-not [string]::IsNullOrWhiteSpace($label)) {
                Format-ObjectLabel -Label ([string]$label)
            }
        }

        $parts = @($parts)

        if ($parts.Count -eq 0) {
            return ""
        }

        return "Objects: " + ($parts -join ", ")
    }


    # =============================================================================
    # SVG
    # =============================================================================

    hidden [string] _ReadSvg([System.IO.FileInfo]$file) {
        $settings = [System.Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Ignore
        $settings.XmlResolver = $null
        $settings.IgnoreComments = $true

        $stream = $this.OpenFile($file)

        try {
            $reader = [System.Xml.XmlReader]::Create($stream, $settings)

            try {
                return [XmlText]::Extract($reader, [ImageOcrContentReader]::SvgRules)
            }
            finally {
                $reader.Dispose()
            }
        }
        catch [System.Xml.XmlException] {
            # Viele Programme schreiben SVG, das kein strenges XML ist (z. B.
            # "--" in Kommentaren). Browser zeigen es trotzdem an; dann wird
            # der Text ohne XML-Parser herausgesucht.
            return [ImageOcrContentReader]::ExtractSvgTextLoosely(
                [System.IO.File]::ReadAllText($file.FullName)
            )
        }
        finally {
            $stream.Dispose()
        }
    }


    # Sucht <title>, <desc> und <text> per regulärem Ausdruck, entfernt
    # darin verschachtelte Tags (z. B. <tspan>) und wandelt Entitäten um.
    hidden static [string] ExtractSvgTextLoosely([string]$svg) {
        # Kommentare, Stile und Skripte enthalten keinen sichtbaren Text.
        $clean = [regex]::Replace($svg, "(?s)<!--.*?-->|<(style|script)\b.*?</\1>", "")
        $lines = [System.Collections.Generic.List[string]]::new()

        foreach ($match in [regex]::Matches($clean, "(?s)<(title|desc|text)\b[^>]*>(.*?)</\1>")) {
            $inner = [regex]::Replace($match.Groups[2].Value, "<[^>]+>", "")
            $text = [System.Net.WebUtility]::HtmlDecode($inner).Trim()

            if ($text.Length -gt 0) {
                $lines.Add([regex]::Replace($text, "\s+", " "))
            }
        }

        return [string]::Join("`n", $lines)
    }


    hidden static [XmlTextRules]$SvgRules = [ImageOcrContentReader]::CreateSvgRules()

    hidden static [XmlTextRules] CreateSvgRules() {
        $rules = [XmlTextRules]::new()
        $rules.TextElements = @("title", "desc", "text")
        $rules.ParagraphElements = @("title", "desc", "text")
        $rules.SkipElements = @("style", "script")

        return $rules
    }


    # =============================================================================
    # SKRIPTE FÜR DIE TEXTERKENNUNG
    # =============================================================================

    # macOS: VNRecognizeTextRequest mit genauer Erkennung und
    # Sprachkorrektur. Jede erkannte Zeile wird eine Zeile der Ausgabe.
    hidden static [string]$VisionFunctions = @'
ObjC.import('Foundation');
ObjC.import('Vision');

function recognize(path) {
    const url = $.NSURL.fileURLWithPath(path);
    const request = $.VNRecognizeTextRequest.alloc.init;
    request.recognitionLevel = 0;
    request.usesLanguageCorrection = true;
    request.recognitionLanguages = $(['de-DE', 'en-US']);

    const handler = $.VNImageRequestHandler.alloc.initWithURLOptions(url, $({}));
    const error = Ref();

    if (!handler.performRequestsError($([request]), error)) {
        throw new Error('Vision could not read the image.');
    }

    const results = request.results;
    const lines = [];

    for (let i = 0; i < results.count; i++) {
        const candidates = results.objectAtIndex(i).topCandidates(1);

        if (candidates.count > 0) {
            lines.push(candidates.objectAtIndex(0).string.js);
        }
    }

    return lines.join('\n');
}
'@

    # Bildklassifizierung: Argumente sind Mindestwahrscheinlichkeit, Höchstzahl
    # der Begriffe und die Bildpfade. Ausgabe: JSON-Liste mit einer Liste von
    # Begriffen pro Bild (leer, wenn das Bild nicht lesbar ist).
    hidden static [string]$VisionClassifyScript = @'
ObjC.import('Foundation');
ObjC.import('Vision');

function run(argv) {
    const minConfidence = parseFloat(argv[0]);
    const maxLabels = parseInt(argv[1]);
    const results = [];

    for (let i = 2; i < argv.length; i++) {
        const request = $.VNClassifyImageRequest.alloc.init;
        const handler = $.VNImageRequestHandler.alloc.initWithURLOptions($.NSURL.fileURLWithPath(argv[i]), $({}));
        const found = [];

        if (handler.performRequestsError($([request]), Ref())) {
            const observations = request.results;

            for (let j = 0; j < observations.count; j++) {
                const observation = observations.objectAtIndex(j);

                if (observation.confidence >= minConfidence) {
                    found.push({ label: observation.identifier.js, confidence: observation.confidence });
                }
            }
        }

        // Wahrscheinlichste zuerst, dann auf maxLabels kürzen.
        found.sort((a, b) => b.confidence - a.confidence);
        results.push(found.slice(0, maxLabels).map(f => f.label));
    }

    return JSON.stringify(results);
}
'@

    # Ein Bild: Der Text wird direkt ausgegeben.
    hidden static [string]$VisionScript = [ImageOcrContentReader]::VisionFunctions + @'

function run(argv) {
    return recognize(argv[0]);
}
'@

    # Mehrere Bilder: JSON-Liste in derselben Reihenfolge, pro Bild
    # {"text": ...} oder {"error": ...}. Ein nicht lesbares Bild bricht so
    # nicht das ganze Paket ab.
    hidden static [string]$VisionBatchScript = [ImageOcrContentReader]::VisionFunctions + @'

function run(argv) {
    const results = [];

    for (let i = 0; i < argv.length; i++) {
        try {
            results.push({ text: recognize(argv[i]) });
        }
        catch (e) {
            results.push({ error: String(e) });
        }
    }

    return JSON.stringify(results);
}
'@

    # Windows: läuft in Windows PowerShell 5.1. Die WinRT-Methoden sind
    # asynchron; AsTask() macht daraus einen .NET-Task, auf den gewartet
    # wird. $path wird vorne eingesetzt.
    hidden static [string]$WindowsOcrScript = @'
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics, ContentType = WindowsRuntime]
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]

$asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and
    $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
} | Select-Object -First 1

function Wait-WinRt($operation, [type]$resultType) {
    $task = $asTask.MakeGenericMethod($resultType).Invoke($null, @($operation))
    [void]$task.Wait(-1)
    return $task.Result
}

$engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
if ($null -eq $engine) {
    throw 'NoOcrLanguage: No OCR language pack is installed.'
}

$storageFile = Wait-WinRt ([Windows.Storage.StorageFile]::GetFileFromPathAsync($path)) ([Windows.Storage.StorageFile])
$stream = Wait-WinRt ($storageFile.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])

try {
    $decoder = Wait-WinRt ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $bitmap = Wait-WinRt ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $result = Wait-WinRt ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])

    foreach ($line in $result.Lines) {
        $line.Text
    }
}
finally {
    $stream.Dispose()
}
'@
}

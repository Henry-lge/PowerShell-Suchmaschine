using module "../ContentReader.psm1"
using module "../Image/ImageOcrContentReader.psm1"
using module "./VideoMetadata.psm1"

#requires -Version 7.4


# =============================================================================
# READER FÜR VIDEOS (METADATEN UND TEXT IN EINZELBILDERN)
# =============================================================================

# Macht Videos auf zwei Wegen durchsuchbar:
#
# 1. Metadaten (immer, ohne Tool, siehe VideoMetadata): Titel,
#    Beschreibung, Stichwörter, Autor, Datum, Ort und Dauer aus MP4, MOV,
#    MKV, WebM und AVI.
#
# 2. Text in Einzelbildern, z. B. Folien einer aufgezeichneten
#    Präsentation, Bildschirmaufnahmen oder Untertitel, die ins Bild
#    gebrannt sind. Über das Video verteilt wird etwa alle
#    SecondsPerFrame Sekunden ein Bild entnommen (mindestens MinFrames,
#    höchstens MaxFrames) und darin Text erkannt; jede Zeile kommt nur
#    einmal vor.
#      - macOS:  AVFoundation entnimmt die Bilder, Vision erkennt den Text,
#                beides eingebaut, aufgerufen über osascript (JavaScript for
#                Automation). AVFoundation kann MP4, M4V, MOV und 3GP lesen.
#      - sonst:  ffmpeg, falls installiert, entnimmt die Bilder; erkannt
#                wird mit der Texterkennung des Bild-Readers (Windows.Media.Ocr
#                oder Tesseract).
#    Ohne passendes Werkzeug werden nur die Metadaten gelesen.
#
# Ein Video braucht so einige Sekunden. Der Reader läuft deshalb im
# Hintergrund (RunsInBackground): Der Crawler speichert Videos beim Scan
# zuerst ohne Inhalt und liest sie danach, ohne den übrigen Index aufzuhalten.
[NoRunspaceAffinity()]
class MediaContentReader : ContentReader {

    # Text in Einzelbildern erkennen. Aus: nur Metadaten.
    [bool]$UseOcr = $true

    # Ungefährer Abstand der entnommenen Bilder und ihre Mindest- und
    # Höchstzahl. Ein 10-Minuten-Video ergibt so 20 Bilder.
    [int]$SecondsPerFrame = 30
    [int]$MinFrames = 3
    [int]$MaxFrames = 20

    # Zeitlimit für die Texterkennung eines ganzen Videos.
    [int]$TimeoutSeconds = 300

    # "AVFoundation", "FFmpeg" oder leer (keine Texterkennung).
    hidden [string]$_engine = ""
    hidden [string]$_tool = ""
    hidden [string]$_ffprobe = ""
    hidden [string[]]$_ocrExtensions = @()

    # Texterkennung für die von ffmpeg entnommenen Bilder.
    hidden [ImageOcrContentReader]$_imageReader


    MediaContentReader() {
        $this.Description = "Videos (metadata and text in frames)"
        $this.Extensions = @(".mp4", ".m4v", ".mov", ".3gp", ".mkv", ".webm", ".avi")

        # Gelesen werden nur die Metadaten-Blöcke und einzelne Bilder, daher
        # gilt die Größengrenze des DocScanners (10 MB) hier nicht.
        $this.MaxFileSizeBytes = 1TB
        $this.RunsInBackground = $true

        $this._DetectEngine()
    }


    # Metadaten gehen immer, daher ist der Reader immer verfügbar.
    [bool] IsAvailable() {
        return $true
    }


    [string] GetOcrEngine() {
        return $this._engine
    }


    [string] ReadContent([System.IO.FileInfo]$file) {
        $stream = $this.OpenFile($file)
        $metadata = $null

        try {
            $metadata = [VideoMetadata]::Read($stream)
        }
        finally {
            $stream.Dispose()
        }

        $text = $metadata.ToText()
        $recognized = ""

        if ($this.UseOcr -and $file.Extension.ToLowerInvariant() -in $this._ocrExtensions) {
            try {
                $recognized = $this._RecognizeFrames($file, $metadata.DurationSeconds)
            }
            catch {
                # Ohne Metadaten ist der Fehler das einzige Ergebnis und wird
                # gemeldet; sonst reichen die Metadaten.
                if ([string]::IsNullOrEmpty($text)) {
                    throw
                }
            }
        }

        if ([string]::IsNullOrEmpty($recognized)) {
            return $text
        }

        if ([string]::IsNullOrEmpty($text)) {
            return $recognized
        }

        return "$text`n`n$recognized"
    }


    # =============================================================================
    # TEXT IN EINZELBILDERN
    # =============================================================================

    hidden [void] _DetectEngine() {
        if ($global:IsMacOS) {
            $osascript = $this.FindTool(@("osascript"))

            if (-not [string]::IsNullOrEmpty($osascript)) {
                $this._engine = "AVFoundation"
                $this._tool = $osascript
                $this._ocrExtensions = @(".mp4", ".m4v", ".mov", ".3gp")
                return
            }
        }

        $ffmpeg = $this.FindTool(@("ffmpeg"))

        if (-not [string]::IsNullOrEmpty($ffmpeg)) {
            $this._imageReader = [ImageOcrContentReader]::new()

            # ffmpeg entnimmt nur die Bilder; ohne Texterkennung nützt es nichts.
            if (-not [string]::IsNullOrEmpty($this._imageReader.GetOcrEngine())) {
                $this._engine = "FFmpeg"
                $this._tool = $ffmpeg
                $this._ffprobe = $this.FindTool(@("ffprobe"))
                $this._ocrExtensions = $this.Extensions
            }
        }
    }


    hidden [string] _RecognizeFrames([System.IO.FileInfo]$file, [double]$durationSeconds) {
        if ($this._engine -eq "AVFoundation") {
            $output = $this.RunTool(
                $this._tool,
                @(
                    "-l", "JavaScript", "-e", [MediaContentReader]::FrameScript,
                    $file.FullName,
                    [string]$this.SecondsPerFrame,
                    [string]$this.MinFrames,
                    [string]$this.MaxFrames
                ),
                $this.TimeoutSeconds
            )

            return [MediaContentReader]::CleanUp($output)
        }

        if ($this._engine -eq "FFmpeg") {
            return $this._RecognizeWithFfmpeg($file, $durationSeconds)
        }

        return ""
    }


    # Entnimmt die Bilder einzeln mit ffmpeg in einen temporären Ordner und
    # erkennt sie mit der Texterkennung des Bild-Readers.
    hidden [string] _RecognizeWithFfmpeg([System.IO.FileInfo]$file, [double]$durationSeconds) {
        $duration = $durationSeconds

        if ($duration -le 0 -and -not [string]::IsNullOrEmpty($this._ffprobe)) {
            $probe = $this.RunTool(
                $this._ffprobe,
                @("-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", $file.FullName),
                60
            )
            [void][double]::TryParse($probe.Trim(), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$duration)
        }

        if ($duration -le 0) {
            return ""
        }

        $folder = Join-Path ([System.IO.Path]::GetTempPath()) ("suchmaschine-frames-" + [guid]::NewGuid())
        [void][System.IO.Directory]::CreateDirectory($folder)
        $lines = [System.Collections.Generic.List[string]]::new()
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

        try {
            foreach ($seconds in [MediaContentReader]::FrameTimes($duration, $this.SecondsPerFrame, $this.MinFrames, $this.MaxFrames)) {
                $framePath = Join-Path $folder ("frame-{0:000000}.png" -f [int]($seconds * 10))
                $time = $seconds.ToString("0.###", [System.Globalization.CultureInfo]::InvariantCulture)

                # -ss vor -i springt schnell zum nächsten Schlüsselbild.
                [void]$this.RunTool(
                    $this._tool,
                    @("-v", "error", "-ss", $time, "-i", $file.FullName, "-frames:v", "1", "-y", $framePath),
                    60
                )

                if (-not [System.IO.File]::Exists($framePath)) {
                    continue
                }

                $text = $this._imageReader._RunOcr([System.IO.FileInfo]::new($framePath))

                foreach ($line in $text -split "\r?\n") {
                    $trimmed = $line.Trim()

                    if ($trimmed.Length -gt 0 -and $seen.Add($trimmed)) {
                        $lines.Add($trimmed)
                    }
                }
            }
        }
        finally {
            [System.IO.Directory]::Delete($folder, $true)
        }

        return [string]::Join("`n", $lines)
    }


    # Zeitpunkte jeweils in der Mitte gleich langer Abschnitte, damit weder
    # Vor- noch Abspann überwiegen.
    static [double[]] FrameTimes([double]$duration, [int]$secondsPerFrame, [int]$minFrames, [int]$maxFrames) {
        $count = [int][Math]::Round($duration / [Math]::Max(1, $secondsPerFrame))
        $count = [Math]::Max([Math]::Max(1, $minFrames), [Math]::Min($count, [Math]::Max(1, $maxFrames)))
        $times = [double[]]::new($count)

        for ($i = 0; $i -lt $count; $i++) {
            $times[$i] = $duration * ($i + 0.5) / $count
        }

        return $times
    }


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


    # macOS: Die Dauer liefert AVFoundation selbst. CoreMedia muss vor
    # AVFoundation importiert werden, sonst kennt JavaScript den Zeittyp
    # CMTime nicht. AVURLAsset und AVAssetImageGenerator werden über
    # NSClassFromString geholt, weil sie nicht direkt unter $ erscheinen.
    # Jede Zeile wird nur einmal ausgegeben, auch wenn sie auf mehreren
    # Bildern steht (z. B. dieselbe Folie).
    hidden static [string]$FrameScript = @'
ObjC.import('Foundation');
ObjC.import('CoreMedia');
ObjC.import('AVFoundation');
ObjC.import('Vision');

function recognize(image) {
    const request = $.VNRecognizeTextRequest.alloc.init;
    request.recognitionLevel = 0;
    request.usesLanguageCorrection = true;
    request.recognitionLanguages = $(['de-DE', 'en-US']);

    const handler = $.VNImageRequestHandler.alloc.initWithCGImageOptions(image, $({}));

    if (!handler.performRequestsError($([request]), Ref())) {
        return [];
    }

    const results = request.results;
    const lines = [];

    for (let i = 0; i < results.count; i++) {
        const candidates = results.objectAtIndex(i).topCandidates(1);

        if (candidates.count > 0) {
            lines.push(candidates.objectAtIndex(0).string.js);
        }
    }

    return lines;
}

function run(argv) {
    const url = $.NSURL.fileURLWithPath(argv[0]);
    const secondsPerFrame = Math.max(1, parseInt(argv[1]));
    const minFrames = Math.max(1, parseInt(argv[2]));
    const maxFrames = Math.max(1, parseInt(argv[3]));

    const asset = $.NSClassFromString('AVURLAsset').URLAssetWithURLOptions(url, $());
    const duration = $.CMTimeGetSeconds(asset.duration);

    if (!(duration > 0)) {
        throw new Error('AVFoundation could not read the video.');
    }

    const generator = $.NSClassFromString('AVAssetImageGenerator').assetImageGeneratorWithAsset(asset);
    generator.appliesPreferredTrackTransform = true;

    const count = Math.max(minFrames, Math.min(Math.round(duration / secondsPerFrame), maxFrames));
    const seen = {};
    const lines = [];

    for (let i = 0; i < count; i++) {
        const time = $.CMTimeMakeWithSeconds(duration * (i + 0.5) / count, 600);
        const image = generator.copyCGImageAtTimeActualTimeError(time, null, null);

        if (!image) {
            continue;
        }

        for (const line of recognize(image)) {
            if (!seen[line]) {
                seen[line] = true;
                lines.push(line);
            }
        }
    }

    return lines.join('\n');
}
'@
}

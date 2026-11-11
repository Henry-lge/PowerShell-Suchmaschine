#requires -Version 7.4


# =============================================================================
# OBJEKTERKENNUNG MIT YOLO26
# =============================================================================

# Erkennt, was auf einem Foto zu sehen ist (z. B. "cat", "car", "person"), mit
# dem Modell YOLO26n von Ultralytics. Es kennt die 80 Objektklassen des
# COCO-Datensatzes. Verwendet unter Windows und Linux; unter macOS übernimmt
# das die eingebaute Bildklassifizierung von Vision (siehe
# ImageOcrContentReader).
#
# Ablauf ohne Python, nur mit .NET-Bibliotheken (Install-Yolo.ps1 lädt sie
# beim ersten Gebrauch nach lib/yolo):
#   1. ImageSharp dekodiert das Bild, verkleinert es auf 640 x 640 Pixel und
#      füllt den Rest grau auf ("Letterbox"), wie beim Training des Modells.
#   2. Die Pixel werden als PPM gespeichert; das ist ein kurzer Kopf und
#      danach die reinen RGB-Bytes, die direkt ins Modell gehen.
#   3. ONNX Runtime führt das Modell aus. Das Umrechnen der Bytes in
#      Gleitkommazahlen (0 bis 1) steckt im Modell selbst (siehe
#      Models/export_yolo.py): In PowerShell dauert eine Schleife über
#      1,2 Millionen Werte mehrere Sekunden, im Modell Millisekunden.
#   4. Ausgabe: 300 Zeilen mit x1, y1, x2, y2, Wahrscheinlichkeit, Klasse.
#      YOLO26 braucht keine Nachbearbeitung (NMS), doppelte Treffer
#      entfernt das Modell selbst.
#
# Funktionen statt einer Klasse: ImageSharp und ONNX Runtime werden erst zur
# Laufzeit geladen. In Funktionen löst PowerShell ihre Typen beim Ausführen
# auf, in Klassenmethoden dagegen schon beim Laden des Moduls.
#
# Lizenz: Die YOLO-Modelle von Ultralytics stehen unter AGPL-3.0.


# Formate, die ImageSharp dekodieren kann.
$script:YoloExtensions = @(".jpg", ".jpeg", ".png", ".gif", ".bmp", ".tif", ".tiff", ".webp")

# Die 80 COCO-Klassen in der Reihenfolge der Klassennummern des Modells.
$script:ClassNames = @(
    "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat",
    "traffic light", "fire hydrant", "stop sign", "parking meter", "bench", "bird", "cat",
    "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe", "backpack",
    "umbrella", "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard", "sports ball",
    "kite", "baseball bat", "baseball glove", "skateboard", "surfboard", "tennis racket",
    "bottle", "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple",
    "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair",
    "couch", "potted plant", "bed", "dining table", "toilet", "tv", "laptop", "mouse",
    "remote", "keyboard", "cell phone", "microwave", "oven", "toaster", "sink",
    "refrigerator", "book", "clock", "vase", "scissors", "teddy bear", "hair drier",
    "toothbrush"
)

# Deutsche Namen in derselben Reihenfolge, damit auch eine Suche nach
# "Katze" ein Foto mit "cat" findet.
$script:GermanNames = @(
    "Person", "Fahrrad", "Auto", "Motorrad", "Flugzeug", "Bus", "Zug", "Lastwagen", "Boot",
    "Ampel", "Hydrant", "Stoppschild", "Parkuhr", "Bank", "Vogel", "Katze",
    "Hund", "Pferd", "Schaf", "Kuh", "Elefant", "Bär", "Zebra", "Giraffe", "Rucksack",
    "Regenschirm", "Handtasche", "Krawatte", "Koffer", "Frisbee", "Ski", "Snowboard", "Ball",
    "Drachen", "Baseballschläger", "Baseballhandschuh", "Skateboard", "Surfbrett", "Tennisschläger",
    "Flasche", "Weinglas", "Tasse", "Gabel", "Messer", "Löffel", "Schüssel", "Banane", "Apfel",
    "Sandwich", "Orange", "Brokkoli", "Karotte", "Hotdog", "Pizza", "Donut", "Kuchen", "Stuhl",
    "Sofa", "Topfpflanze", "Bett", "Esstisch", "Toilette", "Fernseher", "Laptop", "Maus",
    "Fernbedienung", "Tastatur", "Handy", "Mikrowelle", "Ofen", "Toaster", "Waschbecken",
    "Kühlschrank", "Buch", "Uhr", "Vase", "Schere", "Teddybär", "Föhn",
    "Zahnbürste"
)

# Standardorte: Bibliotheken in lib/yolo (nicht im Repository, wird beim
# ersten Gebrauch installiert), Modell neben diesem Modul.
$script:DefaultLibraryPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "../../../../lib/yolo"))
$script:DefaultModelPath = Join-Path $PSScriptRoot "Models/yolo26n.onnx"

# Zustand des geladenen Modells in diesem Runspace.
$script:Yolo = $null

# Handle der nativen ONNX Runtime; einmal pro Prozess geladen.
$script:NativeHandle = [IntPtr]::Zero


# Installiert beim ersten Aufruf ONNX Runtime und ImageSharp, lädt sie und
# öffnet das Modell. Wirft eine Ausnahme, wenn das nicht geht (z. B. ohne
# Internet beim ersten Mal).
function Initialize-YoloDetector {
    param(
        [string]$LibraryPath = $script:DefaultLibraryPath,
        [string]$ModelPath = $script:DefaultModelPath
    )

    if ($null -ne $script:Yolo) {
        return
    }

    if (-not [System.IO.File]::Exists($ModelPath)) {
        throw "YOLO model not found: $ModelPath"
    }

    & (Join-Path $PSScriptRoot "Install-Yolo.ps1") -Destination $LibraryPath
    Import-YoloLibrary -LibraryPath $LibraryPath

    # OrtValue.CreateTensorValueFromMemory<T>(T[], long[]) legt einen Tensor
    # direkt über ein .NET-Array, ohne zu kopieren. Andere Wege erwarten
    # Span<T>, das PowerShell nicht übergeben kann.
    $create = [Microsoft.ML.OnnxRuntime.OrtValue].GetMethods() |
        Where-Object {
            $_.Name -eq "CreateTensorValueFromMemory" -and
            $_.IsGenericMethodDefinition -and
            $_.GetParameters().Count -eq 2 -and
            $_.GetParameters()[0].ParameterType.IsArray
        } |
        Select-Object -First 1

    # Das Ergebnis schreibt ONNX Runtime direkt in dieses Array.
    $output = [float[]]::new(300 * 6)
    $outputValue = $create.MakeGenericMethod([float]).Invoke($null, @($output, [long[]]@(1, 300, 6)))

    # JPEG kann schon beim Dekodieren verkleinert werden; das spart den
    # größten Teil der Zeit bei großen Fotos.
    $decoderOptions = [SixLabors.ImageSharp.Formats.DecoderOptions]::new()
    $decoderOptions.TargetSize = [SixLabors.ImageSharp.Size]::new(640, 640)

    # Auf 640 x 640 einpassen, Rand grau (114, 114, 114) wie beim Training.
    $resizeOptions = [SixLabors.ImageSharp.Processing.ResizeOptions]::new()
    $resizeOptions.Size = [SixLabors.ImageSharp.Size]::new(640, 640)
    $resizeOptions.Mode = [SixLabors.ImageSharp.Processing.ResizeMode]::Pad
    $resizeOptions.PadColor = [SixLabors.ImageSharp.Color]::FromPixel(
        [SixLabors.ImageSharp.PixelFormats.Rgb24]::new(114, 114, 114)
    )

    # PPM: binär, RGB, 8 Bit pro Farbwert (Standard wären 16 Bit).
    $ppmEncoder = [SixLabors.ImageSharp.Formats.Pbm.PbmEncoder]::new()
    $ppmEncoder.ColorType = [SixLabors.ImageSharp.Formats.Pbm.PbmColorType]::Rgb
    $ppmEncoder.Encoding = [SixLabors.ImageSharp.Formats.Pbm.PbmEncoding]::Binary
    $ppmEncoder.ComponentType = [SixLabors.ImageSharp.Formats.Pbm.PbmComponentType]::Byte

    $script:Yolo = @{
        Session        = [Microsoft.ML.OnnxRuntime.InferenceSession]::new($ModelPath)
        RunOptions     = [Microsoft.ML.OnnxRuntime.RunOptions]::new()
        CreateBytes    = $create.MakeGenericMethod([byte])
        Output         = $output
        OutputValue    = $outputValue
        DecoderOptions = $decoderOptions
        Resize         = [Action[SixLabors.ImageSharp.Processing.IImageProcessingContext]] {
            param($context)
            [void][SixLabors.ImageSharp.Processing.ResizeExtensions]::Resize($context, $resizeOptions)
        }.GetNewClosure()
        PpmEncoder     = $ppmEncoder
    }
}


# Gibt die Klassennummern der erkannten Objekte zurück, jede nur einmal,
# nach Wahrscheinlichkeit sortiert.
function Find-YoloObject {
    param(
        [Parameter(Mandatory)][string]$Path,
        [double]$MinConfidence = 0.4
    )

    if ($null -eq $script:Yolo) {
        throw "Initialize-YoloDetector must be called first."
    }

    $state = $script:Yolo
    $pixels = Get-YoloPixel -Path $Path
    $inputValue = $state.CreateBytes.Invoke($null, @($pixels, [long[]]@(1, 640, 640, 3)))

    try {
        # Typisierte Arrays, damit die Überladung von Run mit vorbereitetem
        # Ergebnis-Tensor gewählt wird.
        $state.Session.Run(
            $state.RunOptions,
            [string[]]@("rgb"),
            [Microsoft.ML.OnnxRuntime.OrtValue[]]@($inputValue),
            [string[]]@("output0"),
            [Microsoft.ML.OnnxRuntime.OrtValue[]]@($state.OutputValue)
        )
    }
    finally {
        $inputValue.Dispose()
    }

    $output = $state.Output
    $best = @{}

    for ($i = 0; $i -lt 300; $i++) {
        $score = $output[$i * 6 + 4]

        if ($score -lt $MinConfidence) {
            continue
        }

        $class = [int]$output[$i * 6 + 5]

        if (-not $best.ContainsKey($class) -or $score -gt $best[$class]) {
            $best[$class] = $score
        }
    }

    return [int[]]@($best.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object Key)
}


# Text für den Index, z. B. "cat (Katze), person (Person)".
function Format-YoloLabel {
    param([int[]]$Classes)

    $labels = foreach ($class in $Classes) {
        if ($class -lt 0 -or $class -ge $script:ClassNames.Length) {
            continue
        }

        Format-ObjectLabel -Label $script:ClassNames[$class]
    }

    return (@($labels) -join ", ")
}


# "cat" -> "cat (Katze)", wenn es eine COCO-Klasse mit deutschem Namen ist;
# auch für die Begriffe der macOS-Bildklassifizierung verwendet. Unterstriche
# (z. B. "sports_car") werden zu Leerzeichen.
function Format-ObjectLabel {
    param([string]$Label)

    $english = $Label.Replace("_", " ")
    $index = [Array]::IndexOf($script:ClassNames, $english.ToLowerInvariant())

    if ($index -lt 0 -or $script:GermanNames[$index] -eq $english) {
        return $english
    }

    return "$english ($($script:GermanNames[$index]))"
}


# True, wenn das Modell vorhanden ist (die Bibliotheken werden bei Bedarf
# installiert).
function Test-YoloModel {
    return [System.IO.File]::Exists($script:DefaultModelPath)
}


function Test-YoloExtension {
    param([string]$Extension)

    return $Extension.ToLowerInvariant() -in $script:YoloExtensions
}


function Close-YoloDetector {
    if ($null -eq $script:Yolo) {
        return
    }

    $script:Yolo.OutputValue.Dispose()
    $script:Yolo.RunOptions.Dispose()
    $script:Yolo.Session.Dispose()
    $script:Yolo = $null
}


# Bild -> 640 x 640 RGB-Bytes (Zeile für Zeile von oben, je Pixel R, G, B).
function Get-YoloPixel {
    param([string]$Path)

    $state = $script:Yolo
    $image = [SixLabors.ImageSharp.Image]::Load($state.DecoderOptions, $Path)
    $stream = [System.IO.MemoryStream]::new()

    try {
        [SixLabors.ImageSharp.Processing.ProcessingExtensions]::Mutate($image, $state.Resize)
        [SixLabors.ImageSharp.ImageExtensions]::SaveAsPbm($image, $stream, $state.PpmEncoder)
    }
    finally {
        $image.Dispose()
    }

    # Der PPM-Kopf ("P6 640 640 255") steht vorn; die Pixel sind die
    # letzten 640 * 640 * 3 Bytes.
    $all = $stream.ToArray()
    $pixels = [byte[]]::new(640 * 640 * 3)
    [Array]::Copy($all, $all.Length - $pixels.Length, $pixels, 0, $pixels.Length)

    return , $pixels
}


# Lädt die .NET-Bibliotheken und die native ONNX Runtime. Die verwaltete
# Bibliothek sucht die native über ihren Namen ("onnxruntime"); ein Resolver
# gibt ihr das bereits geladene Handle, weil lib/yolo nicht im Suchpfad des
# Systems liegt.
function Import-YoloLibrary {
    param([string]$LibraryPath)

    foreach ($name in "System.Numerics.Tensors", "System.IO.Hashing", "Microsoft.ML.OnnxRuntime", "SixLabors.ImageSharp") {
        $loaded = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq $name }

        if ($null -eq $loaded) {
            [void][System.Reflection.Assembly]::LoadFrom((Join-Path $LibraryPath "$name.dll"))
        }
    }

    if ($script:NativeHandle -ne [IntPtr]::Zero) {
        return
    }

    $nativeName = if ($IsWindows) { "onnxruntime.dll" } elseif ($IsMacOS) { "libonnxruntime.dylib" } else { "libonnxruntime.so" }
    $handle = [System.Runtime.InteropServices.NativeLibrary]::Load((Join-Path $LibraryPath $nativeName))
    $script:NativeHandle = $handle

    $onnxAssembly = [AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object { $_.GetName().Name -eq "Microsoft.ML.OnnxRuntime" } |
        Select-Object -First 1

    try {
        [System.Runtime.InteropServices.NativeLibrary]::SetDllImportResolver(
            $onnxAssembly,
            [System.Runtime.InteropServices.DllImportResolver] {
                param($libraryName, $assembly, $searchPath)

                if ($libraryName -like "*onnxruntime*") {
                    return $handle
                }

                return [IntPtr]::Zero
            }.GetNewClosure()
        )
    }
    catch [System.InvalidOperationException] {
        # Ein Resolver ist pro Prozess nur einmal möglich; schon gesetzt.
    }
}


Export-ModuleMember -Function Initialize-YoloDetector, Find-YoloObject, Format-YoloLabel, Format-ObjectLabel, Test-YoloModel, Test-YoloExtension, Close-YoloDetector

#requires -Version 7.4

# Richtet die Laufzeit für die Objekterkennung mit YOLO26 ein: ONNX Runtime
# (führt das Modell aus) und ImageSharp (dekodiert und verkleinert Bilder auf
# allen Plattformen). Die NuGet-Pakete werden beim ersten Aufruf
# heruntergeladen und nach $Destination entpackt (lib/yolo, nicht im
# Repository). Gleicher Ablauf wie Install-Sqlite.ps1 der Datenbankgruppe.
#
# Das Paket mit der nativen ONNX Runtime enthält alle Plattformen und ist
# etwa 160 MB groß; übernommen wird nur die Bibliothek der eigenen Plattform.

param(
    [Parameter(Mandatory)]
    [string]$Destination,

    [string]$OnnxRuntimeVersion = "1.31.1",

    [string]$ImageSharpVersion = "4.1.3"
)

$requiredAssemblies = @(
    "Microsoft.ML.OnnxRuntime.dll",
    "System.Numerics.Tensors.dll",
    "SixLabors.ImageSharp.dll",
    "System.IO.Hashing.dll"
)

$architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()

if ($IsWindows) {
    $runtimeIdentifier = "win-$architecture"
    $nativeLibraryName = "onnxruntime.dll"
}
elseif ($IsMacOS) {
    $runtimeIdentifier = "osx-$architecture"
    $nativeLibraryName = "libonnxruntime.dylib"
}
elseif ($IsLinux) {
    $runtimeIdentifier = "linux-$architecture"
    $nativeLibraryName = "libonnxruntime.so"
}
else {
    throw "YOLO runtime installation is not supported on this operating system."
}

$versionFile = Join-Path $Destination "yolo-runtime.version"
$expectedVersion = "$OnnxRuntimeVersion+$ImageSharpVersion+$runtimeIdentifier"

$installed = (
    (Test-Path -LiteralPath $versionFile -PathType Leaf) -and
    (Get-Content -LiteralPath $versionFile -Raw).Trim() -eq $expectedVersion -and
    (Test-Path -LiteralPath (Join-Path $Destination $nativeLibraryName) -PathType Leaf) -and
    ($requiredAssemblies | ForEach-Object {
        Test-Path -LiteralPath (Join-Path $Destination $_) -PathType Leaf
    }) -notcontains $false
)

if ($installed) {
    return
}

# Paket, Version und der Ordner im Paket, aus dem die DLL stammt.
$packages = @(
    @{ Name = "Microsoft.ML.OnnxRuntime.Managed"; Version = $OnnxRuntimeVersion; Folder = "lib/net8.0" }
    @{ Name = "Microsoft.ML.OnnxRuntime"; Version = $OnnxRuntimeVersion; Folder = "runtimes/$runtimeIdentifier/native" }
    @{ Name = "System.Numerics.Tensors"; Version = "9.0.0"; Folder = "lib/net8.0" }
    @{ Name = "SixLabors.ImageSharp"; Version = $ImageSharpVersion; Folder = "lib/net8.0" }
    @{ Name = "System.IO.Hashing"; Version = "8.0.0"; Folder = "lib/net8.0" }
)

$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) (
    "powershell-suchmaschine-yolo-" + [guid]::NewGuid().ToString("N")
)

try {
    [System.IO.Directory]::CreateDirectory($temporaryDirectory) | Out-Null
    [System.IO.Directory]::CreateDirectory($Destination) | Out-Null

    foreach ($package in $packages) {
        $packageName = $package.Name.ToLowerInvariant()
        $packagePath = Join-Path $temporaryDirectory "$packageName.nupkg"
        $packageDirectory = Join-Path $temporaryDirectory $packageName
        $packageUrl = (
            "https://api.nuget.org/v3-flatcontainer/" +
            "$packageName/$($package.Version)/$packageName.$($package.Version).nupkg"
        )

        Invoke-WebRequest -Uri $packageUrl -OutFile $packagePath
        [System.IO.Compression.ZipFile]::ExtractToDirectory($packagePath, $packageDirectory)

        $sourceFolder = Join-Path $packageDirectory $package.Folder
        $files = @(
            Get-ChildItem -LiteralPath $sourceFolder -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in ".dll", ".dylib", ".so" }
        )

        if ($files.Count -eq 0) {
            throw "No library found in $($package.Name) under $($package.Folder)."
        }

        foreach ($file in $files) {
            Copy-Item -LiteralPath $file.FullName -Destination $Destination -Force
        }
    }

    foreach ($required in $requiredAssemblies + $nativeLibraryName) {
        if (-not (Test-Path -LiteralPath (Join-Path $Destination $required) -PathType Leaf)) {
            throw "Required file was not installed: $required"
        }
    }

    Set-Content -LiteralPath $versionFile -Value $expectedVersion -NoNewline
}
catch {
    throw "YOLO runtime installation failed: $($_.Exception.Message)"
}
finally {
    if (Test-Path -LiteralPath $temporaryDirectory) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
}

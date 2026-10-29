#requires -Version 7.2

param(
    [Parameter(Mandatory)]
    [string]$Destination,

    [string]$MicrosoftDataSqliteVersion = "8.0.33",

    [string]$SqlitePclRawVersion = "2.1.13"
)

$requiredAssemblies = @(
    "Microsoft.Data.Sqlite.dll",
    "SQLitePCLRaw.core.dll",
    "SQLitePCLRaw.provider.e_sqlite3.dll",
    "SQLitePCLRaw.batteries_v2.dll"
)

$architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::Windows
)) {
    $runtimeIdentifier = "win-$architecture"
}
elseif ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::OSX
)) {
    $runtimeIdentifier = "osx-$architecture"
}
elseif ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::Linux
)) {
    $runtimeIdentifier = "linux-$architecture"
}
else {
    throw "SQLite runtime installation is not supported on this operating system."
}

$nativeLibraryName = switch -Regex ($runtimeIdentifier) {
    "^win-" { "e_sqlite3.dll"; break }
    "^osx-" { "libe_sqlite3.dylib"; break }
    "^linux-" { "libe_sqlite3.so"; break }
}

$versionFile = Join-Path $Destination "sqlite-runtime.version"
$expectedVersion = "$MicrosoftDataSqliteVersion+$SqlitePclRawVersion+$runtimeIdentifier"

if (
    (Test-Path -LiteralPath $versionFile -PathType Leaf) -and
    (Get-Content -LiteralPath $versionFile -Raw).Trim() -eq $expectedVersion -and
    ($requiredAssemblies | ForEach-Object {
        Test-Path -LiteralPath (Join-Path $Destination $_) -PathType Leaf
    }) -notcontains $false -and
    (Test-Path -LiteralPath (Join-Path $Destination $nativeLibraryName) -PathType Leaf)
) {
    return
}

$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) (
    "powershell-suchmaschine-sqlite-" + [guid]::NewGuid().ToString("N")
)

$packages = @(
    @{
        Name = "Microsoft.Data.Sqlite.Core"
        Version = $MicrosoftDataSqliteVersion
    },
    @{
        Name = "SQLitePCLRaw.bundle_e_sqlite3"
        Version = $SqlitePclRawVersion
    },
    @{
        Name = "SQLitePCLRaw.core"
        Version = $SqlitePclRawVersion
    },
    @{
        Name = "SQLitePCLRaw.provider.e_sqlite3"
        Version = $SqlitePclRawVersion
    },
    @{
        Name = "SQLitePCLRaw.lib.e_sqlite3"
        Version = $SqlitePclRawVersion
    }
)

try {
    [System.IO.Directory]::CreateDirectory($temporaryDirectory) | Out-Null
    $packageDirectories = @{}

    foreach ($package in $packages) {
        $packageName = $package.Name.ToLowerInvariant()
        $packagePath = Join-Path $temporaryDirectory "$packageName.nupkg"
        $packageDirectory = Join-Path $temporaryDirectory $packageName
        $packageUrl = (
            "https://api.nuget.org/v3-flatcontainer/" +
            "$packageName/$($package.Version)/$packageName.$($package.Version).nupkg"
        )

        Invoke-WebRequest -Uri $packageUrl -OutFile $packagePath
        [System.IO.Compression.ZipFile]::ExtractToDirectory(
            $packagePath,
            $packageDirectory
        )
        $packageDirectories[$package.Name] = $packageDirectory
    }

    $assemblies = @(
        foreach ($packageDirectory in $packageDirectories.Values) {
            Get-ChildItem -LiteralPath (Join-Path $packageDirectory "lib/netstandard2.0") `
                -Filter "*.dll" -File -ErrorAction SilentlyContinue
        }
    )

    foreach ($requiredAssembly in $requiredAssemblies) {
        if ($assemblies.Name -notcontains $requiredAssembly) {
            throw "Required assembly was not found in the downloaded NuGet packages: $requiredAssembly"
        }
    }

    $nativeLibrary = Join-Path $packageDirectories["SQLitePCLRaw.lib.e_sqlite3"] (
        "runtimes/$runtimeIdentifier/native/$nativeLibraryName"
    )
    if (-not (Test-Path -LiteralPath $nativeLibrary -PathType Leaf)) {
        throw "SQLite native library is not available for runtime $runtimeIdentifier."
    }

    [System.IO.Directory]::CreateDirectory($Destination) | Out-Null
    foreach ($assembly in $assemblies) {
        Copy-Item -LiteralPath $assembly.FullName -Destination $Destination -Force
    }
    Copy-Item -LiteralPath $nativeLibrary `
        -Destination (Join-Path $Destination $nativeLibraryName) -Force
    Set-Content -LiteralPath $versionFile -Value $expectedVersion -NoNewline
}
catch {
    throw "SQLite installation failed: $($_.Exception.Message)"
}
finally {
    if (Test-Path -LiteralPath $temporaryDirectory) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
}

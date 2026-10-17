#requires -Version 7.2

param(
    [Parameter(Mandatory)]
    [string]$Destination,

    [string]$Version = "4.8.0-beta00016"
)

$requiredAssemblies = @(
    "Lucene.Net.dll",
    "Lucene.Net.Analysis.Common.dll",
    "J2N.dll",
    "Microsoft.Extensions.Configuration.Abstractions.dll",
    "Microsoft.Extensions.Primitives.dll",
    "Prism.dll"
)

if (
    (Test-Path -LiteralPath $Destination -PathType Container) -and
    ($requiredAssemblies | ForEach-Object {
        Test-Path -LiteralPath (Join-Path $Destination $_) -PathType Leaf
    }) -notcontains $false
) {
    return
}

$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) (
    "powershell-suchmaschine-lucene-" + [guid]::NewGuid().ToString("N")
)

try {
    New-Item -ItemType Directory -Path $temporaryDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null

    $packages = @(
        @{ Name = "Lucene.Net"; Version = $Version },
        @{ Name = "Lucene.Net.Analysis.Common"; Version = $Version },
        @{ Name = "J2N"; Version = "2.0.0" },
        @{ Name = "Microsoft.Extensions.Configuration.Abstractions"; Version = "2.0.0" },
        @{ Name = "Microsoft.Extensions.Primitives"; Version = "2.0.0" },
        @{ Name = "Prism.Core"; Version = "7.2.0.1422" }
    )

    foreach ($package in $packages) {
        $packagePath = Join-Path $temporaryDirectory "$($package.Name).nupkg"
        $packageUrl = (
            "https://www.nuget.org/api/v2/package/" +
            "$($package.Name)/$($package.Version)"
        )

        Write-Host "Downloading $($package.Name) $($package.Version)..."
        Invoke-WebRequest -Uri $packageUrl -OutFile $packagePath
        Expand-Archive -LiteralPath $packagePath `
        -DestinationPath (Join-Path $temporaryDirectory $package.Name) `
        -Force

        $assemblies = @(Get-ChildItem -LiteralPath (
            Join-Path $temporaryDirectory $package.Name
        ) -Filter "*.dll" -File -Recurse |
        Where-Object FullName -match "[\\/]netstandard2\.0[\\/]")

        if ($assemblies.Count -eq 0) {
        throw "Could not find netstandard2.0 assemblies in the NuGet package."
        }

        foreach ($assembly in $assemblies) {
        Copy-Item -LiteralPath $assembly.FullName -Destination $Destination `
            -Force
        }
    }
}
catch {
    throw "Lucene.Net installation failed: $($_.Exception.Message)"
}
finally {
    if (Test-Path -LiteralPath $temporaryDirectory) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
}

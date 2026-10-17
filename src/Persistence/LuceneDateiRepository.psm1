using module "../Common/PathUtil.psm1"
using module "../Model/Datei.psm1"
using module "./DateiRepository.psm1"

#requires -Version 7.2

# Lucene.Net wird beim Start von suchmaschine.ps1 automatisch aus NuGet
# installiert. Der Konstruktor erwartet den Ordner mit den DLLs; bei eigener
# Verwendung können die beiden Pakete Lucene.Net und
# Lucene.Net.Analysis.Common dort vorher abgelegt werden.
# Beispiel:
#   $repository = [LuceneDateiRepository]::new(
#       "./data/index", "./lib/lucene"
#   )
#   $crawler.Repository = $repository
#   # Nach dem letzten Scan: $repository.Dispose()
function Initialize-LuceneNet {
    param([Parameter(Mandatory)][string]$AssemblyPath)

    $directory = if ([System.IO.File]::Exists($AssemblyPath)) {
        [System.IO.Path]::GetDirectoryName($AssemblyPath)
    }
    else {
        $AssemblyPath
    }

    if (-not [System.IO.Directory]::Exists($directory)) {
        throw "Lucene.Net assembly directory does not exist: $directory"
    }

    $assemblies = @(
        Get-ChildItem -LiteralPath $directory -Filter "*.dll" -File |
            Sort-Object @{ Expression = {
                if ($_.Name -eq "Lucene.Net.dll") { 0 } else { 1 }
            } }, Name
    )

    $luceneAssembly = $assemblies | Where-Object Name -eq "Lucene.Net.dll"
    $commonAssembly = $assemblies | Where-Object Name -eq "Lucene.Net.Analysis.Common.dll"

    if ($null -eq $luceneAssembly -or $null -eq $commonAssembly) {
        throw (
            "The assembly directory must contain Lucene.Net.dll and " +
            "Lucene.Net.Analysis.Common.dll."
        )
    }

    foreach ($assemblyFile in $assemblies) {
        $alreadyLoaded = [System.AppDomain]::CurrentDomain.GetAssemblies() |
            Where-Object Location -eq $assemblyFile.FullName

        if ($null -eq $alreadyLoaded) {
            [void][System.Reflection.Assembly]::LoadFrom($assemblyFile.FullName)
        }
    }
}

function Get-LuceneType([string]$Name) {
    $assembly = [System.AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object { $_.GetType($Name, $false) } |
        Select-Object -First 1
    if ($null -eq $assembly) {
        throw "Lucene.Net type is not available: $Name"
    }
    return $assembly.GetType($Name, $true)
}

function New-LuceneObject([string]$Name, [object[]]$Arguments) {
    $instance = [System.Activator]::CreateInstance(
        (Get-LuceneType $Name), $Arguments
    )
    return ,$instance
}

function Invoke-LuceneStatic(
    [string]$TypeName,
    [string]$MethodName,
    [object[]]$Arguments
) {
    $type = Get-LuceneType $TypeName
    $method = $type.GetMethods() |
        Where-Object {
            if (
                $_.Name -ne $MethodName -or
                $_.GetParameters().Count -ne $Arguments.Count
            ) {
                return $false
            }

            $parameters = $_.GetParameters()
            for ($i = 0; $i -lt $parameters.Count; $i++) {
                $argument = $Arguments[$i]
                if ($null -eq $argument) {
                    if ($parameters[$i].ParameterType.IsValueType) {
                        return $false
                    }
                    continue
                }

                if (-not $parameters[$i].ParameterType.IsInstanceOfType($argument)) {
                    return $false
                }
            }

            return $true
        } |
        Select-Object -First 1
    if ($null -eq $method) {
        throw "Lucene.Net method is not available: $TypeName.$MethodName"
    }
    return $method.Invoke($null, $Arguments)
}


class LuceneDateiRepository : DateiRepository {

    hidden static [string]$PathField = "path"
    hidden static [string]$NameField = "name"
    hidden static [string]$ExtensionField = "extension"
    hidden static [string]$SizeField = "size"
    hidden static [string]$CreationTimeField = "creationTimeUtcTicks"
    hidden static [string]$LastWriteTimeField = "lastWriteTimeUtcTicks"
    hidden static [string]$IndexedAtField = "indexedAtUtcTicks"
    hidden static [string]$ContentField = "content"
    hidden static [string]$HasContentField = "hasContent"
    hidden static [string]$CloudOnlyField = "isCloudOnly"

    hidden [object]$_directory
    hidden [object]$_writer
    hidden [string]$_indexPath
    hidden [bool]$_disposed = $false


    LuceneDateiRepository([string]$indexPath, [string]$assemblyPath) {
        if ([string]::IsNullOrWhiteSpace($indexPath)) {
            throw "Index path must not be empty."
        }

        Initialize-LuceneNet -AssemblyPath $assemblyPath

        $this._indexPath = [PathUtil]::Normalize($indexPath)
        [System.IO.Directory]::CreateDirectory($this._indexPath) | Out-Null
        $this._directory = Invoke-LuceneStatic `
            "Lucene.Net.Store.FSDirectory" "Open" @(
                [System.IO.DirectoryInfo]::new($this._indexPath)
            )

        $version = (Get-LuceneType "Lucene.Net.Util.LuceneVersion").GetField(
            "LUCENE_48"
        ).GetValue($null)
        $analyzer = New-LuceneObject "Lucene.Net.Analysis.Standard.StandardAnalyzer" @(
            $version
        )
        $config = New-LuceneObject "Lucene.Net.Index.IndexWriterConfig" @(
            $version, $analyzer
        )
        $config.OpenMode = [System.Enum]::Parse(
            (Get-LuceneType "Lucene.Net.Index.OpenMode"), "CREATE_OR_APPEND"
        )
        $this._writer = New-LuceneObject "Lucene.Net.Index.IndexWriter" @(
            $this._directory, $config
        )
    }


    [Datei] Get([string]$path) {
        $this.EnsureOpen()
        $normalizedPath = [PathUtil]::Normalize($path)
        $reader = Invoke-LuceneStatic `
            "Lucene.Net.Index.DirectoryReader" "Open" @($this._writer, $false)

        try {
            $searcher = New-LuceneObject "Lucene.Net.Search.IndexSearcher" @($reader)
            $query = New-LuceneObject "Lucene.Net.Search.TermQuery" @(
                (New-LuceneObject "Lucene.Net.Index.Term" @(
                    [LuceneDateiRepository]::PathField,
                    $normalizedPath
                ))
            )
            $hits = $searcher.Search($query, 1).ScoreDocs

            if ($hits.Length -eq 0) {
                return $null
            }

            return $this.DocumentToDatei($searcher.Doc($hits[0].Doc))
        }
        finally {
            $reader.Dispose()
        }
    }


    [void] Save([Datei]$datei) {
        $this.SaveBatch(@($datei))
    }


    [void] SaveBatch([Datei[]]$dateien) {
        $this.EnsureOpen()

        foreach ($datei in $dateien) {
            if ($null -eq $datei -or [string]::IsNullOrWhiteSpace($datei.Path)) {
                throw "A Datei with a non-empty Path is required."
            }

            $document = $this.DateiToDocument($datei)
            $term = New-LuceneObject "Lucene.Net.Index.Term" @(
                [LuceneDateiRepository]::PathField,
                [PathUtil]::Normalize($datei.Path)
            )
            $this._writer.UpdateDocument($term, $document)
        }

        $this._writer.Commit()
    }


    [void] Remove([string]$path) {
        $this.EnsureOpen()
        $term = New-LuceneObject "Lucene.Net.Index.Term" @(
            [LuceneDateiRepository]::PathField,
            [PathUtil]::Normalize($path)
        )
        $this._writer.DeleteDocuments($term)
        $this._writer.Commit()
    }


    [string[]] GetPathsUnder([string]$folderPath) {
        $this.EnsureOpen()
        $folder = [PathUtil]::Normalize($folderPath)
        $reader = Invoke-LuceneStatic `
            "Lucene.Net.Index.DirectoryReader" "Open" @($this._writer, $false)

        try {
            if ($reader.NumDocs -eq 0) {
                return @()
            }

            $searcher = New-LuceneObject "Lucene.Net.Search.IndexSearcher" @($reader)
            $hits = $searcher.Search(
                (New-LuceneObject "Lucene.Net.Search.MatchAllDocsQuery" @()),
                $reader.NumDocs
            ).ScoreDocs
            $paths = [System.Collections.Generic.List[string]]::new()

            foreach ($hit in $hits) {
                $path = $searcher.Doc($hit.Doc).Get(
                    [LuceneDateiRepository]::PathField
                )
                if ([PathUtil]::IsSameOrUnder($path, $folder)) {
                    $paths.Add($path)
                }
            }

            return $paths.ToArray()
        }
        finally {
            $reader.Dispose()
        }
    }


    [void] Dispose() {
        if ($this._disposed) {
            return
        }

        $this._disposed = $true
        if ($null -ne $this._writer) {
            $this._writer.Dispose()
        }
        if ($null -ne $this._directory) {
            $this._directory.Dispose()
        }
    }


    hidden [void] EnsureOpen() {
        if ($this._disposed) {
            throw "LuceneDateiRepository is already disposed."
        }
    }


    hidden [object] DateiToDocument([Datei]$datei) {
        $document = New-LuceneObject "Lucene.Net.Documents.Document" @()
        $storeYes = [System.Enum]::Parse(
            (Get-LuceneType "Lucene.Net.Documents.Field+Store"), "YES"
        )
        $document.Add((New-LuceneObject "Lucene.Net.Documents.StringField" @(
            [LuceneDateiRepository]::PathField,
            [PathUtil]::Normalize($datei.Path),
            $storeYes
        )))
        $document.Add((New-LuceneObject "Lucene.Net.Documents.StoredField" @(
            [LuceneDateiRepository]::NameField, $datei.Name
        )))
        $document.Add((New-LuceneObject "Lucene.Net.Documents.StoredField" @(
            [LuceneDateiRepository]::ExtensionField, $datei.Extension
        )))
        $document.Add((New-LuceneObject "Lucene.Net.Documents.StoredField" @(
            [LuceneDateiRepository]::SizeField, $datei.Size.ToString(
                [System.Globalization.CultureInfo]::InvariantCulture
            )
        )))

        foreach ($field in @(
            @([LuceneDateiRepository]::CreationTimeField, $datei.CreationTimeUtc.Ticks),
            @([LuceneDateiRepository]::LastWriteTimeField, $datei.LastWriteTimeUtc.Ticks),
            @([LuceneDateiRepository]::IndexedAtField, $datei.IndexedAtUtc.Ticks)
        )) {
            $document.Add((New-LuceneObject "Lucene.Net.Documents.StoredField" @(
                $field[0],
                ([long]$field[1]).ToString(
                    [System.Globalization.CultureInfo]::InvariantCulture
                )
            )))
        }

        $document.Add((New-LuceneObject "Lucene.Net.Documents.StoredField" @(
            [LuceneDateiRepository]::HasContentField,
            $datei.HasContent.ToString()
        )))
        $document.Add((New-LuceneObject "Lucene.Net.Documents.StoredField" @(
            [LuceneDateiRepository]::CloudOnlyField,
            $datei.IsCloudOnly.ToString()
        )))
        if ($datei.HasContent) {
            $document.Add((New-LuceneObject "Lucene.Net.Documents.StoredField" @(
                [LuceneDateiRepository]::ContentField,
                $(if ($null -eq $datei.Content) { "" } else { $datei.Content })
            )))
        }

        return $document
    }


    hidden [Datei] DocumentToDatei([object]$document) {
        $datei = [Datei]::new()
        $datei.Path = $document.Get([LuceneDateiRepository]::PathField)
        $datei.Name = $document.Get([LuceneDateiRepository]::NameField)
        $datei.Extension = $document.Get([LuceneDateiRepository]::ExtensionField)
        $datei.Size = [long]::Parse(
            $document.Get([LuceneDateiRepository]::SizeField),
            [System.Globalization.CultureInfo]::InvariantCulture
        )
        $datei.CreationTimeUtc = [datetime]::new([long]::Parse(
            $document.Get([LuceneDateiRepository]::CreationTimeField),
            [System.Globalization.CultureInfo]::InvariantCulture
        ), [System.DateTimeKind]::Utc)
        $datei.LastWriteTimeUtc = [datetime]::new([long]::Parse(
            $document.Get([LuceneDateiRepository]::LastWriteTimeField),
            [System.Globalization.CultureInfo]::InvariantCulture
        ), [System.DateTimeKind]::Utc)
        $datei.IndexedAtUtc = [datetime]::new([long]::Parse(
            $document.Get([LuceneDateiRepository]::IndexedAtField),
            [System.Globalization.CultureInfo]::InvariantCulture
        ), [System.DateTimeKind]::Utc)
        $datei.HasContent = [bool]::Parse(
            $document.Get([LuceneDateiRepository]::HasContentField)
        )
        $datei.IsCloudOnly = [bool]::Parse(
            $document.Get([LuceneDateiRepository]::CloudOnlyField)
        )
        if ($datei.HasContent) {
            $datei.Content = $document.Get([LuceneDateiRepository]::ContentField)
        }

        return $datei
    }
}

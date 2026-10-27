using module "../ContentReader.psm1"

#requires -Version 7.2


# =============================================================================
# READER FÜR EPUB
# =============================================================================

# Liest den Text von E-Books. Ein EPUB ist ein ZIP-Archiv mit XHTML-Kapiteln,
# daher wird kein zusätzliches Tool benötigt und es funktioniert auf jeder
# Plattform.
#
# Aufbau:
#   - META-INF/container.xml   verweist auf die Paketdatei (*.opf)
#   - *.opf                    <metadata> mit dem Titel, <manifest> listet alle
#                              Dateien, <spine> die Kapitel in Lesereihenfolge
#   - *.xhtml / *.html         die Kapitel
#
# Fehlt die Paketdatei oder ist sie defekt, werden stattdessen alle
# HTML-Dateien des Archivs in Namensreihenfolge gelesen.
class EpubContentReader : ContentReader {

    EpubContentReader() {
        $this.Description = "E-books (EPUB)"
        $this.Extensions = @(".epub")
    }


    [string] ReadContent([System.IO.FileInfo]$file) {
        $zip = $this.OpenZip($file)

        try {
            $parts = [System.Collections.Generic.List[string]]::new()
            $chapterPaths = [System.Collections.Generic.List[string]]::new()

            $packagePath = $this._FindPackagePath($zip)

            if (-not [string]::IsNullOrEmpty($packagePath)) {
                $this._ReadPackage($zip, $packagePath, $parts, $chapterPaths)
            }

            # Ersatzweg ohne brauchbare Paketdatei.
            if ($chapterPaths.Count -eq 0) {
                foreach ($pattern in @("*.xhtml", "*.html", "*.htm")) {
                    foreach ($path in $this.FindZipEntries($zip, $pattern)) {
                        $chapterPaths.Add($path)
                    }
                }
            }

            foreach ($chapterPath in $chapterPaths) {
                $text = $this.ConvertHtmlToText($this.ReadZipEntry($zip, $chapterPath))

                if (-not [string]::IsNullOrWhiteSpace($text)) {
                    $parts.Add($text)
                }
            }

            return $parts -join "`n`n"
        }
        finally {
            $zip.Dispose()
        }
    }


    # Pfad der Paketdatei (*.opf), wie in META-INF/container.xml angegeben.
    hidden [string] _FindPackagePath([System.IO.Compression.ZipArchive]$zip) {
        $container = $this.ReadZipEntry($zip, "META-INF/container.xml")
        $match = [regex]::Match($container, 'full-path\s*=\s*"([^"]+)"')

        if ($match.Success) {
            return $match.Groups[1].Value
        }

        return ""
    }


    # Fügt den Titel zu $parts und die Kapitelpfade in Lesereihenfolge zu
    # $chapterPaths hinzu. Eine defekte Paketdatei lässt beide unverändert.
    hidden [void] _ReadPackage(
        [System.IO.Compression.ZipArchive]$zip,
        [string]$packagePath,
        [System.Collections.Generic.List[string]]$parts,
        [System.Collections.Generic.List[string]]$chapterPaths
    ) {
        try {
            [xml]$package = $this.ReadZipEntry($zip, $packagePath)
        }
        catch {
            return
        }

        if ($null -eq $package) {
            return
        }

        # local-name() ignoriert die Namensräume (opf:, dc:) der Elemente.
        $title = $package.SelectSingleNode("//*[local-name()='metadata']/*[local-name()='title']")

        if ($null -ne $title -and -not [string]::IsNullOrWhiteSpace($title.InnerText)) {
            $parts.Add($title.InnerText.Trim())
        }

        # Kapitelpfade sind relativ zum Ordner der Paketdatei.
        $baseFolder = ""
        $lastSlash = $packagePath.LastIndexOf("/")

        if ($lastSlash -ge 0) {
            $baseFolder = $packagePath.Substring(0, $lastSlash + 1)
        }

        $hrefById = @{}

        foreach ($item in $package.SelectNodes("//*[local-name()='manifest']/*[local-name()='item']")) {
            $hrefById[$item.GetAttribute("id")] = $item.GetAttribute("href")
        }

        foreach ($itemRef in $package.SelectNodes("//*[local-name()='spine']/*[local-name()='itemref']")) {
            $href = $hrefById[$itemRef.GetAttribute("idref")]

            if (-not [string]::IsNullOrEmpty($href)) {
                $chapterPaths.Add([EpubContentReader]::ResolvePath($baseFolder, $href))
            }
        }
    }


    # Setzt einen Ordner und einen relativen Link wie "../Text/ch%201.xhtml#top"
    # zu einem ZIP-Eintragsnamen wie "OEBPS/Text/ch 1.xhtml" zusammen.
    static [string] ResolvePath([string]$baseFolder, [string]$href) {
        $link = $href.Split("#")[0]
        $link = [System.Uri]::UnescapeDataString($link)

        $segments = [System.Collections.Generic.List[string]]::new()

        foreach ($segment in ($baseFolder + $link).Split("/")) {
            if ($segment -eq "..") {
                if ($segments.Count -gt 0) {
                    $segments.RemoveAt($segments.Count - 1)
                }
            }
            elseif ($segment -ne "." -and $segment -ne "") {
                $segments.Add($segment)
            }
        }

        return $segments -join "/"
    }
}

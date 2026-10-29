using module "../Common/PathUtil.psm1"
using module "../Common/CloudFile.psm1"
using module "../Model/Datei.psm1"
using module "../Model/ScanError.psm1"
using module "../Persistence/DateiRepository.psm1"
using module "../DocScanner/DocScanner.psm1"

#requires -Version 7.2


# =============================================================================
# KONFIGURATION
# =============================================================================

$script:DefaultAttributesToSkip = (
    [System.IO.FileAttributes]::Hidden -bor
    [System.IO.FileAttributes]::System -bor
    [System.IO.FileAttributes]::Temporary
)

$script:DefaultExcludedFolderNames = @(
    ".git", ".svn", ".hg",
    "node_modules", "__pycache__",
    ".venv", "venv",
    ".idea", ".vs"
)


# Der Crawler durchläuft einen Ordnerbaum, vergleicht jede Datei mit dem
# Repository, lässt den DocScanner den Inhalt neuer oder geänderter Dateien
# lesen und speichert sie. Dateien, die seit dem letzten Scan verschwunden
# sind, werden entfernt.
class Crawler {

    # =============================================================================
    # ABHÄNGIGKEITEN
    # =============================================================================

    # Liest den Dateiinhalt. Weitere Reader auf dieser Instanz registrieren,
    # um zusätzliche Dateitypen zu unterstützen.
    [DocScanner]$DocScanner = [DocScanner]::new()

    # Speichert den Index. Jede von [DateiRepository] abgeleitete Klasse kann
    # zugewiesen werden, z. B. eine, die in eine Datenbank schreibt.
    [DateiRepository]$Repository = [InMemoryDateiRepository]::new()


    # =============================================================================
    # OPTIONEN
    # =============================================================================

    # Inhalt neuer oder geänderter Dateien über den DocScanner auslesen.
    [bool]$ReadContents = $true

    # Auch Cloud-Platzhalter (iCloud, OneDrive, ...) lesen. Dabei wird jede
    # solche Datei heruntergeladen, was sehr lange dauern kann. Aus: nur die
    # Metadaten werden gespeichert.
    [bool]$ReadCloudOnlyFiles = $false

    # Dateien aus dem Repository entfernen, die unterhalb des gescannten
    # Ordners nicht mehr existieren.
    [bool]$DetectDeletedFiles = $true

    # Jede verarbeitete [Datei] in $Files sammeln. Standardmäßig aus: bei
    # großen Scans würde die Liste (inklusive Inhalt) den Speicher füllen.
    [bool]$CollectFiles = $false

    # Anzahl der Dateien, die auf einmal ins Repository geschrieben werden.
    [int]$SaveBatchSize = 200

    # Ordnernamen, die überall im Baum übersprungen werden (ohne Beachtung
    # der Groß-/Kleinschreibung).
    [string[]]$ExcludedFolderNames = $script:DefaultExcludedFolderNames

    # Absolute Ordnerpfade, die samt Unterordnern übersprungen werden.
    [string[]]$ExcludedPaths = @()

    [System.IO.FileAttributes]$AttributesToSkip = (
        $script:DefaultAttributesToSkip
    )

    # Symbolischen Links und Junctions zu Ordnern folgen. Jeder echte Ordner
    # wird nur einmal besucht, daher führen Link-Zyklen nicht zu Endlosschleifen.
    [bool]$FollowDirectoryLinks = $false

    [bool]$VerboseOutput = $false
    [bool]$ProgressOutput = $false
    [bool]$WarningOutput = $true
    [int]$ProgressInterval = 100


    # =============================================================================
    # ERGEBNISSE
    # =============================================================================

    # Zähler für Ordner.
    [int]$ScannedFolders = 0
    [int]$SkippedFolders = 0    # ausgeschlossen, Link nicht verfolgt oder schon besucht
    [int]$FailedFolders = 0     # konnte nicht aufgelistet werden (z. B. Zugriff verweigert)

    # Zähler für Dateien. Nach einem Scan gilt:
    # ScannedFiles = NewFiles + ChangedFiles + UnchangedFiles + FailedFiles
    [int]$ScannedFiles = 0
    [int]$NewFiles = 0
    [int]$ChangedFiles = 0
    [int]$UnchangedFiles = 0
    [int]$FailedFiles = 0

    # Aus dem Repository entfernt, weil sie nicht mehr existieren.
    [int]$DeletedFiles = 0

    # Zähler für Inhalte, nur für neue oder geänderte Dateien:
    # gelesen = ein Reader hat den Text ausgelesen; übersprungen = kein Reader
    # oder Datei zu groß.
    [int]$ContentFilesRead = 0
    [int]$ContentFilesSkipped = 0

    # Neue oder geänderte Dateien, deren Inhalt nicht gelesen wurde, weil nur
    # ein Cloud-Platzhalter auf der Festplatte liegt. In ContentFilesSkipped
    # enthalten.
    [int]$CloudOnlyFiles = 0

    # Nur gefüllt, wenn CollectFiles aktiviert ist.
    [System.Collections.Generic.List[Datei]]$Files = (
        [System.Collections.Generic.List[Datei]]::new()
    )

    [System.Collections.Generic.List[ScanError]]$Errors = (
        [System.Collections.Generic.List[ScanError]]::new()
    )


    # =============================================================================
    # ZUSTAND PRO SCAN
    # =============================================================================

    hidden [System.IO.EnumerationOptions]$_enumerationOptions
    hidden [System.Collections.Generic.HashSet[string]]$_excludedNames
    hidden [string[]]$_excludedPaths

    # Pfade, die im aktuellen Scan auf der Festplatte gefunden wurden.
    hidden [System.Collections.Generic.HashSet[string]]$_seenPaths

    # Echte Pfade der besuchten Ordner, um Link-Zyklen zu unterbrechen.
    hidden [System.Collections.Generic.HashSet[string]]$_visitedFolders

    # Ordner, die nicht vollständig aufgelistet werden konnten. Gespeicherte
    # Dateien darunter gelten nicht als gelöscht.
    hidden [System.Collections.Generic.List[string]]$_failedFolders

    # Dateien, die darauf warten, ins Repository geschrieben zu werden.
    hidden [System.Collections.Generic.List[Datei]]$_pendingSaves


    # =============================================================================
    # SCAN-VORBEREITUNG
    # =============================================================================

    hidden [void] _PrepareScan() {
        $this._enumerationOptions = [System.IO.EnumerationOptions]::new()
        $this._enumerationOptions.AttributesToSkip = $this.AttributesToSkip
        $this._enumerationOptions.ReturnSpecialDirectories = $false

        # Unterordner verarbeitet der Crawler selbst, damit sie gezählt,
        # ausgeschlossen und auf Links geprüft werden können.
        $this._enumerationOptions.RecurseSubdirectories = $false

        # Nicht zugängliche Ordner müssen einen Fehler auslösen. Sonst sähen
        # sie leer aus und ihre gespeicherten Dateien würden als gelöscht
        # behandelt.
        $this._enumerationOptions.IgnoreInaccessible = $false

        $this._excludedNames = (
            [System.Collections.Generic.HashSet[string]]::new(
                [string[]]@($this.ExcludedFolderNames | Where-Object { $_ }),
                [System.StringComparer]::OrdinalIgnoreCase
            )
        )

        $this._excludedPaths = @(
            $this.ExcludedPaths |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                ForEach-Object { [PathUtil]::Normalize($_) }
        )

        $comparer = [PathUtil]::GetComparer()
        $this._seenPaths = [System.Collections.Generic.HashSet[string]]::new($comparer)
        $this._visitedFolders = [System.Collections.Generic.HashSet[string]]::new($comparer)
        $this._failedFolders = [System.Collections.Generic.List[string]]::new()
        $this._pendingSaves = [System.Collections.Generic.List[Datei]]::new()
    }


    # =============================================================================
    # ÖFFENTLICHE EINSTIEGSPUNKTE
    # =============================================================================

    [void] ScanFolder([string]$folderPath) {
        if ([string]::IsNullOrWhiteSpace($folderPath)) {
            Write-Warning "Folder path must not be empty."
            return
        }

        $rootPath = [PathUtil]::Normalize($folderPath)

        if (-not [System.IO.Directory]::Exists($rootPath)) {
            Write-Warning "Folder does not exist or is inaccessible: $rootPath"
            return
        }

        # Zustand vor jedem Scan neu aufbauen, damit geänderte Einstellungen
        # wirksam werden.
        $this._PrepareScan()

        $this._Traverse($rootPath)
        $this._FlushSaves()

        if ($this.DetectDeletedFiles) {
            $this._RemoveDeletedFiles($rootPath)
        }
    }


    # Verarbeitet eine einzelne Datei, ohne Ordner zu durchlaufen und ohne
    # gelöschte Dateien zu erkennen.
    [Datei] ProcessFile([System.IO.FileInfo]$file) {
        if ($null -eq $file) {
            $this._AddError("", [ScanPhase]::Metadata, "FileInfo must not be null.")
            return $null
        }

        $this._PrepareScan()

        $datei = $this._ProcessFile($file)
        $this._FlushSaves()

        return $datei
    }


    # =============================================================================
    # DURCHLAUFEN DER ORDNER
    # =============================================================================

    # Iterative Tiefensuche. Ein eigener Stapel vermeidet tiefe Rekursion bei
    # stark verschachtelten Ordnerbäumen.
    hidden [void] _Traverse([string]$rootPath) {
        # Jeder Eintrag ist @(Pfad aus Sicht des Benutzers, echter Pfad auf
        # der Festplatte).
        $stack = [System.Collections.Generic.Stack[string[]]]::new()
        $stack.Push(@($rootPath, $rootPath))

        while ($stack.Count -gt 0) {
            $entry = $stack.Pop()
            $folderPath = $entry[0]
            $realPath = $entry[1]

            # Wird ein echter Ordner ein zweites Mal erreicht, liegt ein
            # Link-Zyklus vor oder zwei Links zeigen auf dasselbe Ziel.
            if (-not $this._visitedFolders.Add($realPath)) {
                $this.SkippedFolders++
                continue
            }

            $this.ScannedFolders++
            $subfolders = [System.Collections.Generic.List[string[]]]::new()

            try {
                $directory = [System.IO.DirectoryInfo]::new($folderPath)
                $items = $directory.EnumerateFileSystemInfos(
                    "*",
                    $this._enumerationOptions
                )

                foreach ($item in $items) {
                    if ($item -is [System.IO.DirectoryInfo]) {
                        $childRealPath = $this._GetSubfolderRealPath($item, $realPath)

                        # [string]-Methoden machen aus $null einen leeren
                        # String, deshalb wird beides geprüft.
                        if ([string]::IsNullOrEmpty($childRealPath)) {
                            $this.SkippedFolders++
                        }
                        else {
                            $subfolders.Add(@($item.FullName, $childRealPath))
                        }

                        continue
                    }

                    if ($item -is [System.IO.FileInfo]) {
                        [void]$this._ProcessFile($item)
                    }
                }
            }
            catch {
                $this.FailedFolders++
                $this._failedFolders.Add($folderPath)
                $this._AddError($folderPath, [ScanPhase]::Folder, $_.Exception.Message)
            }

            # In umgekehrter Reihenfolge abgelegt, damit die Unterordner in
            # der Reihenfolge der Auflistung besucht werden.
            for ($i = $subfolders.Count - 1; $i -ge 0; $i--) {
                $stack.Push($subfolders[$i])
            }
        }
    }


    # Gibt den echten Pfad eines zu besuchenden Unterordners zurück oder einen
    # leeren String, wenn er übersprungen wird.
    hidden [string] _GetSubfolderRealPath(
        [System.IO.DirectoryInfo]$folder,
        [string]$parentRealPath
    ) {
        if ($this._excludedNames.Contains($folder.Name)) {
            return $null
        }

        foreach ($excludedPath in $this._excludedPaths) {
            if ([PathUtil]::IsSameOrUnder($folder.FullName, $excludedPath)) {
                return $null
            }
        }

        # Das Attribut ReparsePoint allein bedeutet nicht "Link": Unter Windows
        # markiert OneDrive damit auch seine normalen Ordner (Cloud-Platzhalter).
        # Nur symbolische Links und Junctions haben ein LinkTarget. Das Attribut
        # wird zuerst geprüft, weil es keinen zusätzlichen Zugriff kostet.
        $isLink = (
            ($folder.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -and
            -not [string]::IsNullOrEmpty($folder.LinkTarget)
        )

        if (-not $isLink) {
            return [System.IO.Path]::Join($parentRealPath, $folder.Name)
        }

        if (-not $this.FollowDirectoryLinks) {
            return $null
        }

        try {
            $target = $folder.ResolveLinkTarget($true)

            if ($null -eq $target -or -not $target.Exists) {
                return $null
            }

            return [PathUtil]::Normalize($target.FullName)
        }
        catch {
            $this._AddError($folder.FullName, [ScanPhase]::Folder, $_.Exception.Message)
            return $null
        }
    }


    # =============================================================================
    # DATEIVERARBEITUNG
    # =============================================================================

    # Gibt die verarbeitete Datei zurück oder $null, wenn sie fehlgeschlagen
    # ist. Fehlgeschlagene Dateien werden nicht gespeichert, daher versucht
    # der nächste Scan sie erneut.
    hidden [Datei] _ProcessFile([System.IO.FileInfo]$file) {
        $this.ScannedFiles++
        $filePath = $file.FullName
        [void]$this._seenPaths.Add($filePath)

        # Merkt sich den aktuellen Schritt, damit ein Fehler ihm zugeordnet
        # werden kann.
        $phase = [ScanPhase]::Metadata

        try {
            # Das Auflisten liefert bereits alle Metadaten; kein zusätzlicher
            # Zugriff auf die Festplatte.
            $datei = [Datei]::FromFileInfo($file)

            $phase = [ScanPhase]::Repository
            $stored = $this.Repository.Get($filePath)

            # Nur die Änderungszeit entscheidet: Ist sie gleich der
            # gespeicherten, ist die Datei unverändert und wird weder gelesen
            # noch erneut gespeichert.
            $isUnchanged = (
                $null -ne $stored -and
                $stored.LastWriteTimeUtc.Ticks -eq $datei.LastWriteTimeUtc.Ticks
            )

            # Ausnahme: Ein Cloud-Platzhalter, der inzwischen heruntergeladen
            # wurde, behält seinen Zeitstempel, aber sein Inhalt kann jetzt
            # gelesen werden.
            if (
                $isUnchanged -and
                $stored.IsCloudOnly -and
                -not $this._IsSkippedCloudFile($file)
            ) {
                $isUnchanged = $false
            }

            if ($isUnchanged) {
                $this._MarkUnchanged($datei, $stored)
                return $datei
            }

            # Der DocScanner entscheidet, ob es einen Reader für den Dateityp
            # gibt und ob die Datei klein genug ist.
            $shouldRead = $this.ReadContents -and $this.DocScanner.ShouldRead($file)

            # Nur bei lesbaren Dateien geprüft, weil die Prüfung einen
            # Systemaufruf kostet.
            if ($shouldRead -and $this._IsSkippedCloudFile($file)) {
                $datei.IsCloudOnly = $true
                $this.CloudOnlyFiles++
                $shouldRead = $false
            }

            if ($shouldRead) {
                $phase = [ScanPhase]::Content
                $datei.Content = $this.DocScanner.ReadContent($file)
                $datei.HasContent = $true
                $this.ContentFilesRead++
            }
            else {
                $this.ContentFilesSkipped++
            }

            if ($null -eq $stored) {
                $datei.Status = [DateiStatus]::New
                $this.NewFiles++
            }
            else {
                $datei.Status = [DateiStatus]::Changed
                $this.ChangedFiles++
            }

            $datei.IndexedAtUtc = [datetime]::UtcNow
            $this._QueueSave($datei)
            $this._Collect($datei)

            if ($this.VerboseOutput) {
                $datei.print() | Out-Host
            }

            return $datei
        }
        catch {
            $this.FailedFiles++
            $this._AddError($filePath, $phase, $_.Exception.Message)
            return $null
        }
        finally {
            $this._WriteProgress()
        }
    }


    # Übernimmt die gespeicherten Werte für eine unveränderte Datei. Der Inhalt
    # wird nicht geladen, er liegt bereits im Repository.
    hidden [void] _MarkUnchanged([Datei]$datei, [Datei]$stored) {
        $datei.Status = [DateiStatus]::Unchanged
        $datei.IndexedAtUtc = $stored.IndexedAtUtc
        $datei.HasContent = $stored.HasContent
        $datei.IsCloudOnly = $stored.IsCloudOnly

        $this.UnchangedFiles++
        $this._Collect($datei)

        if ($this.VerboseOutput) {
            Write-Host "File unchanged, skipping content: $($datei.Path)"
        }
    }


    # True, wenn die Datei ein Cloud-Platzhalter ist, der nicht
    # heruntergeladen werden darf.
    hidden [bool] _IsSkippedCloudFile([System.IO.FileInfo]$file) {
        return (
            -not $this.ReadCloudOnlyFiles -and
            [CloudFile]::IsCloudOnly($file)
        )
    }


    hidden [void] _Collect([Datei]$datei) {
        if ($this.CollectFiles) {
            $this.Files.Add($datei)
        }
    }


    # =============================================================================
    # SCHREIBEN INS REPOSITORY
    # =============================================================================

    hidden [void] _QueueSave([Datei]$datei) {
        $this._pendingSaves.Add($datei)

        if ($this._pendingSaves.Count -ge [Math]::Max(1, $this.SaveBatchSize)) {
            $this._FlushSaves()
        }
    }


    hidden [void] _FlushSaves() {
        if ($null -eq $this._pendingSaves -or $this._pendingSaves.Count -eq 0) {
            return
        }

        $batch = $this._pendingSaves.ToArray()
        $this._pendingSaves.Clear()

        try {
            $this.Repository.SaveBatch($batch)
        }
        catch {
            $message = $_.Exception.Message

            # Die Dateien wurden beim Einreihen als neu oder geändert gezählt.
            foreach ($datei in $batch) {
                if ($datei.Status -eq [DateiStatus]::New) {
                    $this.NewFiles--
                }
                else {
                    $this.ChangedFiles--
                }

                $this.FailedFiles++
                $this._AddError($datei.Path, [ScanPhase]::Repository, $message)
            }
        }
    }


    # =============================================================================
    # ERKENNUNG GELÖSCHTER DATEIEN
    # =============================================================================

    hidden [void] _RemoveDeletedFiles([string]$rootPath) {
        try {
            $storedPaths = $this.Repository.GetPathsUnder($rootPath)
        }
        catch {
            $this._AddError($rootPath, [ScanPhase]::Repository, $_.Exception.Message)
            return
        }

        foreach ($path in $storedPaths) {
            if ($this._seenPaths.Contains($path) -or $this._IsBelowFailedFolder($path)) {
                continue
            }

            try {
                $this.Repository.Remove($path)
                $this.DeletedFiles++

                if ($this.CollectFiles) {
                    $deleted = [Datei]::new()
                    $deleted.Path = $path
                    $deleted.Name = [System.IO.Path]::GetFileName($path)
                    $deleted.Status = [DateiStatus]::Deleted
                    $this.Files.Add($deleted)
                }
            }
            catch {
                $this._AddError($path, [ScanPhase]::Repository, $_.Exception.Message)
            }
        }
    }


    hidden [bool] _IsBelowFailedFolder([string]$path) {
        foreach ($failedFolder in $this._failedFolders) {
            if ([PathUtil]::IsSameOrUnder($path, $failedFolder)) {
                return $true
            }
        }

        return $false
    }


    # =============================================================================
    # AUSGABE
    # =============================================================================

    hidden [void] _AddError([string]$path, [ScanPhase]$phase, [string]$message) {
        $scanError = [ScanError]::new($path, $phase, $message)
        $this.Errors.Add($scanError)

        if ($this.WarningOutput) {
            Write-Warning $scanError.ToString()
        }
    }


    hidden [void] _WriteProgress() {
        if (
            $this.ProgressOutput -and
            $this.ProgressInterval -gt 0 -and
            $this.ScannedFiles % $this.ProgressInterval -eq 0
        ) {
            Write-Host (
                "Scanned: {0} | New: {1} | Changed: {2} | Unchanged: {3} | Failed: {4}" -f
                $this.ScannedFiles,
                $this.NewFiles,
                $this.ChangedFiles,
                $this.UnchangedFiles,
                $this.FailedFiles
            )
        }
    }


    [PSCustomObject] GetSummary() {
        return [PSCustomObject][ordered]@{
            ScannedFolders      = $this.ScannedFolders
            SkippedFolders      = $this.SkippedFolders
            FailedFolders       = $this.FailedFolders
            ScannedFiles        = $this.ScannedFiles
            NewFiles            = $this.NewFiles
            ChangedFiles        = $this.ChangedFiles
            UnchangedFiles      = $this.UnchangedFiles
            FailedFiles         = $this.FailedFiles
            DeletedFiles        = $this.DeletedFiles
            ContentFilesRead    = $this.ContentFilesRead
            ContentFilesSkipped = $this.ContentFilesSkipped
            CloudOnlyFiles      = $this.CloudOnlyFiles
            Errors              = $this.Errors.Count
        }
    }


    # =============================================================================
    # ZURÜCKSETZEN
    # =============================================================================

    # Leert Ergebnisse und Zähler. Das Repository bleibt erhalten, damit der
    # nächste Scan unveränderte und gelöschte Dateien erkennen kann.
    [void] Reset() {
        $this.Files.Clear()
        $this.Errors.Clear()

        $this.ScannedFolders = 0
        $this.SkippedFolders = 0
        $this.FailedFolders = 0
        $this.ScannedFiles = 0
        $this.NewFiles = 0
        $this.ChangedFiles = 0
        $this.UnchangedFiles = 0
        $this.FailedFiles = 0
        $this.DeletedFiles = 0
        $this.ContentFilesRead = 0
        $this.ContentFilesSkipped = 0
        $this.CloudOnlyFiles = 0
    }
}

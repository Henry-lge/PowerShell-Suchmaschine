using module "../Common/PathUtil.psm1"
using module "../Common/CloudFile.psm1"
using module "../Model/Datei.psm1"
using module "../Model/ScanError.psm1"
using module "../Persistence/DateiRepository.psm1"
using module "../Persistence/SqliteDateiRepository.psm1"
using module "../DocScanner/DocScanner.psm1"

#requires -Version 7.4


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

# Ordner mit diesen Endungen sind unter macOS Pakete (Programme, Frameworks,
# Plug-ins). Der Finder zeigt sie als eine Datei; ihr Inhalt sind
# Programmdateien und Icons, keine Dokumente. In einem Benutzerordner machten
# allein vier Entwickler-Apps über die Hälfte der zu lesenden Dateien aus.
$script:DefaultExcludedFolderExtensions = @(
    ".app", ".appex", ".framework", ".bundle",
    ".plugin", ".kext", ".xpc", ".prefPane"
)

# Ein Kern bleibt für den Hauptthread (Ordner, Datenbank) frei. Höchstens 8:
# Bei Ordnern mit vielen Bildern warten die Worker meist auf die
# Texterkennung, die außerhalb von PowerShell läuft; 8 statt 4 Worker waren
# dort etwa 25-30 % schneller. Bei reinen Dokumenten änderte sich kaum
# etwas, und mehr als 8 brachten in keinem Fall noch etwas.
$script:DefaultMaxParallelism = [Math]::Max(1, [Math]::Min(8, [Environment]::ProcessorCount - 1))

# Standard-Datenbank: data/index.sqlite3 im Projektordner, unabhängig davon,
# aus welchem Ordner das Skript gestartet wird.
$script:DefaultDatabasePath = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot "../../data/index.sqlite3")
)

# Pfad des DocScanner-Moduls, das jeder Worker selbst lädt.
$script:DocScannerModulePath = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot "../DocScanner/DocScanner.psm1")
)

# Skript, das in jedem Worker-Runspace läuft. Jeder Worker lädt das Modul
# einmal, erzeugt seinen eigenen DocScanner und verwendet ihn für alle
# weiteren Pakete wieder. Zurück kommen nur einfache Daten (Index, Text,
# Fehlermeldung), damit der Hauptthread nichts mit den Workern teilt.
#
# Alle Klassen des DocScanners tragen [NoRunspaceAffinity()] (PowerShell
# 7.4+). Ohne das Attribut würde PowerShell Methoden und statische Felder
# einer Klasse in dem Runspace ausführen, der sie zuerst geladen hat, also im
# Hauptthread. Der wartet aber gerade auf die Worker: Der Scan hinge.
$script:WorkerScript = @'
param([string]$ModulePath, [long]$MaxContentSizeBytes, [int]$Start, [string[]]$Paths)

if ($null -eq $global:CrawlerWorkerDocScanner) {
    # Erst sammeln, dann auswählen: Select-Object -First direkt hinter
    # Import-Module würde in einem Worker die ganze Pipeline anhalten.
    $modules = @(Import-Module -Name $ModulePath -PassThru -ErrorAction Stop)
    $module = @($modules | Where-Object Name -eq "DocScanner")[0]

    # Im Modul ausgeführt, weil der Typ [DocScanner] nur dort bekannt ist.
    $global:CrawlerWorkerDocScanner = & $module { [DocScanner]::new() }
}

$scanner = $global:CrawlerWorkerDocScanner
$scanner.MaxContentSizeBytes = $MaxContentSizeBytes

$files = [System.IO.FileInfo[]]::new($Paths.Length)

for ($i = 0; $i -lt $Paths.Length; $i++) {
    $files[$i] = [System.IO.FileInfo]::new($Paths[$i])
}

# Reader können das ganze Paket auf einmal vorbereiten (z. B. Texterkennung
# für alle Bilder in einem Aufruf).
$scanner.Prepare($files)

for ($i = 0; $i -lt $Paths.Length; $i++) {
    try {
        $text = $scanner.ReadContent($files[$i])
        [pscustomobject]@{ Index = $Start + $i; Content = $text; Error = $null }
    }
    catch {
        [pscustomobject]@{ Index = $Start + $i; Content = $null; Error = $_.Exception.Message }
    }
}
'@


# Pfad des SQLite-Moduls, das der Schreib-Thread selbst lädt.
$script:SqliteModulePath = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot "../Persistence/SqliteDateiRepository.psm1")
)

# Skript des Schreib-Threads. Es speichert die Pakete aus der Warteschlange
# mit SaveBatch, während der Hauptthread weiter Ordner durchläuft und Inhalte
# liest.
#
# Die Verbindung kommt aus dem Verbindungspool der Datenbank (DatabasePool):
# Der Pool ist eine C#-Klasse und darf zwischen Runspaces geteilt werden. Das
# Repository dagegen ist eine PowerShell-Klasse und gehört zu dem Runspace,
# der es erzeugt; deshalb baut der Schreib-Thread sein eigenes aus einer
# geliehenen Verbindung. Würde er das Repository des Hauptthreads benutzen,
# liefen seine Aufrufe über den Hauptthread und hingen, sobald dieser auf die
# Warteschlange wartet. Dank WAL-Modus kann der Hauptthread lesen (Get),
# während hier geschrieben wird.
#
# Der Runspace bleibt über mehrere Scans erhalten. Modul und Repository
# werden nur beim ersten Mal geladen bzw. erzeugt und in
# $global:CrawlerWriterRepository gemerkt; Dispose() des Crawlers gibt die
# Verbindung an den Pool zurück.
#
# Zurück kommen nur Pakete, die nicht gespeichert wurden. Retry = $true heißt,
# dass der Schreib-Thread keine Verbindung bekam; der Hauptthread speichert
# das Paket dann selbst.
$script:WriterScript = @'
param([string]$ModulePath, $Pool, [int]$BorrowTimeoutMilliseconds, $Queue, $Results)

$startError = $null

if ($null -eq $global:CrawlerWriterRepository) {
    $lease = $null

    try {
        # Erst sammeln, dann auswählen (siehe Worker-Skript).
        $modules = @(Import-Module -Name $ModulePath -PassThru -ErrorAction Stop)
        $module = @($modules | Where-Object Name -eq "SqliteDateiRepository")[0]

        $lease = $Pool.Borrow($BorrowTimeoutMilliseconds)

        # Im Modul ausgeführt, weil der Typ nur dort bekannt ist.
        $global:CrawlerWriterRepository = & $module { param($l) [SqliteDateiRepository]::new($l) } $lease
    }
    catch {
        $startError = $_.Exception.Message

        if ($null -ne $lease) {
            $lease.Dispose()
        }
    }
}

$repository = $global:CrawlerWriterRepository

foreach ($batch in $Queue.GetConsumingEnumerable()) {
    if ($null -eq $repository) {
        $Results.Enqueue([pscustomobject]@{ Batch = $batch; Message = $startError; Retry = $true })
        continue
    }

    try {
        $repository.SaveBatch($batch)
    }
    catch {
        $Results.Enqueue([pscustomobject]@{ Batch = $batch; Message = $_.Exception.Message; Retry = $false })
    }
}
'@

# Gibt die Verbindung des Schreib-Threads an den Pool zurück.
$script:WriterCleanupScript = @'
if ($null -ne $global:CrawlerWriterRepository) {
    $global:CrawlerWriterRepository.Dispose()
    $global:CrawlerWriterRepository = $null
}
'@


# Skript der Hintergrundverarbeitung. Es liest Dateien, deren Reader im
# Hintergrund laufen soll (z. B. Videos, ContentReader.RunsInBackground),
# nachdem der eigentliche Scan fertig ist, und speichert jede sofort.
#
# Wie der Schreib-Thread holt es sich eine eigene Verbindung aus dem Pool
# und baut daraus sein Repository; DocScanner und Repository werden nur beim
# ersten Mal erzeugt und für spätere Scans in globalen Variablen gemerkt.
#
# Kann der Inhalt nicht gelesen werden, wird die Datei trotzdem mit ihrer
# echten Änderungszeit gespeichert (ohne Inhalt) und erst nach einer
# Änderung erneut versucht, wie im normalen Scan. Scheitert das Speichern,
# bleibt der Platzhalter aus dem Scan stehen und der nächste Scan versucht
# es erneut.
$script:BackgroundScript = @'
param(
    [string]$DocScannerModulePath,
    [string]$SqliteModulePath,
    $Pool,
    [int]$BorrowTimeoutMilliseconds,
    $Queue,
    $Results,
    $Paths
)

$startError = $null

if ($null -eq $global:CrawlerBackgroundRepository) {
    $lease = $null

    try {
        # Erst sammeln, dann auswählen (siehe Worker-Skript).
        $scannerModules = @(Import-Module -Name $DocScannerModulePath -PassThru -ErrorAction Stop)
        $scannerModule = @($scannerModules | Where-Object Name -eq "DocScanner")[0]
        $global:CrawlerBackgroundDocScanner = & $scannerModule { [DocScanner]::new() }

        $sqliteModules = @(Import-Module -Name $SqliteModulePath -PassThru -ErrorAction Stop)
        $sqliteModule = @($sqliteModules | Where-Object Name -eq "SqliteDateiRepository")[0]
        $lease = $Pool.Borrow($BorrowTimeoutMilliseconds)
        $global:CrawlerBackgroundRepository = & $sqliteModule { param($l) [SqliteDateiRepository]::new($l) } $lease
    }
    catch {
        $startError = $_.Exception.Message

        if ($null -ne $lease) {
            $lease.Dispose()
        }
    }
}

$scanner = $global:CrawlerBackgroundDocScanner
$repository = $global:CrawlerBackgroundRepository
$removed = [byte]0
$carry = $null

# Jeder Eintrag ist entweder eine Datei, die erst hier gelesen wird (z. B.
# ein Video), oder eine bereits gelesene, die nur ergänzt wird (Enrich, z. B.
# Objekte auf einem Foto). Ergänzungen werden bis zu 20 auf einmal
# verarbeitet, damit Reader ein Tool nur einmal pro Paket starten.
while ($true) {
    $item = $carry
    $carry = $null

    if ($null -eq $item -and -not $Queue.TryTake([ref]$item, -1)) {
        break
    }

    $items = [System.Collections.Generic.List[object]]::new()
    $items.Add($item)

    if ($item.Enrich) {
        $next = $null

        while ($items.Count -lt 20 -and $Queue.TryTake([ref]$next, 0)) {
            if ($next.Enrich) {
                $items.Add($next)
            }
            else {
                $carry = $next
                break
            }
        }
    }

    $message = $startError

    if ($null -ne $repository) {
        $message = $null

        if ($item.Enrich) {
            $files = [System.IO.FileInfo[]]::new($items.Count)

            for ($i = 0; $i -lt $items.Count; $i++) {
                $files[$i] = [System.IO.FileInfo]::new($items[$i].Datei.Path)
            }

            try {
                $texts = $scanner.Enrich($files)
            }
            catch {
                # Die Dateien behalten ihren gelesenen Inhalt.
                $message = $_.Exception.Message
                $texts = [string[]]::new($items.Count)
            }

            for ($i = 0; $i -lt $items.Count; $i++) {
                if (-not [string]::IsNullOrWhiteSpace($texts[$i])) {
                    $datei = $items[$i].Datei
                    $datei.Content = ("$($datei.Content)`n`n$($texts[$i])").Trim()
                    $datei.HasContent = $true
                }
            }
        }
        else {
            $datei = $item.Datei

            try {
                $datei.Content = $scanner.ReadContent([System.IO.FileInfo]::new($datei.Path))
                $datei.HasContent = $true
            }
            catch {
                $message = $_.Exception.Message
                $datei.Content = $null
                $datei.HasContent = $false
            }
        }

        $batch = [object[]]::new($items.Count)

        for ($i = 0; $i -lt $items.Count; $i++) {
            $items[$i].Datei.IndexedAtUtc = [datetime]::UtcNow
            $batch[$i] = $items[$i].Datei
        }

        try {
            $repository.SaveBatch($batch)
        }
        catch {
            $message = "Saving failed: " + $_.Exception.Message
        }
    }

    # Ein Fehler beim Ergänzen betrifft meist das ganze Paket (z. B. fehlende
    # Objekterkennung) und wird nur einmal gemeldet.
    for ($i = 0; $i -lt $items.Count; $i++) {
        $path = $items[$i].Datei.Path
        [void]$Paths.TryRemove($path, [ref]$removed)
        $Results.Enqueue([pscustomobject]@{
            Path  = $path
            Error = if ($i -eq 0) { $message } else { $null }
        })
    }
}
'@

# Gibt die Verbindung der Hintergrundverarbeitung an den Pool zurück.
$script:BackgroundCleanupScript = @'
if ($null -ne $global:CrawlerBackgroundRepository) {
    $global:CrawlerBackgroundRepository.Dispose()
    $global:CrawlerBackgroundRepository = $null
}
'@


# Eine Datei, deren Inhalt noch gelesen werden muss. $Stored ist der Stand
# aus dem Repository ($null bei neuen Dateien) und entscheidet später, ob die
# Datei als New oder Changed gilt.
class PendingRead {
    [System.IO.FileInfo]$File
    [Datei]$Datei
    [Datei]$Stored
}


# Der Crawler durchläuft einen Ordnerbaum, vergleicht jede Datei mit dem
# Repository, lässt den DocScanner den Inhalt neuer oder geänderter Dateien
# lesen und speichert sie. Dateien, die seit dem letzten Scan verschwunden
# sind, werden entfernt.
#
# Ein Scan läuft in zwei Phasen:
#   1. Auswahl (Hauptthread): Ordner durchlaufen, mit dem Repository
#      vergleichen. Dateien, deren Inhalt gelesen werden muss, kommen auf
#      eine Liste.
#   2. Lesen: Die Liste wird bei vielen Dateien parallel von mehreren Workern
#      gelesen (MaxParallelism), sonst nacheinander. Die Ergebnisse werden im
#      Hauptthread gezählt, daher braucht die Fehlerliste keine Absicherung
#      gegen gleichzeitigen Zugriff.
#
# Gespeichert wird in beiden Phasen paketweise. Mit der Standard-Datenbank
# übernimmt das ein eigener Schreib-Thread (UseWriterThread), sodass
# Durchlaufen, Lesen und Schreiben gleichzeitig laufen.
class Crawler {

    # =============================================================================
    # ABHÄNGIGKEITEN
    # =============================================================================

    # Liest den Dateiinhalt. Weitere Reader auf dieser Instanz registrieren,
    # um zusätzliche Dateitypen zu unterstützen.
    [DocScanner]$DocScanner = [DocScanner]::new()

    # Speichert den Index. Standardmäßig die SQLite-Datenbank unter
    # DatabasePath: Bleibt Repository leer, holt sich der Crawler beim ersten
    # Scan eine Verbindung aus DatabasePool und gibt sie in Dispose() zurück.
    # Jede andere von [DateiRepository] abgeleitete Klasse kann zugewiesen
    # werden, z. B. [InMemoryDateiRepository] für Tests; sie wird dann im
    # Hauptthread beschrieben, ohne Schreib-Thread.
    [DateiRepository]$Repository = $null

    # Verbindungspool der SQLite-Datenbank (Initialize-DatabasePool). Der
    # Crawler leiht sich daraus eine Verbindung für den Hauptthread und eine
    # für den Schreib-Thread. Bleibt er leer, öffnet der Crawler selbst einen
    # Pool mit zwei Verbindungen zu DatabasePath und schließt ihn in
    # Dispose(). Ein zugewiesener Pool (z. B. von der GUI, die ihn auch für
    # die Suche nutzt) wird nicht geschlossen. Als [object] deklariert, weil
    # der C#-Typ erst beim Laden des SQLite-Moduls entsteht.
    [object]$DatabasePool = $null

    # Datenbankdatei, wenn der Crawler den Pool selbst öffnet.
    [string]$DatabasePath = $script:DefaultDatabasePath


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

    # Anzahl der Dateien, die auf einmal ins Repository geschrieben werden
    # (SaveBatch) bzw. gelöscht werden (RemoveBatch). Gelesen wird der
    # gespeicherte Stand dagegen einzeln pro Datei (Get).
    [int]$SaveBatchSize = 200

    # Ordnernamen, die überall im Baum übersprungen werden (ohne Beachtung
    # der Groß-/Kleinschreibung).
    [string[]]$ExcludedFolderNames = $script:DefaultExcludedFolderNames

    # Ordner mit diesen Endungen werden samt Inhalt übersprungen (ohne
    # Beachtung der Groß-/Kleinschreibung), standardmäßig macOS-Pakete wie
    # ".app". Leeres Array: alle Ordner durchsuchen.
    [string[]]$ExcludedFolderExtensions = $script:DefaultExcludedFolderExtensions

    # Absolute Ordnerpfade, die samt Unterordnern übersprungen werden.
    [string[]]$ExcludedPaths = @()

    [System.IO.FileAttributes]$AttributesToSkip = (
        $script:DefaultAttributesToSkip
    )

    # Symbolischen Links und Junctions zu Ordnern folgen. Jeder echte Ordner
    # wird nur einmal besucht, daher führen Link-Zyklen nicht zu Endlosschleifen.
    [bool]$FollowDirectoryLinks = $false

    # Anzahl der Worker, die Inhalte gleichzeitig lesen. 1 = alles
    # nacheinander im Hauptthread, wie ohne Multithreading.
    [int]$MaxParallelism = $script:DefaultMaxParallelism

    # Erst ab so vielen zu lesenden Dateien werden Worker verwendet. Bei
    # wenigen Dateien dauert das Starten der Worker länger als das Lesen.
    [int]$ParallelThreshold = 50

    # Pakete in einem eigenen Thread speichern, während weiter gescannt wird.
    # Nur mit der SQLite-Datenbank aus DatabasePool, weil der Thread eine
    # eigene Verbindung braucht. Ein zugewiesenes Repository wird immer im
    # Hauptthread beschrieben. Der Thread startet erst beim ersten Paket;
    # ein Scan ohne Änderungen kostet ihn also nichts.
    [bool]$UseWriterThread = $true

    # Dateien, deren Reader im Hintergrund laufen soll (z. B. Videos),
    # werden beim Scan zuerst ohne Inhalt gespeichert und nach dem Scan im
    # Hintergrund gelesen. So ist der übrige Index fertig, ohne auf sie zu
    # warten. Nur mit der SQLite-Datenbank aus DatabasePool; sonst werden sie
    # wie alle anderen Dateien im Scan gelesen. Fortschritt und Abschluss:
    # GetBackgroundPending() und WaitForBackground().
    [bool]$BackgroundProcessing = $true

    # So lange wird auf eine freie Verbindung im Pool gewartet. Ist sie dann
    # nicht frei (z. B. weil ein zugewiesener Pool ausgelastet ist), speichert
    # der Hauptthread selbst bzw. der Scan meldet den Fehler.
    [int]$PoolTimeoutMilliseconds = 30000

    # Höchstens so viele Pakete warten auf den Schreib-Thread. Ist die
    # Warteschlange voll, wartet der Hauptthread; so bleibt der Speicher
    # begrenzt, auch wenn das Schreiben langsamer ist als das Lesen.
    [int]$WriterQueueCapacity = 8

    # Anzahl der Dateien, die ein Worker auf einmal bekommt. Größere Pakete
    # sparen Verwaltungsaufwand, kleinere verteilen die Arbeit gleichmäßiger.
    # Kleiner als 20 lohnt sich nicht: Die Texterkennung erkennt alle Bilder
    # eines Pakets in einem Aufruf (DocScanner.Prepare); bei kleineren
    # Paketen startet sie öfter und wird langsamer.
    [int]$ParallelBatchSize = 20


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

    # Dateien, die dieser Scan zur Hintergrundverarbeitung gegeben hat:
    # Videos, die erst dort gelesen werden (zunächst ohne Inhalt gespeichert),
    # und Fotos, deren Objekte dort ergänzt werden (zunächst mit dem übrigen
    # Inhalt gespeichert). Sie sind in NewFiles bzw. ChangedFiles enthalten. Fertig bzw. gescheitert zählen die beiden anderen Zähler,
    # sobald WaitForBackground() oder der nächste Scan die Ergebnisse abholt.
    [int]$BackgroundFiles = 0
    [int]$BackgroundCompleted = 0
    [int]$BackgroundFailed = 0

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
    hidden [System.Collections.Generic.HashSet[string]]$_excludedExtensions
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

    # Dateien, deren Inhalt in Phase 2 gelesen wird.
    hidden [System.Collections.Generic.List[PendingRead]]$_pendingReads


    # Ob das Repository RemoveBatch() anbietet. Ältere oder eigene
    # Repositories haben nur Remove(); dann wird einzeln gelöscht.
    hidden [bool]$_repositoryHasRemoveBatch = $false

    # True, wenn das Repository aus DatabasePool geliehen ist und in
    # Dispose() zurückgegeben werden muss.
    hidden [bool]$_ownsRepository = $false

    # True, wenn der Crawler DatabasePool selbst geöffnet hat und ihn in
    # Dispose() schließen muss.
    hidden [bool]$_ownsPool = $false

    # Pool der Worker. Er bleibt über mehrere Scans erhalten, weil das Laden
    # der Module in jedem Worker Zeit kostet; Dispose() gibt ihn frei.
    hidden [System.Management.Automation.Runspaces.RunspacePool]$_workerPool
    hidden [int]$_workerPoolSize = 0

    # Schreib-Thread eines laufenden Scans: Warteschlange der Pakete,
    # zurückgemeldete Fehler und der Thread selbst. $null, wenn im
    # Hauptthread gespeichert wird.
    hidden [System.Collections.Concurrent.BlockingCollection[object]]$_writeQueue
    hidden [System.Collections.Concurrent.ConcurrentQueue[object]]$_writeResults
    hidden [powershell]$_writerShell
    hidden [System.IAsyncResult]$_writerHandle

    # Runspace des Schreib-Threads. Er bleibt wie der Worker-Pool über Scans
    # erhalten, damit Modul und Verbindung nur einmal geladen werden.
    hidden [System.Management.Automation.Runspaces.Runspace]$_writerRunspace

    # True, solange ScanFolder läuft und der Schreib-Thread beim ersten
    # Paket gestartet werden darf.
    hidden [bool]$_writerWanted = $false

    # True, solange ScanFolder läuft. Nur dann gehen Dateien in den
    # Hintergrund; ProcessFile() liest sie sofort.
    hidden [bool]$_inScanFolder = $false

    # Hintergrundverarbeitung: Dateien dieses Scans, die nach dem Scan
    # übergeben werden; Warteschlange, Rückmeldungen und Pfade, die gerade
    # verarbeitet werden. Der Runspace bleibt über Scans erhalten.
    hidden [System.Collections.Generic.List[object]]$_backgroundForScan
    hidden [System.Collections.Concurrent.BlockingCollection[object]]$_backgroundQueue
    hidden [System.Collections.Concurrent.ConcurrentQueue[object]]$_backgroundResults
    hidden [System.Collections.Concurrent.ConcurrentDictionary[string, byte]]$_backgroundPaths
    hidden [System.Management.Automation.Runspaces.Runspace]$_backgroundRunspace
    hidden [powershell]$_backgroundShell
    hidden [System.IAsyncResult]$_backgroundHandle


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

        $this._excludedExtensions = (
            [System.Collections.Generic.HashSet[string]]::new(
                [string[]]@($this.ExcludedFolderExtensions | Where-Object { $_ }),
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
        $this._pendingReads = [System.Collections.Generic.List[PendingRead]]::new()
        $this._backgroundForScan = [System.Collections.Generic.List[object]]::new()

        # Ergebnisse eines früheren Scans abholen, damit Zähler und Fehler
        # stimmen.
        $this._CollectBackgroundResults()

        $this._EnsureRepository()

        $repositoryType = $this.Repository.GetType()
        $this._repositoryHasRemoveBatch = $null -ne $repositoryType.GetMethod("RemoveBatch", [type[]]@([string[]]))
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

        # Der Schreib-Thread startet erst beim ersten Paket (_FlushSaves).
        $this._writerWanted = $true
        $this._inScanFolder = $true

        try {
            # Phase 1: auswählen. Phase 2: Inhalte lesen. Gespeichert wird
            # währenddessen im Schreib-Thread.
            $this._Traverse($rootPath)
            $this._ReadPendingContents()
            $this._FlushSaves()
        }
        finally {
            # Wartet, bis alle Pakete gespeichert sind, auch nach einem Fehler.
            $this._writerWanted = $false
            $this._inScanFolder = $false
            $this._StopWriter()
        }

        # Erst nach dem Schreiben, damit Speichern und Löschen sich nicht
        # gegenseitig sperren.
        if ($this.DetectDeletedFiles) {
            $this._RemoveDeletedFiles($rootPath)
        }

        # Erst jetzt, damit die Hintergrundverarbeitung dem Scan keine
        # Rechenzeit wegnimmt. Die Platzhalter sind bereits gespeichert.
        $this._StartBackground()
    }


    # Gibt Worker, Schreib-Thread und die geliehenen Verbindungen frei und
    # schließt den Pool, wenn der Crawler ihn selbst geöffnet hat. Nach dem
    # letzten Scan aufrufen; ein späterer Scan startet alles bei Bedarf neu.
    [void] Dispose() {
        $this._writerWanted = $false
        $this._StopWriter()
        $this._DisposeWriterRunspace()
        $this._StopBackground()
        $this._DisposeWorkerPool()

        if ($this._ownsRepository -and $null -ne $this.Repository) {
            # Gibt die Verbindung an den Pool zurück.
            $this.Repository.Dispose()
            $this.Repository = $null
            $this._ownsRepository = $false
        }

        if ($this._ownsPool -and $null -ne $this.DatabasePool) {
            $this.DatabasePool.Dispose()
            $this.DatabasePool = $null
            $this._ownsPool = $false
        }
    }


    # Holt eine Verbindung aus DatabasePool, falls kein Repository gesetzt
    # ist, und öffnet den Pool vorher selbst, falls auch keiner gesetzt ist.
    # Initialize-DatabasePool richtet beim ersten Mal auch die
    # SQLite-Bibliotheken unter lib/sqlite ein.
    hidden [void] _EnsureRepository() {
        if ($null -ne $this.Repository) {
            return
        }

        if ($null -eq $this.DatabasePool) {
            # Je eine Verbindung für Hauptthread, Schreib-Thread und
            # Hintergrundverarbeitung.
            $this.DatabasePool = Initialize-DatabasePool -DatabasePath $this.DatabasePath -PoolSize 3
            $this._ownsPool = $true
        }

        $lease = $this.DatabasePool.Borrow($this.PoolTimeoutMilliseconds)

        try {
            $this.Repository = [SqliteDateiRepository]::new($lease)
        }
        catch {
            $lease.Dispose()
            throw
        }

        $this._ownsRepository = $true
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
        $this._ReadPendingContents()
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

        if (
            $this._excludedExtensions.Count -gt 0 -and
            $this._excludedExtensions.Contains($folder.Extension)
        ) {
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
    # ist. Scheitert nur das Lesen des Inhalts, wird die Datei ohne Inhalt
    # gespeichert und zurückgegeben (siehe _MarkContentFailed). Scheitern
    # Metadaten oder Repository, wird nichts gespeichert, daher versucht der
    # nächste Scan die Datei erneut.
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

            # Wird von einem früheren Scan noch im Hintergrund gelesen: nicht
            # erneut einreihen.
            if ($null -ne $this._backgroundPaths -and $this._backgroundPaths.ContainsKey($filePath)) {
                $datei.Status = [DateiStatus]::Unchanged
                $this.UnchangedFiles++
                $this._Collect($datei)
                return $datei
            }

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

            if ($shouldRead -and $this._ShouldUseBackground($file)) {
                $this._QueueBackground($datei, $stored)
                return $datei
            }

            # Gelesen wird erst in Phase 2 (_ReadPendingContents), damit
            # mehrere Dateien gleichzeitig gelesen werden können.
            if ($shouldRead) {
                $pending = [PendingRead]::new()
                $pending.File = $file
                $pending.Datei = $datei
                $pending.Stored = $stored
                $this._pendingReads.Add($pending)

                return $datei
            }

            $this.ContentFilesSkipped++
            $this._FinishNewOrChanged($datei, $stored)

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


    # Zählt eine neue oder geänderte Datei, setzt ihren Status und reiht sie
    # zum Speichern ein.
    hidden [void] _FinishNewOrChanged([Datei]$datei, [Datei]$stored) {
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
    }


    # =============================================================================
    # INHALTE LESEN (PHASE 2)
    # =============================================================================

    # Liest alle vorgemerkten Dateien und leert die Liste. Parallel nur, wenn
    # es sich lohnt und die Worker denselben DocScanner nachbauen können: Zur
    # Laufzeit registrierte Reader kennt ein Worker nicht, dann wird
    # nacheinander gelesen.
    hidden [void] _ReadPendingContents() {
        if ($null -eq $this._pendingReads -or $this._pendingReads.Count -eq 0) {
            return
        }

        $items = [Crawler]::GroupByExtension($this._pendingReads)
        $this._pendingReads.Clear()

        $useWorkers = (
            $this.MaxParallelism -gt 1 -and
            $items.Length -ge $this.ParallelThreshold -and
            -not $this.DocScanner.HasCustomReaders()
        )

        if ($useWorkers) {
            $this._ReadParallel($items)
        }
        else {
            $this._ReadSequential($items, 0, $items.Length)
        }
    }


    # Ordnet die Dateien nach Endung, sonst in der gefundenen Reihenfolge.
    # So bestehen die Pakete der Worker möglichst aus gleichartigen Dateien:
    # Die Texterkennung erkennt alle Bilder eines Pakets in einem Aufruf
    # (DocScanner.Prepare). Liegen die Bilder verstreut zwischen anderen
    # Dateien, stehen in jedem Paket nur ein oder zwei und die Erkennung
    # startet fast für jedes Bild neu.
    hidden static [PendingRead[]] GroupByExtension([System.Collections.Generic.List[PendingRead]]$pending) {
        $groups = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[PendingRead]]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )

        foreach ($item in $pending) {
            $list = $null

            if (-not $groups.TryGetValue($item.File.Extension, [ref]$list)) {
                $list = [System.Collections.Generic.List[PendingRead]]::new()
                $groups[$item.File.Extension] = $list
            }

            $list.Add($item)
        }

        $ordered = [System.Collections.Generic.List[PendingRead]]::new($pending.Count)

        foreach ($list in $groups.Values) {
            $ordered.AddRange($list)
        }

        return $ordered.ToArray()
    }


    # Liest die Einträge [$start, $end) im Hauptthread.
    # Wie bei den Workern wird jedes Paket vorher an die Reader angekündigt
    # (DocScanner.Prepare).
    hidden [void] _ReadSequential([PendingRead[]]$items, [int]$start, [int]$end) {
        $batchSize = [Math]::Max(1, $this.ParallelBatchSize)

        for ($i = $start; $i -lt $end; $i++) {
            if (($i - $start) % $batchSize -eq 0) {
                $count = [Math]::Min($batchSize, $end - $i)
                $batchFiles = [System.IO.FileInfo[]]::new($count)

                for ($j = 0; $j -lt $count; $j++) {
                    $batchFiles[$j] = $items[$i + $j].File
                }

                $this.DocScanner.Prepare($batchFiles)
            }

            $item = $items[$i]

            try {
                $text = $this.DocScanner.ReadContent($item.File)
                $this._CompleteRead($item, $text)
            }
            catch {
                $this._MarkContentFailed($item.Datei, $item.Stored, $_.Exception.Message)
            }

            $this._WriteReadProgress($i + 1, $items.Length)
        }
    }


    # Verteilt die Einträge in Paketen auf die Worker. Es sind höchstens
    # doppelt so viele Pakete unterwegs wie Worker, damit nicht alle Texte
    # gleichzeitig im Speicher liegen. Die Ergebnisse werden in der
    # Reihenfolge der Pakete abgeholt und im Hauptthread verarbeitet.
    hidden [void] _ReadParallel([PendingRead[]]$items) {
        $pool = $this._GetWorkerPool()
        $batchSize = [Math]::Max(1, $this.ParallelBatchSize)
        $maxInFlight = 2 * $this._workerPoolSize
        $jobs = [System.Collections.Generic.Queue[object]]::new()
        $nextStart = 0
        $done = 0
        $workersFailed = $false

        while ($nextStart -lt $items.Length -or $jobs.Count -gt 0) {
            while (-not $workersFailed -and $jobs.Count -lt $maxInFlight -and $nextStart -lt $items.Length) {
                $count = [Math]::Min($batchSize, $items.Length - $nextStart)
                $paths = [string[]]::new($count)

                for ($i = 0; $i -lt $count; $i++) {
                    $paths[$i] = $items[$nextStart + $i].File.FullName
                }

                $shell = [powershell]::Create()
                $shell.RunspacePool = $pool
                [void]$shell.AddScript($script:WorkerScript)
                [void]$shell.AddParameter("ModulePath", $script:DocScannerModulePath)
                [void]$shell.AddParameter("MaxContentSizeBytes", $this.DocScanner.MaxContentSizeBytes)
                [void]$shell.AddParameter("Start", $nextStart)
                [void]$shell.AddParameter("Paths", $paths)

                $jobs.Enqueue([pscustomobject]@{
                    Shell  = $shell
                    Handle = $shell.BeginInvoke()
                    Start  = $nextStart
                    Count  = $count
                })

                $nextStart += $count
            }

            # Startet ein Worker gar nicht (z. B. Modul nicht ladbar), wird
            # der Rest im Hauptthread gelesen statt abzubrechen.
            if ($jobs.Count -eq 0) {
                $this._ReadSequential($items, $nextStart, $items.Length)
                break
            }

            $job = $jobs.Dequeue()

            try {
                $results = $job.Shell.EndInvoke($job.Handle)

                if ($results.Count -ne $job.Count) {
                    throw "Worker returned $($results.Count) of $($job.Count) results."
                }

                foreach ($result in $results) {
                    $item = $items[$result.Index]

                    if ($null -ne $result.Error) {
                        $this._MarkContentFailed($item.Datei, $item.Stored, $result.Error)
                    }
                    else {
                        $this._CompleteRead($item, [string]$result.Content)
                    }
                }
            }
            catch {
                $workersFailed = $true
                $this._ReadSequential($items, $job.Start, $job.Start + $job.Count)
            }
            finally {
                $job.Shell.Dispose()
            }

            $done += $job.Count
            $this._WriteReadProgress($done, $items.Length)

            if ($workersFailed -and $jobs.Count -eq 0 -and $nextStart -lt $items.Length) {
                $this._ReadSequential($items, $nextStart, $items.Length)
                $nextStart = $items.Length
            }
        }
    }


    # Erstellt den Pool beim ersten Bedarf oder neu, wenn MaxParallelism
    # geändert wurde. Die Worker selbst entstehen erst, wenn sie gebraucht
    # werden.
    hidden [System.Management.Automation.Runspaces.RunspacePool] _GetWorkerPool() {
        $size = [Math]::Max(1, $this.MaxParallelism)

        # Nur den Pool ersetzen; Datenbank und Schreib-Thread laufen weiter.
        if ($null -ne $this._workerPool -and $this._workerPoolSize -ne $size) {
            $this._DisposeWorkerPool()
        }

        if ($null -eq $this._workerPool) {
            $pool = [runspacefactory]::CreateRunspacePool(1, $size)
            $pool.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
            $pool.Open()

            $this._workerPool = $pool
            $this._workerPoolSize = $size
        }

        return $this._workerPool
    }


    hidden [void] _DisposeWorkerPool() {
        if ($null -eq $this._workerPool) {
            return
        }

        $this._workerPool.Close()
        $this._workerPool.Dispose()
        $this._workerPool = $null
        $this._workerPoolSize = 0
    }


    # Übernimmt den gelesenen Text einer vorgemerkten Datei.
    # Reader, die im Hintergrund noch etwas ergänzen (z. B. Objekte auf
    # Fotos), bekommen die Datei danach über _QueueEnrichment.
    hidden [void] _CompleteRead([PendingRead]$item, [string]$text) {
        $item.Datei.Content = $text
        $item.Datei.HasContent = $true
        $this.ContentFilesRead++

        if ($this._CanUseBackground() -and $this.DocScanner.CanEnrich($item.File)) {
            $this._QueueEnrichment($item.Datei, $item.Stored)
            return
        }

        $this._FinishNewOrChanged($item.Datei, $item.Stored)
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


    # Speichert eine Datei, deren Inhalt nicht gelesen werden konnte, ohne
    # Inhalt (HasContent = $false). Sie zählt als fehlgeschlagen und der Fehler
    # steht in Errors und in ContentError. Beim nächsten Scan ist sie
    # unverändert und wird übersprungen, bis sich ihre Änderungszeit ändert.
    hidden [void] _MarkContentFailed([Datei]$datei, [Datei]$stored, [string]$message) {
        $datei.Content = $null
        $datei.HasContent = $false
        $datei.ContentError = $message
        $datei.IndexedAtUtc = [datetime]::UtcNow

        if ($null -eq $stored) {
            $datei.Status = [DateiStatus]::New
        }
        else {
            $datei.Status = [DateiStatus]::Changed
        }

        $this.FailedFiles++
        $this._AddError($datei.Path, [ScanPhase]::Content, $message)
        $this._QueueSave($datei)
        $this._Collect($datei)
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


    # Gibt das aktuelle Paket an den Schreib-Thread oder speichert es direkt.
    hidden [void] _FlushSaves() {
        if ($null -eq $this._pendingSaves -or $this._pendingSaves.Count -eq 0) {
            return
        }

        $batch = $this._pendingSaves.ToArray()
        $this._pendingSaves.Clear()

        if ($this._writerWanted -and $null -eq $this._writerShell) {
            $this._StartWriter()
        }

        if ($null -ne $this._writeQueue) {
            # Blockiert nur, wenn die Warteschlange voll ist.
            $this._writeQueue.Add($batch)
            $this._CollectWriterResults()
            return
        }

        $this._SaveNow($batch)
    }


    hidden [void] _SaveNow([Datei[]]$batch) {
        try {
            $this.Repository.SaveBatch($batch)
        }
        catch {
            $this._MarkSaveFailed($batch, $_.Exception.Message)
        }
    }


    # Korrigiert die Zähler für ein Paket, das nicht gespeichert wurde. Die
    # Dateien wurden beim Einreihen als neu oder geändert gezählt. Dateien
    # mit ContentError zählen bereits als fehlgeschlagen.
    hidden [void] _MarkSaveFailed([Datei[]]$batch, [string]$message) {
        foreach ($datei in $batch) {
            if (-not [string]::IsNullOrEmpty($datei.ContentError)) {
                $this._AddError($datei.Path, [ScanPhase]::Repository, $message)
                continue
            }

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


    # =============================================================================
    # SCHREIB-THREAD
    # =============================================================================

    # Startet den Schreib-Thread, wenn das Repository aus DatabasePool
    # stammt. Sonst bleibt die Warteschlange leer und _FlushSaves speichert
    # im Hauptthread. Wird höchstens einmal pro Scan aufgerufen, weil
    # _writerShell danach gesetzt ist bzw. _writerWanted zurückgesetzt wird.
    hidden [void] _StartWriter() {
        if (
            -not $this.UseWriterThread -or
            -not $this._ownsRepository -or
            $null -eq $this.DatabasePool
        ) {
            $this._writerWanted = $false
            return
        }

        if ($null -eq $this._writerRunspace) {
            $this._writerRunspace = [runspacefactory]::CreateRunspace()
            $this._writerRunspace.Open()
        }

        $this._writeQueue = [System.Collections.Concurrent.BlockingCollection[object]]::new(
            [Math]::Max(1, $this.WriterQueueCapacity)
        )
        $this._writeResults = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()

        $shell = [powershell]::Create()
        $shell.Runspace = $this._writerRunspace
        [void]$shell.AddScript($script:WriterScript)
        [void]$shell.AddParameter("ModulePath", $script:SqliteModulePath)
        [void]$shell.AddParameter("Pool", $this.DatabasePool)
        # Höchstens 2 Sekunden: Ist der Pool ausgelastet, speichert besser
        # der Hauptthread selbst, statt den Scan lange warten zu lassen.
        [void]$shell.AddParameter("BorrowTimeoutMilliseconds", [Math]::Min($this.PoolTimeoutMilliseconds, 2000))
        [void]$shell.AddParameter("Queue", $this._writeQueue)
        [void]$shell.AddParameter("Results", $this._writeResults)

        $this._writerShell = $shell
        $this._writerHandle = $shell.BeginInvoke()
    }


    # Schließt die Warteschlange, wartet, bis der Schreib-Thread alle Pakete
    # gespeichert hat, und übernimmt seine Fehler.
    hidden [void] _StopWriter() {
        if ($null -eq $this._writerShell) {
            return
        }

        $this._writeQueue.CompleteAdding()

        try {
            [void]$this._writerShell.EndInvoke($this._writerHandle)
        }
        catch {
            # Bricht der Thread selbst ab, bleiben unverarbeitete Pakete in
            # der Warteschlange; sie werden unten im Hauptthread gespeichert.
            $this._AddError($this.DatabasePath, [ScanPhase]::Repository, $_.Exception.Message)
        }
        finally {
            $this._writerShell.Dispose()
            $this._writerShell = $null
            $this._writerHandle = $null
        }

        $remaining = $this._writeQueue
        $this._writeQueue = $null

        $this._CollectWriterResults()

        foreach ($batch in $remaining.GetConsumingEnumerable()) {
            $this._SaveNow($batch)
        }

        $remaining.Dispose()
        $this._writeResults = $null
    }


    # Gibt die Verbindung des Schreib-Threads an den Pool zurück und schließt
    # seinen Runspace.
    hidden [void] _DisposeWriterRunspace() {
        if ($null -eq $this._writerRunspace) {
            return
        }

        $shell = [powershell]::Create()

        try {
            $shell.Runspace = $this._writerRunspace
            [void]$shell.AddScript($script:WriterCleanupScript)
            [void]$shell.Invoke()
        }
        catch {
            # Die Verbindung schließt spätestens Dispose() des Pools.
        }
        finally {
            $shell.Dispose()
            $this._writerRunspace.Dispose()
            $this._writerRunspace = $null
        }
    }


    # Übernimmt die Rückmeldungen des Schreib-Threads im Hauptthread.
    hidden [void] _CollectWriterResults() {
        if ($null -eq $this._writeResults) {
            return
        }

        $result = $null

        while ($this._writeResults.TryDequeue([ref]$result)) {
            if ($result.Retry) {
                # Der Thread konnte die Datenbank nicht öffnen.
                $this._SaveNow([Datei[]]$result.Batch)
            }
            else {
                $this._MarkSaveFailed([Datei[]]$result.Batch, [string]$result.Message)
            }
        }
    }


    # =============================================================================
    # HINTERGRUNDVERARBEITUNG
    # =============================================================================

    # Anzahl der Dateien, die noch im Hintergrund gelesen werden.
    [int] GetBackgroundPending() {
        if ($null -eq $this._backgroundPaths) {
            return 0
        }

        return $this._backgroundPaths.Count
    }


    # Wartet höchstens $timeoutMilliseconds (negativ: unbegrenzt), bis die
    # Hintergrundverarbeitung fertig ist, und übernimmt ihre Ergebnisse in
    # Zähler und Fehlerliste. Gibt $true zurück, wenn nichts mehr offen ist.
    [bool] WaitForBackground([int]$timeoutMilliseconds) {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        while ($true) {
            $this._CollectBackgroundResults()

            if ($this.GetBackgroundPending() -eq 0) {
                return $true
            }

            # Ist der Thread selbst abgebrochen, wird nichts mehr fertig.
            # Die Platzhalter bleiben gespeichert, der nächste Scan versucht
            # es erneut.
            if ($null -eq $this._backgroundHandle -or $this._backgroundHandle.IsCompleted) {
                $this._RestartBackgroundAfterFailure()
                return $true
            }

            if ($timeoutMilliseconds -ge 0 -and $stopwatch.ElapsedMilliseconds -ge $timeoutMilliseconds) {
                return $false
            }

            [System.Threading.Thread]::Sleep(100)
        }

        return $true
    }


    # Hintergrundverarbeitung ist möglich: nur während ScanFolder, mit der
    # Datenbank aus dem Pool und ohne zur Laufzeit registrierte Reader (die
    # kennt der Hintergrund-Thread nicht).
    hidden [bool] _CanUseBackground() {
        return (
            $this._inScanFolder -and
            $this.BackgroundProcessing -and
            $this._ownsRepository -and
            $null -ne $this.DatabasePool -and
            -not $this.DocScanner.HasCustomReaders()
        )
    }


    hidden [bool] _ShouldUseBackground([System.IO.FileInfo]$file) {
        return $this._CanUseBackground() -and $this.DocScanner.RunsInBackground($file)
    }


    # Wie _QueueBackground, aber für eine bereits gelesene Datei, die im
    # Hintergrund nur ergänzt wird (ContentReader.CanEnrich). Der
    # Platzhalter enthält den gelesenen Inhalt, ist also sofort durchsuchbar.
    hidden [void] _QueueEnrichment([Datei]$datei, [Datei]$stored) {
        $placeholder = $datei.CopyWithoutContent()
        $placeholder.Content = $datei.Content
        $placeholder.HasContent = $datei.HasContent
        $placeholder.LastWriteTimeUtc = $datei.LastWriteTimeUtc.AddTicks(-1)

        $this._FinishNewOrChanged($placeholder, $stored)
        $datei.Status = $placeholder.Status

        $this.BackgroundFiles++
        $this._backgroundForScan.Add([pscustomobject]@{ Datei = $datei; Enrich = $true })
    }


    # Speichert sofort einen Platzhalter ohne Inhalt und merkt die Datei für
    # die Hintergrundverarbeitung vor. Der Platzhalter trägt eine um einen
    # Tick (100 ns) frühere Änderungszeit: Endet das Programm, bevor die
    # Datei im Hintergrund fertig ist, gilt sie beim nächsten Scan als
    # geändert und wird erneut eingereiht. Ist sie fertig, speichert der
    # Hintergrund die echte Zeit. So geht nichts verloren, ohne dass die
    # Datenbank ein eigenes Feld dafür braucht.
    hidden [void] _QueueBackground([Datei]$datei, [Datei]$stored) {
        $placeholder = $datei.CopyWithoutContent()
        $placeholder.LastWriteTimeUtc = $datei.LastWriteTimeUtc.AddTicks(-1)
        $placeholder.HasContent = $false

        $this._FinishNewOrChanged($placeholder, $stored)
        $datei.Status = $placeholder.Status

        $this.BackgroundFiles++
        $this._backgroundForScan.Add([pscustomobject]@{ Datei = $datei; Enrich = $false })
    }


    # Übergibt die Dateien des Scans an den Hintergrund und startet ihn beim
    # ersten Mal.
    hidden [void] _StartBackground() {
        if ($null -eq $this._backgroundForScan -or $this._backgroundForScan.Count -eq 0) {
            return
        }

        if ($null -ne $this._backgroundHandle -and $this._backgroundHandle.IsCompleted) {
            $this._RestartBackgroundAfterFailure()
        }

        if ($null -eq $this._backgroundPaths) {
            $this._backgroundPaths = [System.Collections.Concurrent.ConcurrentDictionary[string, byte]]::new(
                [PathUtil]::GetComparer()
            )
        }

        if ($null -eq $this._backgroundShell) {
            $this._backgroundQueue = [System.Collections.Concurrent.BlockingCollection[object]]::new()
            $this._backgroundResults = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()

            if ($null -eq $this._backgroundRunspace) {
                $this._backgroundRunspace = [runspacefactory]::CreateRunspace()
                $this._backgroundRunspace.Open()
            }

            $shell = [powershell]::Create()
            $shell.Runspace = $this._backgroundRunspace
            [void]$shell.AddScript($script:BackgroundScript)
            [void]$shell.AddParameter("DocScannerModulePath", $script:DocScannerModulePath)
            [void]$shell.AddParameter("SqliteModulePath", $script:SqliteModulePath)
            [void]$shell.AddParameter("Pool", $this.DatabasePool)
            [void]$shell.AddParameter("BorrowTimeoutMilliseconds", $this.PoolTimeoutMilliseconds)
            [void]$shell.AddParameter("Queue", $this._backgroundQueue)
            [void]$shell.AddParameter("Results", $this._backgroundResults)
            [void]$shell.AddParameter("Paths", $this._backgroundPaths)

            $this._backgroundShell = $shell
            $this._backgroundHandle = $shell.BeginInvoke()
        }

        foreach ($item in $this._backgroundForScan) {
            $this._backgroundPaths[$item.Datei.Path] = 0
            $this._backgroundQueue.Add($item)
        }

        $this._backgroundForScan.Clear()
    }


    # Übernimmt die Rückmeldungen der Hintergrundverarbeitung im Hauptthread.
    hidden [void] _CollectBackgroundResults() {
        if ($null -eq $this._backgroundResults) {
            return
        }

        $result = $null

        while ($this._backgroundResults.TryDequeue([ref]$result)) {
            if ([string]::IsNullOrEmpty($result.Error)) {
                $this.BackgroundCompleted++
            }
            else {
                $this.BackgroundFailed++
                $this._AddError($result.Path, [ScanPhase]::Content, $result.Error)
            }
        }
    }


    # Der Hintergrund-Thread ist unerwartet beendet: Fehler melden, offene
    # Pfade vergessen (ihre Platzhalter bleiben gespeichert) und beim
    # nächsten Mal neu starten.
    hidden [void] _RestartBackgroundAfterFailure() {
        if ($null -eq $this._backgroundShell) {
            return
        }

        try {
            [void]$this._backgroundShell.EndInvoke($this._backgroundHandle)
        }
        catch {
            $this._AddError("", [ScanPhase]::Content, "Background processing stopped: " + $_.Exception.Message)
        }

        $this._CollectBackgroundResults()
        $this._backgroundShell.Dispose()
        $this._backgroundShell = $null
        $this._backgroundHandle = $null
        $this._backgroundQueue = $null

        if ($null -ne $this._backgroundPaths) {
            $this._backgroundPaths.Clear()
        }
    }


    # Beendet die Hintergrundverarbeitung. Noch nicht begonnene Dateien
    # werden aus der Warteschlange genommen (ihre Platzhalter bleiben, der
    # nächste Scan reiht sie erneut ein); auf die gerade laufende Datei wird
    # gewartet, damit ihre Verbindung sauber zurückgegeben wird.
    hidden [void] _StopBackground() {
        if ($null -ne $this._backgroundShell) {
            $item = $null

            while ($this._backgroundQueue.TryTake([ref]$item)) {
                $removed = [byte]0
                [void]$this._backgroundPaths.TryRemove($item.Datei.Path, [ref]$removed)
            }

            $this._backgroundQueue.CompleteAdding()

            try {
                [void]$this._backgroundShell.EndInvoke($this._backgroundHandle)
            }
            catch {
                $this._AddError("", [ScanPhase]::Content, "Background processing stopped: " + $_.Exception.Message)
            }

            $this._CollectBackgroundResults()
            $this._backgroundShell.Dispose()
            $this._backgroundShell = $null
            $this._backgroundHandle = $null
            $this._backgroundQueue = $null
        }

        if ($null -ne $this._backgroundRunspace) {
            $cleanup = [powershell]::Create()

            try {
                $cleanup.Runspace = $this._backgroundRunspace
                [void]$cleanup.AddScript($script:BackgroundCleanupScript)
                [void]$cleanup.Invoke()
            }
            catch {
                # Die Verbindung schließt spätestens Dispose() des Pools.
            }
            finally {
                $cleanup.Dispose()
                $this._backgroundRunspace.Dispose()
                $this._backgroundRunspace = $null
            }
        }

        if ($null -ne $this._backgroundPaths) {
            $this._backgroundPaths.Clear()
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

        $deletedPaths = [System.Collections.Generic.List[string]]::new()

        foreach ($path in $storedPaths) {
            if (-not $this._seenPaths.Contains($path) -and -not $this._IsBelowFailedFolder($path)) {
                $deletedPaths.Add($path)
            }
        }

        # Mit RemoveBatch in Paketen löschen (bei SQLite eine Transaktion pro
        # Aufruf). Scheitert ein Paket, wird es einzeln gelöscht, damit ein
        # Fehler dem richtigen Pfad zugeordnet wird.
        $batchSize = [Math]::Max(1, $this.SaveBatchSize)

        for ($start = 0; $start -lt $deletedPaths.Count; $start += $batchSize) {
            $count = [Math]::Min($batchSize, $deletedPaths.Count - $start)
            $chunk = $deletedPaths.GetRange($start, $count).ToArray()
            $removedAsBatch = $false

            if ($this._repositoryHasRemoveBatch) {
                try {
                    $this.Repository.RemoveBatch($chunk)
                    $removedAsBatch = $true
                }
                catch {
                    $removedAsBatch = $false
                }
            }

            foreach ($path in $chunk) {
                if (-not $removedAsBatch) {
                    try {
                        $this.Repository.Remove($path)
                    }
                    catch {
                        $this._AddError($path, [ScanPhase]::Repository, $_.Exception.Message)
                        continue
                    }
                }

                $this._MarkDeleted($path)
            }
        }
    }


    hidden [void] _MarkDeleted([string]$path) {
        $this.DeletedFiles++

        if ($this.CollectFiles) {
            $deleted = [Datei]::new()
            $deleted.Path = $path
            $deleted.Name = [System.IO.Path]::GetFileName($path)
            $deleted.Status = [DateiStatus]::Deleted
            $this.Files.Add($deleted)
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


    hidden [void] _WriteReadProgress([int]$done, [int]$total) {
        if (
            $this.ProgressOutput -and
            $this.ProgressInterval -gt 0 -and
            ($done % $this.ProgressInterval -eq 0 -or $done -eq $total)
        ) {
            Write-Host ("Read: {0} of {1} | Failed: {2}" -f $done, $total, $this.FailedFiles)
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
            BackgroundFiles     = $this.BackgroundFiles
            BackgroundCompleted = $this.BackgroundCompleted
            BackgroundFailed    = $this.BackgroundFailed
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
        $this.BackgroundFiles = 0
        $this.BackgroundCompleted = 0
        $this.BackgroundFailed = 0
    }
}

#requires -Version 7.2


# Ergebnis des Vergleichs einer Datei mit dem im Repository gespeicherten Stand.
enum DateiStatus {
    New         # noch nicht im Repository
    Changed     # gespeichert, aber die Änderungszeit hat sich seitdem geändert
    Unchanged   # gespeichert mit derselben Änderungszeit
    Deleted     # gespeichert, aber nicht mehr auf der Festplatte
}


# Eine Datei des Index. Diese Klasse ist die Schnittstelle zwischen Crawler,
# Datenbank und GUI. Alle Zeitstempel sind UTC; nur für die Anzeige mit
# .ToLocalTime() umwandeln.
class Datei {
    [string]$Name
    [string]$Path

    # Endung in Kleinbuchstaben mit Punkt, z. B. ".pdf". Leer, wenn keine.
    [string]$Extension

    [long]$Size
    [datetime]$CreationTimeUtc
    [datetime]$LastWriteTimeUtc

    # Zeitpunkt, zu dem der Crawler die Datei zuletzt im Repository gespeichert hat.
    [datetime]$IndexedAtUtc

    # Extrahierter Klartext. Nur gefüllt, wenn die Datei New oder Changed ist
    # und ein Reader des DocScanners ihren Typ unterstützt.
    [string]$Content

    # True, wenn ein Reader den Inhalt gelesen hat (auch wenn der Text leer ist).
    [bool]$HasContent

    # True, wenn nur ein Cloud-Platzhalter auf der Festplatte lag (iCloud,
    # OneDrive, ...) und der Inhalt deshalb nicht gelesen wurde. Der nächste
    # Scan liest ihn, sobald die Datei heruntergeladen ist.
    [bool]$IsCloudOnly

    [DateiStatus]$Status = [DateiStatus]::New


    # Füllt die Metadaten aus einem FileInfo, das beim Auflisten eines Ordners
    # entsteht. Dafür ist kein zusätzlicher Zugriff auf das Dateisystem nötig.
    static [Datei] FromFileInfo([System.IO.FileInfo]$file) {
        $datei = [Datei]::new()
        $datei.Name = $file.Name
        $datei.Path = $file.FullName
        $datei.Extension = $file.Extension.ToLowerInvariant()
        $datei.Size = $file.Length
        $datei.CreationTimeUtc = $file.CreationTimeUtc
        $datei.LastWriteTimeUtc = $file.LastWriteTimeUtc

        return $datei
    }


    # Kopie aller Felder außer dem Inhalt, z. B. um Metadaten im Speicher zu
    # halten, ohne große Texte mitzuführen.
    [Datei] CopyWithoutContent() {
        $copy = [Datei]::new()
        $copy.Name = $this.Name
        $copy.Path = $this.Path
        $copy.Extension = $this.Extension
        $copy.Size = $this.Size
        $copy.CreationTimeUtc = $this.CreationTimeUtc
        $copy.LastWriteTimeUtc = $this.LastWriteTimeUtc
        $copy.IndexedAtUtc = $this.IndexedAtUtc
        $copy.HasContent = $this.HasContent
        $copy.IsCloudOnly = $this.IsCloudOnly
        $copy.Status = $this.Status

        return $copy
    }


    [string[]] print() {
        $output = @(
            "Name: $($this.Name)"
            "Path: $($this.Path)"
            "Extension: $($this.Extension)"
            "Size: $($this.Size) bytes"
            "Creation Time: $($this.CreationTimeUtc.ToLocalTime())"
            "Last Write Time: $($this.LastWriteTimeUtc.ToLocalTime())"
            "Status: $($this.Status)"
        )

        if ($this.HasContent) {
            $output += "Content: $($this.Content.Length) characters"
        }

        if ($this.IsCloudOnly) {
            $output += "Content: not read (cloud placeholder)"
        }

        $output += ""
        return $output
    }


    [System.Collections.Hashtable] ToHashtable() {
        return @{
            Name             = $this.Name
            Path             = $this.Path
            Extension        = $this.Extension
            Size             = $this.Size
            CreationTimeUtc  = $this.CreationTimeUtc
            LastWriteTimeUtc = $this.LastWriteTimeUtc
            IndexedAtUtc     = $this.IndexedAtUtc
            Content          = $this.Content
            HasContent       = $this.HasContent
            IsCloudOnly      = $this.IsCloudOnly
            Status           = $this.Status.ToString()
        }
    }


    [PSCustomObject] ToObject() {
        return [PSCustomObject]$this.ToHashtable()
    }
}

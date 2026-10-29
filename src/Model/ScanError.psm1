#requires -Version 7.2


# Schritt, in dem ein Fehler aufgetreten ist.
enum ScanPhase {
    Folder      # Auflisten eines Ordners fehlgeschlagen (z. B. Zugriff verweigert)
    Metadata    # Lesen der Metadaten fehlgeschlagen
    Content     # Auslesen des Inhalts fehlgeschlagen
    Repository  # Lesen aus dem oder Schreiben in das Repository fehlgeschlagen
}


# Ein Fehler eines Scans. Er wird als Objekt gespeichert, damit die GUI nach
# Phase oder Pfad filtern kann, statt Text auswerten zu müssen.
class ScanError {
    [string]$Path
    [ScanPhase]$Phase
    [string]$Message
    [datetime]$TimeUtc

    ScanError([string]$path, [ScanPhase]$phase, [string]$message) {
        $this.Path = $path
        $this.Phase = $phase
        $this.Message = $message
        $this.TimeUtc = [datetime]::UtcNow
    }

    [string] ToString() {
        return "[{0}] {1} - {2}" -f $this.Phase, $this.Path, $this.Message
    }
}

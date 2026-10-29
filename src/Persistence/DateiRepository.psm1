using module "../Common/PathUtil.psm1"
using module "../Model/Datei.psm1"

#requires -Version 7.2


# =============================================================================
# SCHNITTSTELLE DES REPOSITORYS
# =============================================================================

# Der Crawler arbeitet nur mit dieser Schnittstelle. Dadurch lässt sich der
# Speicher austauschen, ohne den Crawler zu ändern. Ein Speicher (im
# Arbeitsspeicher, SQLite, MSSQL, ...) erbt von dieser Klasse und
# überschreibt die Methoden, die eine Ausnahme werfen.
#
# PowerShell kennt keine abstrakten Klassen, deshalb werfen die Methoden der
# Basisklasse stattdessen eine Ausnahme.
class DateiRepository {

    # Gibt die gespeicherte Datei zurück (der Inhalt darf fehlen) oder $null,
    # wenn der Pfad nicht gespeichert ist.
    [Datei] Get([string]$path) {
        throw "Get() must be implemented by a derived class."
    }

    # Fügt die Datei samt Inhalt ein oder ersetzt sie.
    [void] Save([Datei]$datei) {
        throw "Save() must be implemented by a derived class."
    }

    # Entfernt eine Datei aus dem Index.
    [void] Remove([string]$path) {
        throw "Remove() must be implemented by a derived class."
    }

    # Gibt alle gespeicherten Pfade im Ordner und seinen Unterordnern zurück.
    # Damit werden Dateien gefunden, die seit dem letzten Scan gelöscht wurden.
    [string[]] GetPathsUnder([string]$folderPath) {
        throw "GetPathsUnder() must be implemented by a derived class."
    }

    # Speichert mehrere Dateien auf einmal. Überschreiben, um eine einzige
    # Datenbank-Transaktion zu verwenden; standardmäßig wird einzeln gespeichert.
    [void] SaveBatch([Datei[]]$dateien) {
        foreach ($datei in $dateien) {
            $this.Save($datei)
        }
    }
}


# =============================================================================
# IMPLEMENTIERUNG IM ARBEITSSPEICHER
# =============================================================================

# Speichert nur die Metadaten, nicht den Inhalt, damit der Speicherbedarf auch
# bei großen Scans klein bleibt. Die Daten gehen verloren, wenn die
# PowerShell-Sitzung endet.
class InMemoryDateiRepository : DateiRepository {

    hidden [System.Collections.Generic.Dictionary[string, Datei]]$_store = (
        [System.Collections.Generic.Dictionary[string, Datei]]::new(
            [PathUtil]::GetComparer()
        )
    )

    [int] Count() {
        return $this._store.Count
    }

    [Datei] Get([string]$path) {
        $datei = $null

        if ($this._store.TryGetValue($path, [ref]$datei)) {
            return $datei
        }

        return $null
    }

    [void] Save([Datei]$datei) {
        $this._store[$datei.Path] = $datei.CopyWithoutContent()
    }

    [void] Remove([string]$path) {
        [void]$this._store.Remove($path)
    }

    [string[]] GetPathsUnder([string]$folderPath) {
        $folder = [PathUtil]::Normalize($folderPath)

        $paths = [System.Collections.Generic.List[string]]::new()

        foreach ($path in $this._store.Keys) {
            if ([PathUtil]::IsSameOrUnder($path, $folder)) {
                $paths.Add($path)
            }
        }

        return $paths.ToArray()
    }
}

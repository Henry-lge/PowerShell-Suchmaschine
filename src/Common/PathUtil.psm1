#requires -Version 7.2


# =============================================================================
# PFAD-HILFSFUNKTIONEN
# =============================================================================

# Die Dateisysteme von Windows und macOS unterscheiden standardmäßig nicht
# zwischen Groß- und Kleinschreibung, Linux schon. Alle Pfad-Mengen und
# Suchen verwenden deshalb den passenden Vergleich.
class PathUtil {

    static [System.StringComparer] GetComparer() {
        if ($global:IsLinux) {
            return [System.StringComparer]::Ordinal
        }

        return [System.StringComparer]::OrdinalIgnoreCase
    }


    static [System.StringComparison] GetComparison() {
        if ($global:IsLinux) {
            return [System.StringComparison]::Ordinal
        }

        return [System.StringComparison]::OrdinalIgnoreCase
    }


    # Absoluter Pfad ohne abschließendes Trennzeichen, damit "C:\Docs\" und
    # "C:\Docs" gleich behandelt werden. Wurzelordner behalten ihr
    # Trennzeichen ("/" und "C:\"), weil "" und "C:" keine gültigen
    # Wurzelpfade sind.
    static [string] Normalize([string]$path) {
        $fullPath = [System.IO.Path]::GetFullPath($path)

        return [System.IO.Path]::TrimEndingDirectorySeparator($fullPath)
    }


    # True, wenn $path der Ordner $folderPath selbst ist oder irgendwo darunter
    # liegt. Beide Pfade müssen bereits normalisiert sein.
    static [bool] IsSameOrUnder([string]$path, [string]$folderPath) {
        $comparison = [PathUtil]::GetComparison()

        if ([string]::Equals($path, $folderPath, $comparison)) {
            return $true
        }

        # Das Trennzeichen verhindert, dass "/docs-old" zu "/docs" passt.
        # Wurzelordner enden bereits mit einem Trennzeichen ("/", "C:\").
        $prefix = $folderPath

        if (-not [System.IO.Path]::EndsInDirectorySeparator($prefix)) {
            $prefix += [System.IO.Path]::DirectorySeparatorChar
        }

        return $path.StartsWith($prefix, $comparison)
    }
}

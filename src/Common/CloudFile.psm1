#requires -Version 7.2


# =============================================================================
# NATIVE HILFSFUNKTION (macOS)
# =============================================================================

# .NET stellt die BSD-Dateiflags von macOS nicht bereit, deshalb wird lstat()
# direkt aufgerufen. Add-Type kompiliert den Code einmal pro PowerShell-Sitzung.
if (-not ("Suchmaschine.Native.DarwinFileFlags" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace Suchmaschine.Native
{
    public static class DarwinFileFlags
    {
        // Apple Silicon verwendet die Struktur mit 64-Bit-Inode unter dem
        // normalen Namen, Intel-Macs unter dem Namen mit Suffix. Der Aufbau
        // ist bei beiden gleich.
        [DllImport("libc", EntryPoint = "lstat")]
        private static extern int LstatArm64(string path, byte[] buffer);

        [DllImport("libc", EntryPoint = "lstat`$INODE64")]
        private static extern int LstatX64(string path, byte[] buffer);

        // Position von st_flags in struct stat (Aufbau mit 64-Bit-Inode).
        private const int FlagsOffset = 116;

        // Der Dateiinhalt liegt nicht auf der Festplatte und wird beim
        // ersten Zugriff geladen.
        private const uint SF_DATALESS = 0x40000000;

        public static bool IsDataless(string path)
        {
            byte[] buffer = new byte[256];

            int result = RuntimeInformation.ProcessArchitecture == Architecture.X64
                ? LstatX64(path, buffer)
                : LstatArm64(path, buffer);

            if (result != 0)
            {
                return false;
            }

            return (BitConverter.ToUInt32(buffer, FlagsOffset) & SF_DATALESS) != 0;
        }
    }
}
"@
}


# =============================================================================
# ERKENNUNG VON CLOUD-PLATZHALTERN
# =============================================================================

# Cloud-Dienste (iCloud "Mac-Speicher optimieren", OneDrive "Dateien bei
# Bedarf", Dropbox, ...) können nur einen Platzhalter auf der Festplatte
# lassen. Wird eine solche Datei gelesen, wird sie zuerst heruntergeladen,
# was einen Scan extrem verlangsamt. Die Metadaten eines Platzhalters (Name,
# Größe, Zeitstempel) sind ohne Download verfügbar.
class CloudFile {

    # Windows-Attribute von Platzhaltern, die beim Zugriff heruntergeladen
    # werden: Offline, RecallOnOpen, RecallOnDataAccess.
    hidden static [int]$WindowsCloudAttributes = 0x1000 -bor 0x40000 -bor 0x400000

    # Der native Typ wird beim Laden des Moduls kompiliert, also erst nachdem
    # die Klasse eingelesen wurde. Deshalb wird er über seinen Namen statt
    # über ein Typ-Literal aufgelöst.
    hidden static [type]$_darwinFlags = $null


    static [bool] IsCloudOnly([System.IO.FileInfo]$file) {
        if ($global:IsWindows) {
            return (
                ([int]$file.Attributes -band [CloudFile]::WindowsCloudAttributes) -ne 0
            )
        }

        if ($global:IsMacOS) {
            if ($null -eq [CloudFile]::_darwinFlags) {
                [CloudFile]::_darwinFlags = "Suchmaschine.Native.DarwinFileFlags" -as [type]
            }

            return [CloudFile]::_darwinFlags::IsDataless($file.FullName)
        }

        return $false
    }
}

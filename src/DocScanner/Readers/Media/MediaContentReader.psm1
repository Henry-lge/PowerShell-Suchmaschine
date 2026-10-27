using module "../ContentReader.psm1"

#requires -Version 7.2


# =============================================================================
# READER FÜR MEDIEN (TODO)
# =============================================================================

# Audio- und Videodateien enthalten keinen Text, aber ihre Tags (Titel,
# Interpret, Album, Jahr, Kommentar) machen sie durchsuchbar.
#
# Möglichkeiten:
#   - "ffprobe" aus FFmpeg (Windows, macOS über Homebrew, Linux):
#       ffprobe -v quiet -print_format json -show_format <datei>
#     Die Tags stehen in format.tags des JSON (ConvertFrom-Json).
#   - .NET-Bibliothek TagLibSharp, geladen über Add-Type -Path.
#   - Nur Windows: COM-Objekt Shell.Application (Dateieigenschaften).
#
# Erweiterung (KI, optional): Sprache mit einem Modell wie Whisper
# transkribieren und die Abschrift als Inhalt zurückgeben.
#
# Startpunkt:
#   $tool = $this.FindTool(@("ffprobe"))
#   $json = $this.RunTool($tool, @("-v", "quiet", "-print_format", "json", "-show_format", $file.FullName))
#   $tags = ($json | ConvertFrom-Json).format.tags
class MediaContentReader : ContentReader {

    MediaContentReader() {
        $this.Description = "Audio and video (tags)"
        $this.Extensions = @(
            ".mp3", ".m4a", ".flac", ".wav", ".ogg", ".aac",
            ".mp4", ".m4v", ".mov", ".mkv", ".avi", ".webm"
        )
    }

    # TODO: $true zurückgeben, sobald ReadContent() implementiert ist. Bei
    # einem externen Tool stattdessen prüfen, ob es installiert ist:
    #   return $this.HasTool(@("ffprobe"))
    [bool] IsAvailable() {
        return $false
    }

    # TODO: Die Tags als Text zurückgeben, z. B. eine Zeile "Name: Wert" pro Tag.
    [string] ReadContent([System.IO.FileInfo]$file) {
        throw [System.NotImplementedException]::new("MediaContentReader.ReadContent()")
    }
}

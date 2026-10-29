using module "../ContentReader.psm1"

#requires -Version 7.2


# =============================================================================
# READER FÜR BILDER MIT TEXTERKENNUNG (TODO)
# =============================================================================

# Erkennt Text in Bildern (Scans, Fotos von Dokumenten, Screenshots).
#
# Möglichkeiten:
#   - Tesseract OCR (Windows, macOS über Homebrew, Linux):
#       tesseract <datei> stdout -l deu+eng
#     "stdout" schreibt den Text in die Standardausgabe. Die deutschen
#     Sprachdaten ("deu") müssen eventuell separat installiert werden.
#   - Windows 10/11: eingebaute Texterkennung über Windows.Media.Ocr (WinRT,
#     nur Windows).
#
# Texterkennung ist langsam (etwa eine Sekunde pro Bild). Eine Größengrenze
# ist sinnvoll, z. B. in ReadContent() Bilder unter 20 KB (Icons)
# überspringen.
#
# Bilder-KI (optional, aus der Aufgabenstellung): Statt oder zusätzlich zur
# Texterkennung könnte ein KI-Modell eine Bildbeschreibung erzeugen, die als
# Inhalt zurückgegeben wird. So werden Fotos nach dem durchsuchbar, was sie
# zeigen.
#
# Startpunkt:
#   $tool = $this.FindTool(@("tesseract"))
#   return $this.RunTool($tool, @($file.FullName, "stdout", "-l", "deu+eng"), 120)
class ImageOcrContentReader : ContentReader {

    ImageOcrContentReader() {
        $this.Description = "Images (text recognition)"
        $this.Extensions = @(
            ".png", ".jpg", ".jpeg",
            ".tif", ".tiff", ".bmp",
            ".gif", ".webp", ".heic"
        )
    }

    # TODO: $true zurückgeben, sobald ReadContent() implementiert ist. Bei
    # einem externen Tool stattdessen prüfen, ob es installiert ist:
    #   return $this.HasTool(@("tesseract"))
    [bool] IsAvailable() {
        return $false
    }

    # TODO: Den erkannten Text zurückgeben.
    [string] ReadContent([System.IO.FileInfo]$file) {
        throw [System.NotImplementedException]::new("ImageOcrContentReader.ReadContent()")
    }
}

using module "../ContentReader.psm1"

#requires -Version 7.2


# =============================================================================
# READER FÜR RTF
# =============================================================================

# Liest den Text von Dateien im Rich Text Format mit einem eigenen Parser.
#
# RTF ist Text mit Steuerwörtern und Gruppen, z. B.
#   {\rtf1\ansi\ansicpg1252 {\fonttbl ...} {\b Fett} normal\par Gr\'f6\'dfe}
#   - { } öffnen und schließen eine Gruppe (die Formatierung wird am Ende
#     zurückgesetzt)
#   - \wort oder \wort123 ist ein Steuerwort mit optionaler Zahl
#   - \'f6 ist ein Byte in der Codepage des Dokuments (\ansicpg,
#     standardmäßig 1252)
#   - \u246? ist ein Unicode-Zeichen; die nächsten \ucN Zeichen (standardmäßig
#     1) sind ein Ersatz für alte Programme und werden übersprungen
#   - Gruppen wie {\fonttbl ...} oder {\*\irgendwas ...} enthalten keinen
#     sichtbaren Text ("Destinations") und werden komplett übersprungen
class RtfContentReader : ContentReader {

    # Destinations ohne sichtbaren Text.
    hidden static [System.Collections.Generic.HashSet[string]]$SkippedDestinations = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@(
            "fonttbl", "colortbl", "stylesheet", "info", "pict", "object",
            "listtable", "listoverridetable", "rsidtbl", "generator",
            "xmlnstbl", "themedata", "colorschememapping", "datastore",
            "latentstyles", "pgdsctbl", "revtbl", "fldinst", "filetbl",
            "header", "headerl", "headerr", "headerf",
            "footer", "footerl", "footerr", "footerf",
            "bkmkstart", "bkmkend", "nonshppict", "shpinst", "objdata"
        ),
        [System.StringComparer]::Ordinal
    )

    # Steuerwörter, die ein Zeichen erzeugen.
    hidden static [hashtable]$SymbolWords = @{
        "par" = "`n"; "line" = "`n"; "sect" = "`n"; "page" = "`n"; "row" = "`n"
        "tab" = "`t"; "cell" = "`t"
        "emdash" = [string][char]0x2014; "endash" = [string][char]0x2013
        "bullet" = [string][char]0x2022
        "lquote" = [string][char]0x2018; "rquote" = [string][char]0x2019
        "ldblquote" = [string][char]0x201C; "rdblquote" = [string][char]0x201D
        "emspace" = " "; "enspace" = " "; "qmspace" = " "
    }


    RtfContentReader() {
        $this.Description = "Rich Text Format"
        $this.Extensions = @(".rtf")
    }


    [string] ReadContent([System.IO.FileInfo]$file) {
        # Latin-1 behält jedes Byte als ein Zeichen; \'xx-Escapes werden später
        # mit der Codepage des Dokuments dekodiert.
        $rtf = [System.Text.Encoding]::Latin1.GetString(
            $this.ReadFileBytes($file)
        )

        if (-not $rtf.StartsWith("{\rtf")) {
            return ""
        }

        return [RtfContentReader]::ConvertRtfToText($rtf)
    }


    static [string] ConvertRtfToText([string]$rtf) {
        $builder = [System.Text.StringBuilder]::new($rtf.Length)
        $encoding = [System.Text.Encoding]::GetEncoding(1252)

        # Zustand pro Gruppe: Text überspringen? Zeichen, die nach \u
        # übersprungen werden.
        $skipStack = [System.Collections.Generic.Stack[bool]]::new()
        $unicodeSkipStack = [System.Collections.Generic.Stack[int]]::new()
        $skipping = $false
        $unicodeSkip = 1

        # Ersatzzeichen, die nach einem \u-Zeichen noch zu überspringen sind.
        $pendingSkip = 0

        $length = $rtf.Length
        $i = 0

        while ($i -lt $length) {
            $char = $rtf[$i]

            if ($char -eq "{") {
                $skipStack.Push($skipping)
                $unicodeSkipStack.Push($unicodeSkip)
                $pendingSkip = 0
                $i++

                # {\* ...} kennzeichnet eine Destination, die unbekannte
                # Programme ignorieren müssen.
                if ($i + 1 -lt $length -and $rtf[$i] -eq "\" -and $rtf[$i + 1] -eq "*") {
                    $skipping = $true
                    $i += 2
                }

                continue
            }

            if ($char -eq "}") {
                if ($skipStack.Count -gt 0) {
                    $skipping = $skipStack.Pop()
                    $unicodeSkip = $unicodeSkipStack.Pop()
                }

                $pendingSkip = 0
                $i++
                continue
            }

            if ($char -eq "`r" -or $char -eq "`n") {
                # Zeilenumbrüche im RTF-Quelltext gehören nicht zum Text.
                $i++
                continue
            }

            if ($char -ne "\") {
                if ($pendingSkip -gt 0) {
                    $pendingSkip--
                }
                elseif (-not $skipping) {
                    [void]$builder.Append($char)
                }

                $i++
                continue
            }

            # Backslash: Steuerwort, Steuersymbol oder maskiertes Zeichen.
            $i++

            if ($i -ge $length) {
                break
            }

            $next = $rtf[$i]

            if ([char]::IsLetter($next)) {
                $start = $i

                while ($i -lt $length -and [char]::IsLetter($rtf[$i])) {
                    $i++
                }

                $word = $rtf.Substring($start, $i - $start)

                $parameterStart = $i

                if ($i -lt $length -and $rtf[$i] -eq "-") {
                    $i++
                }

                while ($i -lt $length -and [char]::IsDigit($rtf[$i])) {
                    $i++
                }

                $parameterText = $rtf.Substring($parameterStart, $i - $parameterStart)
                $hasParameter = $parameterText.Length -gt 0 -and $parameterText -ne "-"
                $parameter = 0

                if ($hasParameter) {
                    [void][int]::TryParse($parameterText, [ref]$parameter)
                }

                # Ein Leerzeichen nach einem Steuerwort beendet nur das Wort.
                if ($i -lt $length -and $rtf[$i] -eq " ") {
                    $i++
                }

                if ([RtfContentReader]::SkippedDestinations.Contains($word)) {
                    $skipping = $true
                    continue
                }

                switch ($word) {
                    "ansicpg" {
                        try {
                            $encoding = [System.Text.Encoding]::GetEncoding($parameter)
                        }
                        catch {
                            # Unbekannte Codepage: die bisherige behalten.
                        }
                    }
                    "uc" {
                        $unicodeSkip = [Math]::Max(0, $parameter)
                    }
                    "u" {
                        if (-not $skipping) {
                            # Werte über 32767 werden als negative Zahlen
                            # geschrieben.
                            $codePoint = if ($parameter -lt 0) { $parameter + 65536 } else { $parameter }
                            [void]$builder.Append([char]$codePoint)
                        }

                        $pendingSkip = $unicodeSkip
                    }
                    "bin" {
                        # Es folgen Binärdaten der angegebenen Länge.
                        $i += [Math]::Max(0, $parameter)
                    }
                    default {
                        $symbol = [RtfContentReader]::SymbolWords[$word]

                        if ($null -ne $symbol -and -not $skipping) {
                            [void]$builder.Append($symbol)
                        }
                    }
                }

                continue
            }

            if ($next -eq "'") {
                # \'hh: ein Byte in der Codepage des Dokuments.
                if ($i + 2 -lt $length) {
                    $hex = $rtf.Substring($i + 1, 2)
                    $byteValue = 0

                    if ([int]::TryParse($hex, [System.Globalization.NumberStyles]::HexNumber, $null, [ref]$byteValue)) {
                        if ($pendingSkip -gt 0) {
                            $pendingSkip--
                        }
                        elseif (-not $skipping) {
                            [void]$builder.Append($encoding.GetString([byte[]]@($byteValue)))
                        }
                    }
                }

                $i += 3
                continue
            }

            # Steuersymbole.
            if (-not $skipping) {
                switch ($next) {
                    "\" { [void]$builder.Append("\") }
                    "{" { [void]$builder.Append("{") }
                    "}" { [void]$builder.Append("}") }
                    "~" { [void]$builder.Append([char]0x00A0) }
                    "_" { [void]$builder.Append("-") }
                    "`n" { [void]$builder.Append("`n") }
                    "`r" { [void]$builder.Append("`n") }
                    # "\-" weicher Trennstrich und andere: kein sichtbares
                    # Zeichen.
                }
            }

            $i++
        }

        # Dieselbe Bereinigung wie bei den anderen Readern: gekürzte Zeilen,
        # höchstens eine leere Zeile.
        $text = $builder.ToString().Replace([char]0x00A0, " ")
        $text = [regex]::Replace($text, "[ \t]*\n[ \t]*", "`n")
        $text = [regex]::Replace($text, "\n{3,}", "`n`n")

        return $text.Trim()
    }
}

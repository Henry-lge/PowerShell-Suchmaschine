using module "../ContentReader.psm1"
using module "../Shared/XmlText.psm1"
using module "../Shared/IWorkArchive.psm1"

#requires -Version 7.2


# =============================================================================
# READER FÜR APPLE IWORK (Pages, Numbers, Keynote)
# =============================================================================

# Liest den Text von iWork-Dokumenten mit einem eigenen Parser, ohne
# Apple-Software.
#
# Aktuelles Format (seit 2013): ZIP mit Index/*.iwa-Dateien, die
# Snappy-komprimierte Protobuf-Nachrichten enthalten (siehe
# Shared/IWorkArchive.psm1). Text steht in diesen Nachrichtentypen:
#   2001  TSWP.StorageArchive    Feld 3: Text eines Textflusses (Pages-Text,
#                                Keynote-Textfelder, Notizen, Textzellen)
#   6005  TST.TableDataList      Feld 1 = Listentyp (1 = Texte),
#                                Feld 3 = Einträge, jeweils mit dem Text
#                                in Feld 3 (Numbers-/Tabellenzellen)
#   6001  TST.TableModelArchive  Feld 8: Tabellenname
#   2     TN.SheetArchive        Feld 1: Blattname (nur Numbers; die
#                                niedrigen Typnummern unterscheiden sich
#                                zwischen den Apps)
# Zahlen in Zellen werden in einem binären Kachelformat gespeichert und
# nicht gelesen.
#
# Altes Format (iWork '09): ZIP mit index.xml (Pages, Numbers) oder
# index.apxl (Keynote), eventuell gzip-komprimiert; alle Textknoten werden
# verwendet.
#
# Als Paketordner gespeicherte Dokumente sind keine Dateien; der Crawler
# durchläuft sie wie normale Ordner. Andere Dateien mit diesen Endungen
# (z. B. Lizenzdateien ".key") sind keine ZIP-Archive und liefern keinen
# Text.
class IWorkContentReader : ContentReader {

    hidden static [int]$TextStorage = 2001
    hidden static [int]$TableDataList = 6005
    hidden static [int]$TableModel = 6001
    hidden static [int]$NumbersSheet = 2


    IWorkContentReader() {
        $this.Description = "Apple iWork (Pages, Numbers, Keynote)"
        $this.Extensions = @(".pages", ".numbers", ".key")
    }


    [string] ReadContent([System.IO.FileInfo]$file) {
        if (-not $this.IsZipFile($file)) {
            return ""
        }

        $zip = $this.OpenZip($file)

        try {
            $archiveNames = $this.FindZipEntries($zip, "Index/*.iwa")

            if ($archiveNames.Length -gt 0) {
                $isNumbers = $file.Extension -eq ".numbers"
                return $this._ReadArchives($zip, $archiveNames, $isNumbers)
            }

            return $this._ReadLegacyXml($zip)
        }
        finally {
            $zip.Dispose()
        }
    }


    hidden [string] _ReadArchives(
        [System.IO.Compression.ZipArchive]$zip,
        [string[]]$archiveNames,
        [bool]$isNumbers
    ) {
        $texts = [System.Collections.Generic.List[string]]::new()

        # Document.iwa enthält die Struktur (Blätter, Fließtext) und kommt
        # zuerst.
        $ordered = @($archiveNames | Sort-Object { $_ -ne "Index/Document.iwa" })

        foreach ($archiveName in $ordered) {
            $buffer = [IWorkArchive]::Decompress($this._ReadZipBytes($zip, $archiveName))

            foreach ($message in [IWorkArchive]::ReadMessages($buffer)) {
                $this._CollectText($buffer, $message, $isNumbers, $texts)
            }
        }

        return [XmlText]::CleanUp(($texts -join "`n"))
    }


    hidden [void] _CollectText(
        [byte[]]$buffer,
        [IWorkMessage]$message,
        [bool]$isNumbers,
        [System.Collections.Generic.List[string]]$texts
    ) {
        $type = $message.Type

        if (
            $type -ne [IWorkContentReader]::TextStorage -and
            $type -ne [IWorkContentReader]::TableDataList -and
            $type -ne [IWorkContentReader]::TableModel -and
            -not ($isNumbers -and $type -eq [IWorkContentReader]::NumbersSheet)
        ) {
            return
        }

        $fields = [ProtoReader]::ReadFields($buffer, $message.Offset, $message.Length)

        switch ($type) {
            ([IWorkContentReader]::TextStorage) {
                foreach ($field in $fields) {
                    if ($field.Number -eq 3 -and $field.WireType -eq 2) {
                        $texts.Add([IWorkContentReader]::CleanStorageText([ProtoReader]::GetString($buffer, $field)))
                    }
                }
            }
            ([IWorkContentReader]::TableDataList) {
                $listType = 0

                foreach ($field in $fields) {
                    if ($field.Number -eq 1) { $listType = [int]$field.Value }
                }

                # Nur Textlisten; andere enthalten Formate, Formeln, Stile.
                if ($listType -ne 1) {
                    return
                }

                foreach ($field in $fields) {
                    if ($field.Number -ne 3 -or $field.WireType -ne 2) {
                        continue
                    }

                    foreach ($entryField in [ProtoReader]::ReadFields($buffer, $field.Offset, $field.Length)) {
                        if ($entryField.Number -eq 3 -and $entryField.WireType -eq 2) {
                            $texts.Add([ProtoReader]::GetString($buffer, $entryField))
                        }
                    }
                }
            }
            ([IWorkContentReader]::TableModel) {
                $this._AddStringField($buffer, $fields, 8, $texts)
            }
            ([IWorkContentReader]::NumbersSheet) {
                $this._AddStringField($buffer, $fields, 1, $texts)
            }
        }
    }


    hidden [void] _AddStringField(
        [byte[]]$buffer,
        [ProtoField[]]$fields,
        [int]$number,
        [System.Collections.Generic.List[string]]$texts
    ) {
        foreach ($field in $fields) {
            if ($field.Number -eq $number -and $field.WireType -eq 2) {
                $texts.Add([ProtoReader]::GetString($buffer, $field))
            }
        }
    }


    # iWork kennzeichnet Absatzenden, Zeilenumbrüche und eingebettete Objekte
    # mit Sonderzeichen.
    static [string] CleanStorageText([string]$text) {
        return $text.Replace([string][char]0x2029, "`n").
            Replace([string][char]0x2028, "`n").
            Replace([string][char]0xFFFC, "").
            Replace([string][char]0x0004, "").
            Replace([string][char]0x0005, "")
    }


    hidden [byte[]] _ReadZipBytes([System.IO.Compression.ZipArchive]$zip, [string]$entryName) {
        $stream = $zip.GetEntry($entryName).Open()
        $memory = [System.IO.MemoryStream]::new()

        try {
            $stream.CopyTo($memory)
        }
        finally {
            $stream.Dispose()
        }

        return $memory.ToArray()
    }


    # iWork '09: XML, eventuell gzip-komprimiert.
    hidden [string] _ReadLegacyXml([System.IO.Compression.ZipArchive]$zip) {
        foreach ($name in @("index.xml", "index.apxl", "index.xml.gz", "index.apxl.gz")) {
            $entry = $zip.GetEntry($name)

            if ($null -eq $entry) {
                continue
            }

            $stream = $entry.Open()

            if ($name.EndsWith(".gz")) {
                $stream = [System.IO.Compression.GZipStream]::new($stream, [System.IO.Compression.CompressionMode]::Decompress)
            }

            $settings = [System.Xml.XmlReaderSettings]::new()
            $settings.DtdProcessing = [System.Xml.DtdProcessing]::Ignore
            $settings.CloseInput = $true
            $reader = [System.Xml.XmlReader]::Create($stream, $settings)

            try {
                $rules = [XmlTextRules]::new()
                $rules.ParagraphElements = @("p")
                $rules.BreakElements = @("br", "lnbr")
                $rules.TabElements = @("tab")

                return [XmlText]::Extract($reader, $rules)
            }
            finally {
                $reader.Dispose()
            }
        }

        return ""
    }
}

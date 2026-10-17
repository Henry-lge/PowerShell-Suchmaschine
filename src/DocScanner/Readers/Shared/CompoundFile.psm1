#requires -Version 7.2


# =============================================================================
# READER FÜR OLE-VERBUNDDATEIEN
# =============================================================================

# Liest das "Compound File Binary Format" (MS-CFB), ein kleines Dateisystem
# innerhalb einer Datei. Wird von Outlook-.msg und von Office-Dokumenten
# 97-2003 (.doc, .xls, .ppt) verwendet.
#
# Aufbau:
#   - 512 Byte Kopf, dann Sektoren mit 512 (Version 3) oder 4096 Bytes (v4)
#   - FAT: der nächste Sektor jedes Sektors, ein Stream ist also eine Kette
#     von Sektoren
#   - Verzeichnis: Einträge mit 128 Bytes (Storages = Ordner, Streams =
#     Dateien), die pro Storage über linke/rechte Geschwister- und
#     Kind-Verweise einen Baum bilden
#   - Streams unter 4096 Bytes liegen im "Mini-Stream" mit 64-Byte-Sektoren
#     und einer eigenen Mini-FAT
#
# Sektornummern werden als vorzeichenbehaftete Ganzzahlen gelesen:
# -2 = Ende der Kette, -1 = frei / kein Eintrag.


# Ein Verzeichniseintrag.
class CompoundFileEntry {
    [int]$Id
    [string]$Name

    # 1 = Storage, 2 = Stream, 5 = Wurzel
    [int]$Type

    [int]$LeftSibling
    [int]$RightSibling
    [int]$Child
    [int]$StartSector
    [long]$Size

    [bool] IsStorage() {
        return $this.Type -eq 1 -or $this.Type -eq 5
    }

    [bool] IsStream() {
        return $this.Type -eq 2
    }
}


class CompoundFile {

    hidden static [byte[]]$Signature = [byte[]](0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1)
    hidden static [int]$EndOfChain = -2
    hidden static [int]$NoEntry = -1

    [CompoundFileEntry[]]$Entries

    hidden [byte[]]$_data
    hidden [int]$_sectorSize
    hidden [int]$_miniSectorSize
    hidden [long]$_miniStreamCutoff
    hidden [int[]]$_fat
    hidden [int[]]$_miniFat
    hidden [byte[]]$_miniStream


    # True, wenn die Bytes mit der Signatur einer Verbunddatei beginnen.
    # Damit lassen sich echte Outlook-.msg-Dateien von anderen Dateien mit
    # derselben Endung unterscheiden.
    static [bool] IsCompoundFile([byte[]]$data) {
        if ($null -eq $data -or $data.Length -lt 512) {
            return $false
        }

        for ($i = 0; $i -lt 8; $i++) {
            if ($data[$i] -ne [CompoundFile]::Signature[$i]) {
                return $false
            }
        }

        return $true
    }


    CompoundFile([byte[]]$data) {
        if (-not [CompoundFile]::IsCompoundFile($data)) {
            throw "Not an OLE compound file."
        }

        $this._data = $data
        $this._sectorSize = 1 -shl [System.BitConverter]::ToUInt16($data, 0x1E)
        $this._miniSectorSize = 1 -shl [System.BitConverter]::ToUInt16($data, 0x20)
        $this._miniStreamCutoff = [System.BitConverter]::ToUInt32($data, 0x38)

        $this._fat = $this._ReadFat()

        $directoryBytes = $this._ReadChain([System.BitConverter]::ToInt32($data, 0x30), -1)
        $majorVersion = [System.BitConverter]::ToUInt16($data, 0x1A)
        $this.Entries = $this._ParseDirectory($directoryBytes, $majorVersion)

        # Der Wurzeleintrag verweist auf den Mini-Stream in normalen Sektoren.
        $root = $this.GetRoot()
        $this._miniStream = $this._ReadChain($root.StartSector, $root.Size)

        $firstMiniFatSector = [System.BitConverter]::ToInt32($data, 0x3C)
        $this._miniFat = [CompoundFile]::ToIntArray(
            $this._ReadChain($firstMiniFatSector, -1)
        )
    }


    # =============================================================================
    # ÖFFENTLICHER ZUGRIFF
    # =============================================================================

    [CompoundFileEntry] GetRoot() {
        return $this.Entries[0]
    }


    # Direkte Kinder eines Storages (nicht rekursiv).
    [CompoundFileEntry[]] GetChildren([CompoundFileEntry]$storage) {
        $children = [System.Collections.Generic.List[CompoundFileEntry]]::new()
        $visited = [System.Collections.Generic.HashSet[int]]::new()
        $pending = [System.Collections.Generic.Stack[int]]::new()
        $pending.Push($storage.Child)

        # Die Kinder bilden einen Binärbaum; jeden Knoten einmal besuchen.
        while ($pending.Count -gt 0) {
            $id = $pending.Pop()

            if ($id -lt 0 -or $id -ge $this.Entries.Length -or -not $visited.Add($id)) {
                continue
            }

            $entry = $this.Entries[$id]
            $children.Add($entry)
            $pending.Push($entry.LeftSibling)
            $pending.Push($entry.RightSibling)
        }

        return $children.ToArray()
    }


    # Kind mit dem angegebenen Namen (ohne Beachtung der Groß-/
    # Kleinschreibung) oder $null.
    [CompoundFileEntry] FindChild([CompoundFileEntry]$storage, [string]$name) {
        foreach ($child in $this.GetChildren($storage)) {
            if ([string]::Equals($child.Name, $name, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $child
            }
        }

        return $null
    }


    [byte[]] ReadStream([CompoundFileEntry]$entry) {
        if ($entry.Size -lt $this._miniStreamCutoff) {
            return $this._ReadMiniChain($entry.StartSector, $entry.Size)
        }

        return $this._ReadChain($entry.StartSector, $entry.Size)
    }


    # =============================================================================
    # INTERNES
    # =============================================================================

    hidden [int[]] _ReadFat() {
        $fatSectors = [System.Collections.Generic.List[int]]::new()

        # Der Kopf listet die ersten 109 FAT-Sektoren.
        for ($i = 0; $i -lt 109; $i++) {
            $sector = [System.BitConverter]::ToInt32($this._data, 0x4C + $i * 4)

            if ($sector -ge 0) {
                $fatSectors.Add($sector)
            }
        }

        # Größere Dateien setzen die Liste in DIFAT-Sektoren fort. Der letzte
        # Eintrag jedes DIFAT-Sektors verweist auf den nächsten.
        $difatSector = [System.BitConverter]::ToInt32($this._data, 0x44)
        $entriesPerSector = $this._sectorSize / 4
        $guard = 0

        while ($difatSector -ge 0 -and $guard -lt 100000) {
            $offset = $this._SectorOffset($difatSector)

            for ($i = 0; $i -lt $entriesPerSector - 1; $i++) {
                $sector = [System.BitConverter]::ToInt32($this._data, $offset + $i * 4)

                if ($sector -ge 0) {
                    $fatSectors.Add($sector)
                }
            }

            $difatSector = [System.BitConverter]::ToInt32(
                $this._data,
                $offset + ($entriesPerSector - 1) * 4
            )
            $guard++
        }

        $fat = [System.Collections.Generic.List[int]]::new()

        foreach ($sector in $fatSectors) {
            $offset = $this._SectorOffset($sector)

            for ($i = 0; $i -lt $entriesPerSector; $i++) {
                $fat.Add([System.BitConverter]::ToInt32($this._data, $offset + $i * 4))
            }
        }

        return $fat.ToArray()
    }


    hidden [long] _SectorOffset([int]$sector) {
        $offset = ([long]$sector + 1) * $this._sectorSize

        if ($offset + $this._sectorSize -gt $this._data.Length) {
            throw "Compound file is truncated or damaged (sector $sector)."
        }

        return $offset
    }


    # Hängt eine Sektorkette aneinander. Bei $size -lt 0 wird die ganze
    # Kette gelesen.
    hidden [byte[]] _ReadChain([int]$startSector, [long]$size) {
        $buffer = [System.IO.MemoryStream]::new()
        $sector = $startSector
        $guard = 0

        while ($sector -ge 0 -and $guard -le $this._fat.Length) {
            $buffer.Write($this._data, $this._SectorOffset($sector), $this._sectorSize)
            $sector = $this._fat[$sector]
            $guard++
        }

        return [CompoundFile]::Truncate($buffer.ToArray(), $size)
    }


    hidden [byte[]] _ReadMiniChain([int]$startSector, [long]$size) {
        $buffer = [System.IO.MemoryStream]::new()
        $sector = $startSector
        $guard = 0

        while ($sector -ge 0 -and $guard -le $this._miniFat.Length) {
            $offset = [long]$sector * $this._miniSectorSize

            if ($offset + $this._miniSectorSize -gt $this._miniStream.Length) {
                throw "Compound file mini stream is damaged (sector $sector)."
            }

            $buffer.Write($this._miniStream, $offset, $this._miniSectorSize)
            $sector = $this._miniFat[$sector]
            $guard++
        }

        return [CompoundFile]::Truncate($buffer.ToArray(), $size)
    }


    hidden [CompoundFileEntry[]] _ParseDirectory([byte[]]$bytes, [int]$majorVersion) {
        $parsed = [System.Collections.Generic.List[CompoundFileEntry]]::new()

        for ($offset = 0; $offset + 128 -le $bytes.Length; $offset += 128) {
            $entry = [CompoundFileEntry]::new()
            $entry.Id = $parsed.Count

            # Name: UTF-16, Länge in Bytes einschließlich der abschließenden
            # Null.
            $nameLength = [System.BitConverter]::ToUInt16($bytes, $offset + 0x40)

            if ($nameLength -ge 2 -and $nameLength -le 64) {
                $entry.Name = [System.Text.Encoding]::Unicode.GetString($bytes, $offset, $nameLength - 2)
            }
            else {
                $entry.Name = ""
            }

            $entry.Type = $bytes[$offset + 0x42]
            $entry.LeftSibling = [System.BitConverter]::ToInt32($bytes, $offset + 0x44)
            $entry.RightSibling = [System.BitConverter]::ToInt32($bytes, $offset + 0x48)
            $entry.Child = [System.BitConverter]::ToInt32($bytes, $offset + 0x4C)
            $entry.StartSector = [System.BitConverter]::ToInt32($bytes, $offset + 0x74)

            # Dateien der Version 3 verwenden nur die unteren 32 Bits der
            # Größe.
            if ($majorVersion -eq 3) {
                $entry.Size = [System.BitConverter]::ToUInt32($bytes, $offset + 0x78)
            }
            else {
                $entry.Size = [System.BitConverter]::ToInt64($bytes, $offset + 0x78)
            }

            $parsed.Add($entry)
        }

        if ($parsed.Count -eq 0 -or $parsed[0].Type -ne 5) {
            throw "Compound file has no root entry."
        }

        return $parsed.ToArray()
    }


    hidden static [byte[]] Truncate([byte[]]$bytes, [long]$size) {
        if ($size -lt 0 -or $size -ge $bytes.Length) {
            return $bytes
        }

        $result = [byte[]]::new($size)
        [System.Array]::Copy($bytes, $result, $size)

        return $result
    }


    hidden static [int[]] ToIntArray([byte[]]$bytes) {
        $values = [int[]]::new([Math]::Floor($bytes.Length / 4))

        for ($i = 0; $i -lt $values.Length; $i++) {
            $values[$i] = [System.BitConverter]::ToInt32($bytes, $i * 4)
        }

        return $values
    }
}

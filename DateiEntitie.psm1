class Datei {
    [String]$Name
    [String]$Path
    [String]$Extension
    [Int64]$Size
    [DateTime]$CreationTime
    [DateTime]$LastWriteTime
    [DateTime]$LastAccessTime

    [String]$Hash
    [String]$Content

    [string[]] print() {
        $output = @(
            "Name: $($this.Name)"
            "Path: $($this.Path)"
            "Extension: $($this.Extension)"
            "Size: $($this.Size) bytes"
            "Creation Time: $($this.CreationTime)"
            "Last Write Time: $($this.LastWriteTime)"
            "Last Access Time: $($this.LastAccessTime)"
        )

        if (-not [string]::IsNullOrEmpty($this.Hash)) {
            $output += "Hash (SHA256): $($this.Hash)"
        }

        if (-not [string]::IsNullOrEmpty($this.Content)) {
            $contentLength = $this.Content.Length
            $output += "Content: $contentLength characters"
        }

        $output += ""
        return $output
    }


    [System.Collections.Hashtable] ToHashtable() {
        return @{
            Name = $this.Name
            Path = $this.Path
            Extension = $this.Extension
            Size = $this.Size
            CreationTime = $this.CreationTime
            LastWriteTime = $this.LastWriteTime
            LastAccessTime = $this.LastAccessTime
            Hash = $this.Hash
            Content = $this.Content
        }
    }

   
    [PSCustomObject] ToObject() {
        return [PSCustomObject]@{
            Name = $this.Name
            Path = $this.Path
            Extension = $this.Extension
            Size = $this.Size
            CreationTime = $this.CreationTime
            LastWriteTime = $this.LastWriteTime
            LastAccessTime = $this.LastAccessTime
            Hash = $this.Hash
            Content = $this.Content
        }
    }
}

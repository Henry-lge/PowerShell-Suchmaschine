class Datei {
    # Basic file metadata.
    [String]$Name
    [String]$Path
    [String]$Extension
    [Int64]$Size
    [DateTime]$CreationTime
    [DateTime]$LastWriteTime
    [DateTime]$LastAccessTime

    # Optional hash and content.
    [String]$Hash
    [String]$Content

    # Return readable file information.
    [string[]] print() {
        return @(
            "Name: $($this.Name)"
            "Path: $($this.Path)"
            "Extension: $($this.Extension)"
            "Size: $($this.Size) bytes"
            "Creation Time: $($this.CreationTime)"
            "Last Write Time: $($this.LastWriteTime)"
            "Last Access Time: $($this.LastAccessTime)"
            "Hash (SHA256): $($this.Hash)"
            ""
        )
    }
}
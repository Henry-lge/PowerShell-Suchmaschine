function Write-HostCenter
{
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ConsoleColor]$ForegroundColor
    )

    $width = $Host.UI.RawUI.BufferSize.Width
    $padding = [Math]::Max(0,[Math]::Floor(($width / 2) - ($Message.Length / 2)))
    $paddedMessage = (' ' * $padding) + $Message

    if ( $PSBoundParameters.ContainsKey('ForegroundColor'))
    {
        Write-Host $paddedMessage -ForegroundColor $ForegroundColor
    }
    else
    {
        Write-Host $paddedMessage
    }
}
function Write-Seperator ($char = "=") {
    $width = $Host.UI.RawUI.WindowSize.Width
    $char * $width
}


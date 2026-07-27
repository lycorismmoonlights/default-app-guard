[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateRange(1024, 65535)]
    [int]$Port,
    [Parameter(Mandatory)]
    [string]$ReadyFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$listener = [Net.Sockets.TcpListener]::new(
    [Net.IPAddress]::Loopback,
    $Port)
try {
    $listener.Start()
    "ready" | Set-Content -LiteralPath $ReadyFile -Encoding Ascii
    while ($true) {
        Start-Sleep -Seconds 1
    }
} finally {
    $listener.Stop()
}

[CmdletBinding()]
param(
    [string]$AgentUrl = "http://127.0.0.1:51873",
    [ValidateRange(2, 30)]
    [int]$TimeoutSeconds = 10,
    [switch]$AllowAssociationDrift,
    [Parameter(Mandatory)]
    [string]$WorkRoot,
    [Parameter(Mandatory)]
    [string]$EvidencePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$workPath = [IO.Path]::GetFullPath($WorkRoot)
$evidenceFile = [IO.Path]::GetFullPath($EvidencePath)
if (Test-Path -LiteralPath $workPath) {
    throw "Monitor probe work directory already exists: $workPath"
}
if (Test-Path -LiteralPath $evidenceFile) {
    throw "Refusing to overwrite existing monitor evidence: $evidenceFile"
}
New-Item -ItemType Directory -Path $workPath | Out-Null
$inputPath = Join-Path $workPath "input.json"
$resultPath = Join-Path $workPath "result.json"
$wrapperPath = Join-Path $workPath "probe.ps1"
@{
    scriptPath = Join-Path $PSScriptRoot "Test-InstalledMonitor.ps1"
    agentUrl = $AgentUrl
    timeoutSeconds = $TimeoutSeconds
    allowAssociationDrift = [bool]$AllowAssociationDrift
} | ConvertTo-Json | Set-Content -LiteralPath $inputPath -Encoding UTF8
@'
param([string]$InputPath, [string]$ResultPath)
$ErrorActionPreference = "Stop"
try {
    $inputData = Get-Content -LiteralPath $InputPath -Raw | ConvertFrom-Json
    $result = & $inputData.scriptPath -AgentUrl $inputData.agentUrl `
        -TimeoutSeconds $inputData.timeoutSeconds `
        -AllowAssociationDrift:([bool]$inputData.allowAssociationDrift)
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
    exit 0
} catch {
    @{ InstalledMonitorVerified = $false; Error = $_.Exception.Message } |
        ConvertTo-Json | Set-Content -LiteralPath $ResultPath -Encoding UTF8
    exit 1
}
'@ | Set-Content -LiteralPath $wrapperPath -Encoding UTF8

$taskName = "DefaultAppGuard Monitor Probe " + [Guid]::NewGuid().ToString("N")
$action = New-ScheduledTaskAction -Execute (
    Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe") `
    -Argument ("-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden " +
        "-File `"$wrapperPath`" -InputPath `"$inputPath`" -ResultPath `"$resultPath`"")
$principal = New-ScheduledTaskPrincipal `
    -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
    -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -Hidden `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 1) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$registered = $false
try {
    Register-ScheduledTask -TaskName $taskName -Action $action `
        -Principal $principal -Settings $settings | Out-Null
    $registered = $true
    Start-ScheduledTask -TaskName $taskName
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds * 2 + 15)
    do {
        Start-Sleep -Milliseconds 250
        $task = Get-ScheduledTask -TaskName $taskName
        $info = Get-ScheduledTaskInfo -TaskName $taskName
        $finished = (Test-Path -LiteralPath $resultPath) -and
            $task.State -ne "Running"
    } until ($finished -or [DateTime]::UtcNow -ge $deadline)
    if (-not $finished) {
        throw "Interactive task monitor probe timed out."
    }
    $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    if ($info.LastTaskResult -ne 0 -or -not $result.InstalledMonitorVerified) {
        $detail = if ($null -ne $result.PSObject.Properties["Error"]) {
            [string]$result.Error
        } else { "Task exit code: $($info.LastTaskResult)" }
        throw "Interactive task monitor probe failed: $detail"
    }
    $result | Add-Member -NotePropertyName VerificationContext `
        -NotePropertyValue "interactive-scheduled-task"
    New-Item -ItemType Directory -Path (Split-Path -Parent $evidenceFile) `
        -Force | Out-Null
    $result | ConvertTo-Json -Depth 6 | Set-Content `
        -LiteralPath $evidenceFile -Encoding UTF8
    $result
} finally {
    if ($registered) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
}

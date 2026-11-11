param(
    [Parameter(Mandatory=$true)][string]$BinaryUrl,
    [Parameter(Mandatory=$true)][string]$Sha256,
    [switch]$InstallStartupTask
)
$ErrorActionPreference = 'Stop'
$Root = Join-Path $env:LOCALAPPDATA 'FarPilot'
$Bin = Join-Path $Root 'bin'
$Target = Join-Path $Bin 'farpilot.exe'
$Temp = Join-Path $env:TEMP ("farpilot-" + [guid]::NewGuid() + '.exe')
New-Item -ItemType Directory -Force -Path $Bin | Out-Null
try {
    Invoke-WebRequest -UseBasicParsing -Uri $BinaryUrl -OutFile $Temp
    $Actual = (Get-FileHash -Algorithm SHA256 $Temp).Hash
    if ($Actual -ne $Sha256.ToUpperInvariant()) { throw 'FarPilot SHA256 mismatch' }
    $Signature = Get-AuthenticodeSignature $Temp
    if ($Signature.Status -ne 'Valid') { throw "FarPilot Authenticode signature is $($Signature.Status)" }
    Move-Item -Force $Temp $Target
} finally {
    Remove-Item -Force -ErrorAction SilentlyContinue $Temp
}
if ($InstallStartupTask) {
    $Action = New-ScheduledTaskAction -Execute $Target -Argument 'host start'
    $Trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $Principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName 'FarPilot Host' -Action $Action -Trigger $Trigger -Principal $Principal -Force | Out-Null
}
Write-Host "Installed $Target"
Write-Host 'FarPilot opens no inbound port and creates no firewall rule.'

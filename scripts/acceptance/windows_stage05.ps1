[CmdletBinding()]
param(
    [switch]$SkipStart,
    [switch]$CreatePairing
)

$ErrorActionPreference = 'Stop'
$ArtifactRunId = '43676588975'
$ArtifactName = 'farpilot-windows-x86_64-fd71c316e08f50a8e0f1e5fbf3a15d4238792b41'
$ExpectedBinarySha256 = '4BCAC3FD7D3E56D214190A02EA1ACDC67B8C68F72E815A43D3D76B0387A72698'
$ExpectedInstallerSha256 = 'BAEC1685079407957D23C3235DF5001B071F2C0A7C79A70112E8CA867A247070'
$SourceCommit = 'stage05/live-acceptance'
$Root = Join-Path $env:LOCALAPPDATA 'FarPilot'
$Executable = Join-Path $Root 'bin\farpilot.exe'
$TaskName = 'FarPilot Host'
$TemporaryRoot = $null

function Assert-FileHash {
    param([string]$Path, [string]$Expected, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label is missing"
    }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
    if ($actual -cne $Expected) {
        throw "$Label SHA-256 mismatch"
    }
}

function Repair-FarPilotInstall {
    $script:TemporaryRoot = Join-Path $env:TEMP ("FarPilot-stage05-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:TemporaryRoot | Out-Null

    $package = $Executable
    if (-not (Test-Path -LiteralPath $package -PathType Leaf)) {
        if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
            throw 'GitHub CLI is required to recover the pinned CI artifact'
        }
        gh auth status *> $null
        if ($LASTEXITCODE -ne 0) {
            throw 'GitHub CLI must be authenticated before recovery'
        }
        gh run download $ArtifactRunId `
            --repo Polly2014/FarPilot `
            --name $ArtifactName `
            --dir $script:TemporaryRoot
        if ($LASTEXITCODE -ne 0) { throw 'CI artifact download failed' }
        $package = Join-Path $script:TemporaryRoot 'farpilot.exe'
    }
    Assert-FileHash -Path $package -Expected $ExpectedBinarySha256 -Label 'FarPilot package'

    $installer = Join-Path $script:TemporaryRoot 'install.ps1'
    Invoke-WebRequest `
        -Uri "https://raw.githubusercontent.com/Polly2014/FarPilot/$SourceCommit/deploy/windows/install.ps1" `
        -OutFile $installer
    Assert-FileHash -Path $installer -Expected $ExpectedInstallerSha256 -Label 'FarPilot installer'

    & pwsh `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $installer `
        -LocalPackagePath $package `
        -LocalPackageVersion '0.1.0' `
        -LocalPackageSha256 $ExpectedBinarySha256
    if ($LASTEXITCODE -ne 0) { throw 'FarPilot recovery installer failed' }
}

try {
    Repair-FarPilotInstall
    Assert-FileHash -Path $Executable -Expected $ExpectedBinarySha256 -Label 'Installed FarPilot'
    $version = (& $Executable --version).Trim()
    if ($version -cne 'farpilot 0.1.0') { throw "Unexpected FarPilot version: $version" }

    $identityPresent = Test-Path -LiteralPath (Join-Path $Root 'host-identity.json') -PathType Leaf
    $configPath = Join-Path $Root 'host.json'
    $configPresent = Test-Path -LiteralPath $configPath -PathType Leaf
    if (-not ($identityPresent -and $configPresent)) {
        throw 'Preserved Host identity or configuration is missing'
    }

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -eq $task) { throw 'FarPilot Host scheduled task is missing' }
    if (-not $SkipStart -and $task.State -ne 'Running') {
        Start-ScheduledTask -TaskName $TaskName
        Start-Sleep -Seconds 5
        $task = Get-ScheduledTask -TaskName $TaskName
    }

    $managedProcesses = @(
        Get-CimInstance Win32_Process -Filter "Name='farpilot.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase) }
    )
    $gatewayReady = $false
    try {
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        $gateway = [uri]$config.gateway_https
        $readyUri = [uri]::new($gateway, '/health/ready')
        $response = Invoke-RestMethod -Uri $readyUri -Method Get -TimeoutSec 10
        $gatewayReady = ([string]$response.status -ceq 'ok')
    } catch {
        $gatewayReady = $false
    }

    [PSCustomObject]@{
        version = $version
        binary_verified = $true
        identity_present = $identityPresent
        config_present = $configPresent
        task_exists = ($null -ne $task)
        task_state = [string]$task.State
        managed_processes = $managedProcesses.Count
        gateway_ready = $gatewayReady
    } | ConvertTo-Json -Compress

    if ($CreatePairing) {
        Write-Host 'PAIRING_OUTPUT_IS_SENSITIVE_DO_NOT_SHARE'
        & $Executable host pair
    }
} finally {
    if ($TemporaryRoot -and (Test-Path -LiteralPath $TemporaryRoot)) {
        Remove-Item -LiteralPath $TemporaryRoot -Recurse -Force
    }
}

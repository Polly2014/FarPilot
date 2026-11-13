Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Installer = Join-Path $PSScriptRoot 'install.ps1'
$OriginalLocalAppData = $env:LOCALAPPDATA
$OriginalUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$PowerShellExe = (Get-Process -Id $PID).Path
$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('farpilot-installer-test-' + [guid]::NewGuid().ToString('N'))

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "$Message`nExpected: $Expected`nActual:   $Actual"
    }
}

function Assert-FileBytesEqual {
    param([string]$ExpectedPath, [string]$ActualPath, [string]$Message)
    $expected = (Get-FileHash -Algorithm SHA256 -LiteralPath $ExpectedPath).Hash
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $ActualPath).Hash
    Assert-Equal $expected $actual $Message
}

function New-FarPilotFixture {
    param([string]$Version, [string]$Destination)
    $source = [IO.Path]::ChangeExtension($Destination, '.rs')
    $escaped = $Version.Replace('\', '\\').Replace('"', '\"')
    @"
fn main() {
    if std::env::args().nth(1).as_deref() == Some("--version") {
        println!("farpilot $escaped");
    } else {
        println!("fixture $escaped");
    }
}
"@ | Set-Content -LiteralPath $source -Encoding UTF8
    $compilerOutput = & rustc --crate-name farpilot_installer_fixture $source -O -o $Destination 2>&1
    if ($LASTEXITCODE -ne 0) {
        $detail = ($compilerOutput | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        throw "rustc failed for FarPilot fixture $Version`: $detail"
    }
    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        throw "rustc reported success but FarPilot fixture $Version was not created at $Destination"
    }
    Remove-Item -LiteralPath $source -Force
}

function Invoke-InstallerProcess {
    param(
        [string]$LocalAppData,
        [string]$PackagePath,
        [string]$Version,
        [string]$Sha256,
        [switch]$DryRun
    )
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $Installer,
        '-LocalPackagePath', $PackagePath,
        '-LocalPackageVersion', $Version,
        '-LocalPackageSha256', $Sha256,
        '-NoStartupTask',
        '-SkipPathMutation'
    )
    if ($DryRun) { $arguments += '-DryRun' }
    $previous = $env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA = $LocalAppData
        $output = & $PowerShellExe @arguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    } finally {
        $env:LOCALAPPDATA = $previous
    }
    return [PSCustomObject]@{ ExitCode = $exitCode; Output = $output }
}

function Get-JunctionTarget {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    Assert-True (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) "$Path is not a reparse point"
    $target = [string]$item.Target
    if ([string]::IsNullOrWhiteSpace($target)) { throw "$Path has no junction target" }
    return [IO.Path]::GetFullPath($target).TrimEnd('\')
}

function New-ScenarioRoot {
    param([string]$Name)
    $path = Join-Path $TempRoot $Name
    New-Item -ItemType Directory -Force -Path $path | Out-Null
    return $path
}

function Install-Fixture {
    param([string]$Scenario, [string]$Package, [string]$Version)
    $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $Package).Hash.ToLowerInvariant()
    $result = Invoke-InstallerProcess -LocalAppData $Scenario -PackagePath $Package -Version $Version -Sha256 $sha
    if ($result.ExitCode -ne 0) { throw "installer failed for $Version`: $($result.Output)" }
    return $result
}

New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null
try {
    $fixtures = Join-Path $TempRoot 'fixtures'
    New-Item -ItemType Directory -Force -Path $fixtures | Out-Null
    $versions = @('0.2.0', '0.2.1', '0.2.2', '0.2.3')
    $packages = @{}
    foreach ($version in $versions) {
        $path = Join-Path $fixtures "farpilot-$version.exe"
        New-FarPilotFixture -Version $version -Destination $path
        $packages[$version] = $path
    }

    # Fresh install creates a versioned release and managed junctions.
    $fresh = New-ScenarioRoot 'fresh'
    $pathBefore = [Environment]::GetEnvironmentVariable('Path', 'User')
    Install-Fixture -Scenario $fresh -Package $packages['0.2.0'] -Version '0.2.0' | Out-Null
    $root = Join-Path $fresh 'FarPilot'
    $releaseDir = Join-Path $root 'releases\0.2.0-x86_64-pc-windows-msvc'
    $releaseExe = Join-Path $releaseDir 'farpilot.exe'
    Assert-True (Test-Path -LiteralPath $releaseExe -PathType Leaf) 'versioned release executable was not installed'
    Assert-Equal ([IO.Path]::GetFullPath($releaseDir).TrimEnd('\')) (Get-JunctionTarget (Join-Path $root 'current')) 'current junction target is wrong'
    Assert-Equal ([IO.Path]::GetFullPath($releaseDir).TrimEnd('\')) (Get-JunctionTarget (Join-Path $root 'bin')) 'bin junction target is wrong'
    Assert-Equal $pathBefore ([Environment]::GetEnvironmentVariable('Path', 'User')) 'SkipPathMutation changed the real user PATH'

    # Same release is idempotent and does not replace the executable.
    $beforeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $releaseExe).Hash
    $beforeWrite = (Get-Item -LiteralPath $releaseExe).LastWriteTimeUtc
    Install-Fixture -Scenario $fresh -Package $packages['0.2.0'] -Version '0.2.0' | Out-Null
    Assert-Equal $beforeHash (Get-FileHash -Algorithm SHA256 -LiteralPath $releaseExe).Hash 'same-version reinstall changed bytes'
    Assert-Equal $beforeWrite (Get-Item -LiteralPath $releaseExe).LastWriteTimeUtc 'same-version reinstall replaced the executable'

    # Checksum mismatch and binary-version mismatch cannot move current.
    $currentBefore = Get-JunctionTarget (Join-Path $root 'current')
    $badChecksum = Invoke-InstallerProcess -LocalAppData $fresh -PackagePath $packages['0.2.1'] -Version '0.2.1' -Sha256 ('0' * 64)
    Assert-True ($badChecksum.ExitCode -ne 0) 'checksum mismatch unexpectedly succeeded'
    Assert-Equal $currentBefore (Get-JunctionTarget (Join-Path $root 'current')) 'checksum mismatch changed current'
    $wrongVersionSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $packages['0.2.0']).Hash.ToLowerInvariant()
    $wrongVersion = Invoke-InstallerProcess -LocalAppData $fresh -PackagePath $packages['0.2.0'] -Version '0.2.1' -Sha256 $wrongVersionSha
    Assert-True ($wrongVersion.ExitCode -ne 0) 'binary version mismatch unexpectedly succeeded'
    Assert-Equal $currentBefore (Get-JunctionTarget (Join-Path $root 'current')) 'version mismatch changed current'

    # Legacy managed binary migrates without touching identity or config.
    $legacy = New-ScenarioRoot 'legacy'
    $legacyRoot = Join-Path $legacy 'FarPilot'
    $legacyBin = Join-Path $legacyRoot 'bin'
    New-Item -ItemType Directory -Force -Path $legacyBin | Out-Null
    Copy-Item -LiteralPath $packages['0.2.0'] -Destination (Join-Path $legacyBin 'farpilot.exe')
    'identity-sentinel' | Set-Content -LiteralPath (Join-Path $legacyRoot 'host-identity.json')
    'config-sentinel' | Set-Content -LiteralPath (Join-Path $legacyRoot 'host-config.json')
    Install-Fixture -Scenario $legacy -Package $packages['0.2.1'] -Version '0.2.1' | Out-Null
    Assert-Equal 'identity-sentinel' (Get-Content -LiteralPath (Join-Path $legacyRoot 'host-identity.json') -Raw).Trim() 'identity changed during migration'
    Assert-Equal 'config-sentinel' (Get-Content -LiteralPath (Join-Path $legacyRoot 'host-config.json') -Raw).Trim() 'config changed during migration'
    Assert-True (((Get-Item -LiteralPath $legacyBin -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) 'legacy bin was not converted to a managed junction'

    # Unmanaged nonempty bin directories are refused and preserved.
    $unmanaged = New-ScenarioRoot 'unmanaged'
    $unmanagedBin = Join-Path $unmanaged 'FarPilot\bin'
    New-Item -ItemType Directory -Force -Path $unmanagedBin | Out-Null
    'keep-me' | Set-Content -LiteralPath (Join-Path $unmanagedBin 'user.txt')
    $unmanagedResult = Invoke-InstallerProcess -LocalAppData $unmanaged -PackagePath $packages['0.2.0'] -Version '0.2.0' -Sha256 (Get-FileHash -Algorithm SHA256 $packages['0.2.0']).Hash
    Assert-True ($unmanagedResult.ExitCode -ne 0) 'unmanaged nonempty bin unexpectedly succeeded'
    Assert-Equal 'keep-me' (Get-Content -LiteralPath (Join-Path $unmanagedBin 'user.txt') -Raw).Trim() 'unmanaged file was modified'

    # Junctions outside the managed releases root are refused.
    $outside = New-ScenarioRoot 'outside'
    $outsideTarget = Join-Path $outside 'external-target'
    $outsideBin = Join-Path $outside 'FarPilot\bin'
    New-Item -ItemType Directory -Force -Path $outsideTarget | Out-Null
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outsideBin) | Out-Null
    New-Item -ItemType Junction -Path $outsideBin -Target $outsideTarget | Out-Null
    $outsideResult = Invoke-InstallerProcess -LocalAppData $outside -PackagePath $packages['0.2.0'] -Version '0.2.0' -Sha256 (Get-FileHash -Algorithm SHA256 $packages['0.2.0']).Hash
    Assert-True ($outsideResult.ExitCode -ne 0) 'outside junction unexpectedly succeeded'
    Assert-Equal ([IO.Path]::GetFullPath($outsideTarget).TrimEnd('\')) (Get-JunctionTarget $outsideBin) 'outside junction was retargeted'

    # An incomplete destination release cannot disturb the current release.
    $failedActivationCurrent = Get-JunctionTarget (Join-Path $root 'current')
    $blockedRelease = Join-Path $root 'releases\0.2.1-x86_64-pc-windows-msvc'
    New-Item -ItemType Directory -Force -Path $blockedRelease | Out-Null
    'unmanaged' | Set-Content -LiteralPath (Join-Path $blockedRelease 'unexpected.txt')
    $blocked = Invoke-InstallerProcess -LocalAppData $fresh -PackagePath $packages['0.2.1'] -Version '0.2.1' -Sha256 (Get-FileHash -Algorithm SHA256 $packages['0.2.1']).Hash
    Assert-True ($blocked.ExitCode -ne 0) 'incomplete destination unexpectedly activated'
    Assert-Equal $failedActivationCurrent (Get-JunctionTarget (Join-Path $root 'current')) 'failed activation changed current'

    # Four successful versions retain active plus two previous releases.
    $retention = New-ScenarioRoot 'retention'
    foreach ($version in $versions) { Install-Fixture -Scenario $retention -Package $packages[$version] -Version $version | Out-Null }
    $releaseDirectories = @(Get-ChildItem -LiteralPath (Join-Path $retention 'FarPilot\releases') -Directory | Where-Object { -not $_.Name.StartsWith('.') })
    Assert-Equal 3 $releaseDirectories.Count 'retention did not keep exactly active plus two prior releases'
    Assert-True (($releaseDirectories.Name -contains '0.2.3-x86_64-pc-windows-msvc')) 'active release was removed by retention'

    # DryRun makes no FarPilot root and leaves user PATH unchanged.
    $dryRun = New-ScenarioRoot 'dry-run'
    $dryPathBefore = [Environment]::GetEnvironmentVariable('Path', 'User')
    $dry = Invoke-InstallerProcess -LocalAppData $dryRun -PackagePath $packages['0.2.0'] -Version '0.2.0' -Sha256 (Get-FileHash -Algorithm SHA256 $packages['0.2.0']).Hash -DryRun
    Assert-Equal 0 $dry.ExitCode "DryRun failed: $($dry.Output)"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $dryRun 'FarPilot'))) 'DryRun created FarPilot root'
    Assert-Equal $dryPathBefore ([Environment]::GetEnvironmentVariable('Path', 'User')) 'DryRun changed user PATH'

    # Production code must isolate process and task operations behind explicit functions.
    $source = Get-Content -LiteralPath $Installer -Raw
    Assert-True ($source -match 'function\s+Stop-ManagedFarPilotProcesses') 'managed process stop boundary is missing'
    Assert-True ($source -match 'function\s+Set-FarPilotStartupTask') 'startup task boundary is missing'

    Write-Host 'FarPilot Windows installer behavior verified'
} finally {
    if ($null -eq $OriginalLocalAppData) { Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue } else { $env:LOCALAPPDATA = $OriginalLocalAppData }
    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

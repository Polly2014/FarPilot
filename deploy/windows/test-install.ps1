Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.IO.Compression

$Installer = Join-Path $PSScriptRoot 'install.ps1'
$OriginalLocalAppData = $env:LOCALAPPDATA
$PowerShellExe = (Get-Process -Id $PID).Path
$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('farpilot-installer-test-' + [guid]::NewGuid().ToString('N'))
$MaxZipEntryBytes = [long](64MB)
$MaxZipAggregateBytes = [long](96MB)
$TestCurrentUserSid = 'S-1-5-21-1000'

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

function Initialize-FarPilotFixture {
    param(
        [string]$Version,
        [string]$Destination,
        [string]$Marker = '',
        [string]$ProductName = 'farpilot',
        [string]$VersionMarkerPath = ''
    )
    $source = [IO.Path]::ChangeExtension($Destination, '.rs')
    $escaped = $Version.Replace('\', '\\').Replace('"', '\"')
    $escapedMarker = $Marker.Replace('\', '\\').Replace('"', '\"')
    $escapedProductName = $ProductName.Replace('\', '\\').Replace('"', '\"')
    $escapedVersionMarkerPath = $VersionMarkerPath.Replace('\', '\\').Replace('"', '\"')
    @"
fn main() {
    if std::env::args().nth(1).as_deref() == Some("--version") {
        let marker = "$escapedVersionMarkerPath";
        if !marker.is_empty() {
            std::fs::write(marker, "version-invoked").unwrap();
        }
        println!("$escapedProductName $escaped");
    } else {
        println!("fixture $escaped $escapedMarker");
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

function Initialize-TestZipPackage {
    param(
        [string]$Destination,
        [object[]]$Entries
    )
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Force
    }
    $file = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $archive = [IO.Compression.ZipArchive]::new($file, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            foreach ($entrySpec in $Entries) {
                $entry = $archive.CreateEntry([string]$entrySpec.Name, [IO.Compression.CompressionLevel]::Optimal)
                if ($null -ne $entrySpec.PSObject.Properties['ExternalAttributes']) {
                    $entry.ExternalAttributes = [int]$entrySpec.ExternalAttributes
                }
                if ($null -ne $entrySpec.PSObject.Properties['Directory'] -and [bool]$entrySpec.Directory) {
                    continue
                }
                $entryStream = $entry.Open()
                try {
                    if ($null -ne $entrySpec.PSObject.Properties['SourcePath']) {
                        $sourceStream = [IO.File]::OpenRead([string]$entrySpec.SourcePath)
                        try {
                            $sourceStream.CopyTo($entryStream)
                        } finally {
                            $sourceStream.Dispose()
                        }
                    } elseif ($null -ne $entrySpec.PSObject.Properties['Size']) {
                        $remaining = [long]$entrySpec.Size
                        $buffer = [byte[]]::new(1MB)
                        while ($remaining -gt 0) {
                            $count = [int][Math]::Min([long]$buffer.Length, $remaining)
                            $entryStream.Write($buffer, 0, $count)
                            $remaining -= $count
                        }
                    } else {
                        $bytes = [Text.Encoding]::UTF8.GetBytes([string]$entrySpec.Content)
                        $entryStream.Write($bytes, 0, $bytes.Length)
                    }
                } finally {
                    $entryStream.Dispose()
                }
            }
        } finally {
            $archive.Dispose()
        }
    } finally {
        $file.Dispose()
    }
    return $Destination
}

function Initialize-TestState {
    param([string]$LocalAppData)
    $state = Join-Path $LocalAppData 'installer-test-state'
    New-Item -ItemType Directory -Force -Path $state | Out-Null
    $pathFile = Join-Path $state 'path.json'
    if (-not (Test-Path -LiteralPath $pathFile)) {
        [PSCustomObject]@{ Exists = $true; Value = 'C:\Unrelated'; Kind = 'String'; ProcessValue = 'C:\Unrelated' } |
            ConvertTo-Json | Set-Content -LiteralPath $pathFile -Encoding UTF8
    }
    $processFile = Join-Path $state 'processes.json'
    if (-not (Test-Path -LiteralPath $processFile)) { '[]' | Set-Content -LiteralPath $processFile -Encoding UTF8 }
    $taskFile = Join-Path $state 'task.json'
    if (-not (Test-Path -LiteralPath $taskFile)) {
        [PSCustomObject]@{ Exists = $false; Running = $false; Executable = $null; Arguments = $null; UserId = $null; RunLevel = $null } |
            ConvertTo-Json | Set-Content -LiteralPath $taskFile -Encoding UTF8
    }
    return $state
}

function Get-TestState {
    param([string]$LocalAppData, [string]$Name)
    $path = Join-Path (Initialize-TestState $LocalAppData) "$Name.json"
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}

function Write-TestStateFile {
    param([string]$LocalAppData, [string]$Name, [object]$Value)
    $path = Join-Path (Initialize-TestState $LocalAppData) "$Name.json"
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding UTF8
}

function Invoke-InstallerProcess {
    param(
        [string]$LocalAppData,
        [string]$PackagePath,
        [string]$Version,
        [string]$Sha256,
        [switch]$DryRun,
        [switch]$EnableStartupTask,
        [string]$FailAfter = '',
        [int]$Retain = 3,
        [string]$InstallDir = ''
    )
    $testState = Initialize-TestState $LocalAppData
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $Installer,
        '-LocalPackagePath', $PackagePath,
        '-LocalPackageVersion', $Version,
        '-LocalPackageSha256', $Sha256,
        '-TestStateDirectory', $testState,
        '-Retain', [string]$Retain
    )
    if (-not $EnableStartupTask) { $arguments += '-NoStartupTask' }
    if (-not [string]::IsNullOrWhiteSpace($InstallDir)) { $arguments += @('-InstallDir', $InstallDir) }
    if ($DryRun) { $arguments += '-DryRun' }
    if (-not [string]::IsNullOrWhiteSpace($FailAfter)) { $arguments += @('-TestFailAfter', $FailAfter) }
    $previousLocalAppData = $env:LOCALAPPDATA
    $previousTestMode = $env:FARPILOT_INSTALLER_TEST_MODE
    try {
        $env:LOCALAPPDATA = $LocalAppData
        $env:FARPILOT_INSTALLER_TEST_MODE = '1'
        $output = & $PowerShellExe @arguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    } finally {
        $env:LOCALAPPDATA = $previousLocalAppData
        if ($null -eq $previousTestMode) { Remove-Item Env:FARPILOT_INSTALLER_TEST_MODE -ErrorAction SilentlyContinue } else { $env:FARPILOT_INSTALLER_TEST_MODE = $previousTestMode }
    }
    return [PSCustomObject]@{ ExitCode = $exitCode; Output = $output; TestState = $testState }
}

function Invoke-UninstallerProcess {
    param(
        [string]$LocalAppData,
        [switch]$PurgeState,
        [string]$PurgeConfirmation = '',
        [switch]$DryRun,
        [string]$FailAfter = '',
        [string]$LegacyInstallDir = '',
        [string[]]$AdditionalArguments = @()
    )
    $testState = Initialize-TestState $LocalAppData
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $Installer,
        '-Uninstall',
        '-TestStateDirectory', $testState
    )
    if ($PurgeState) { $arguments += '-PurgeState' }
    if (-not [string]::IsNullOrWhiteSpace($LegacyInstallDir)) { $arguments += @('-InstallDir', $LegacyInstallDir) }
    if ($DryRun) { $arguments += '-DryRun' }
    if (-not [string]::IsNullOrWhiteSpace($FailAfter)) { $arguments += @('-TestFailAfter', $FailAfter) }
    $arguments += $AdditionalArguments
    $previousLocalAppData = $env:LOCALAPPDATA
    $previousTestMode = $env:FARPILOT_INSTALLER_TEST_MODE
    try {
        $env:LOCALAPPDATA = $LocalAppData
        $env:FARPILOT_INSTALLER_TEST_MODE = '1'
        if ($PurgeState) {
            $output = $PurgeConfirmation | & $PowerShellExe @arguments 2>&1 | Out-String
        } else {
            $output = & $PowerShellExe @arguments 2>&1 | Out-String
        }
        $exitCode = $LASTEXITCODE
    } finally {
        $env:LOCALAPPDATA = $previousLocalAppData
        if ($null -eq $previousTestMode) { Remove-Item Env:FARPILOT_INSTALLER_TEST_MODE -ErrorAction SilentlyContinue } else { $env:FARPILOT_INSTALLER_TEST_MODE = $previousTestMode }
    }
    return [PSCustomObject]@{ ExitCode = $exitCode; Output = $output; TestState = $testState }
}

function Invoke-RawInstallerProcess {
    param(
        [string]$LocalAppData,
        [string[]]$InstallerArguments,
        [bool]$TestMode = $true
    )
    $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Installer) + $InstallerArguments
    $previousLocalAppData = $env:LOCALAPPDATA
    $previousTestMode = $env:FARPILOT_INSTALLER_TEST_MODE
    try {
        $env:LOCALAPPDATA = $LocalAppData
        if ($TestMode) { $env:FARPILOT_INSTALLER_TEST_MODE = '1' } else { Remove-Item Env:FARPILOT_INSTALLER_TEST_MODE -ErrorAction SilentlyContinue }
        $output = & $PowerShellExe @arguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    } finally {
        $env:LOCALAPPDATA = $previousLocalAppData
        if ($null -eq $previousTestMode) { Remove-Item Env:FARPILOT_INSTALLER_TEST_MODE -ErrorAction SilentlyContinue } else { $env:FARPILOT_INSTALLER_TEST_MODE = $previousTestMode }
    }
    return [PSCustomObject]@{ ExitCode = $exitCode; Output = $output }
}

function Invoke-UnguardedPurgeConfirmation {
    param([string]$LocalAppData)
    $arguments = @(
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-File', $Installer,
        '-Uninstall',
        '-PurgeState',
        '-ConfirmPurge',
        '-DryRun'
    )
    $previousLocalAppData = $env:LOCALAPPDATA
    $previousTestMode = $env:FARPILOT_INSTALLER_TEST_MODE
    try {
        $env:LOCALAPPDATA = $LocalAppData
        Remove-Item Env:FARPILOT_INSTALLER_TEST_MODE -ErrorAction SilentlyContinue
        $output = & $PowerShellExe @arguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    } finally {
        $env:LOCALAPPDATA = $previousLocalAppData
        if ($null -eq $previousTestMode) { Remove-Item Env:FARPILOT_INSTALLER_TEST_MODE -ErrorAction SilentlyContinue } else { $env:FARPILOT_INSTALLER_TEST_MODE = $previousTestMode }
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

function Initialize-ScenarioRoot {
    param([string]$Name)
    $path = Join-Path $TempRoot $Name
    New-Item -ItemType Directory -Force -Path $path | Out-Null
    return $path
}

function Install-Fixture {
    param(
        [string]$Scenario,
        [string]$Package,
        [string]$Version,
        [switch]$EnableStartupTask,
        [string]$FailAfter = '',
        [int]$Retain = 3,
        [string]$InstallDir = ''
    )
    $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $Package).Hash.ToLowerInvariant()
    $result = Invoke-InstallerProcess -LocalAppData $Scenario -PackagePath $Package -Version $Version -Sha256 $sha -EnableStartupTask:$EnableStartupTask -FailAfter $FailAfter -Retain $Retain -InstallDir $InstallDir
    if ($result.ExitCode -ne 0) { throw "installer failed for $Version`: $($result.Output)" }
    return $result
}

function Assert-PreMutationFailureState {
    param(
        [string]$Scenario,
        [string]$ExpectedCurrent,
        [string]$ExpectedBin,
        [string]$ExpectedPathJson,
        [string]$ExpectedTaskJson,
        [string]$RejectedVersion,
        [string]$Label,
        [string]$ExpectedProcessJson = ''
    )
    $root = Join-Path $Scenario 'FarPilot'
    Assert-Equal -Expected $ExpectedCurrent -Actual (Get-JunctionTarget (Join-Path $root 'current')) -Message "$Label changed current"
    Assert-Equal -Expected $ExpectedBin -Actual (Get-JunctionTarget (Join-Path $root 'bin')) -Message "$Label changed bin"
    Assert-Equal -Expected $ExpectedPathJson -Actual (Get-Content -LiteralPath (Join-Path (Initialize-TestState $Scenario) 'path.json') -Raw) -Message "$Label changed PATH"
    Assert-Equal -Expected $ExpectedTaskJson -Actual (Get-Content -LiteralPath (Join-Path (Initialize-TestState $Scenario) 'task.json') -Raw) -Message "$Label changed task"
    if (-not [string]::IsNullOrWhiteSpace($ExpectedProcessJson)) {
        Assert-Equal -Expected $ExpectedProcessJson -Actual (Get-Content -LiteralPath (Join-Path (Initialize-TestState $Scenario) 'processes.json') -Raw) -Message "$Label changed processes"
    }
    Assert-Equal -Expected 'identity-sentinel' -Actual (Get-Content -LiteralPath (Join-Path $root 'host-identity.json') -Raw).Trim() -Message "$Label changed identity"
    Assert-Equal -Expected 'config-sentinel' -Actual (Get-Content -LiteralPath (Join-Path $root 'host.json') -Raw).Trim() -Message "$Label changed config"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root "releases\$RejectedVersion-x86_64-pc-windows-msvc"))) "$Label left a new release"
    $artifacts = @(Get-ChildItem -LiteralPath $root -Force -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\.(staging|backup|legacy)\.' })
    Assert-Equal -Expected 0 -Actual $artifacts.Count -Message "$Label left managed artifacts"
}

New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null
try {
    $fixtures = Join-Path $TempRoot 'fixtures'
    New-Item -ItemType Directory -Force -Path $fixtures | Out-Null
    $versions = @('0.2.0', '0.2.1', '0.2.2', '0.2.3')
    $packages = @{}
    foreach ($version in $versions) {
        $path = Join-Path $fixtures "farpilot-$version.exe"
        Initialize-FarPilotFixture -Version $version -Destination $path
        $packages[$version] = $path
    }
    $alternateSameVersion = Join-Path $fixtures 'farpilot-0.2.0-alternate.exe'
    Initialize-FarPilotFixture -Version '0.2.0' -Destination $alternateSameVersion -Marker 'alternate-build'

    # ZIP packages must contain exactly the CLI and runner and must fail before mutation when malformed.
    $zipRunner = Join-Path $fixtures 'farpilot-host-runner-0.2.1.exe'
    Initialize-FarPilotFixture -Version '0.2.1' -Destination $zipRunner -ProductName 'farpilot-host-runner'
    $mismatchedZipRunner = Join-Path $fixtures 'farpilot-host-runner-0.2.2.exe'
    Initialize-FarPilotFixture -Version '0.2.2' -Destination $mismatchedZipRunner -ProductName 'farpilot-host-runner'
    $zipCli = $packages['0.2.1']
    $validZip = Join-Path $fixtures 'farpilot-windows-x86_64.zip'
    $validEntries = @(
        [PSCustomObject]@{ Name = 'farpilot.exe'; SourcePath = $zipCli },
        [PSCustomObject]@{ Name = 'farpilot-host-runner.exe'; SourcePath = $zipRunner }
    )
    $null = Initialize-TestZipPackage -Destination $validZip -Entries $validEntries

    $invalidZips = [ordered]@{}
    $invalidZips['missing runner'] = Join-Path $fixtures 'missing-runner.zip'
    $null = Initialize-TestZipPackage -Destination $invalidZips['missing runner'] -Entries @(
        [PSCustomObject]@{ Name = 'farpilot.exe'; SourcePath = $zipCli }
    )
    $invalidZips['missing CLI'] = Join-Path $fixtures 'missing-cli.zip'
    $null = Initialize-TestZipPackage -Destination $invalidZips['missing CLI'] -Entries @(
        [PSCustomObject]@{ Name = 'farpilot-host-runner.exe'; SourcePath = $zipRunner }
    )
    $invalidZips['extra file'] = Join-Path $fixtures 'extra-file.zip'
    $null = Initialize-TestZipPackage -Destination $invalidZips['extra file'] -Entries @(
        $validEntries[0],
        $validEntries[1],
        [PSCustomObject]@{ Name = 'unexpected.txt'; Content = 'unexpected' }
    )
    $invalidZips['directory entry'] = Join-Path $fixtures 'directory-entry.zip'
    $null = Initialize-TestZipPackage -Destination $invalidZips['directory entry'] -Entries @(
        $validEntries[0],
        $validEntries[1],
        [PSCustomObject]@{ Name = 'nested/'; Directory = $true }
    )
    $invalidZips['parent traversal'] = Join-Path $fixtures 'parent-traversal.zip'
    $null = Initialize-TestZipPackage -Destination $invalidZips['parent traversal'] -Entries @(
        [PSCustomObject]@{ Name = '../farpilot.exe'; SourcePath = $zipCli },
        $validEntries[1]
    )
    $invalidZips['absolute path'] = Join-Path $fixtures 'absolute-path.zip'
    $null = Initialize-TestZipPackage -Destination $invalidZips['absolute path'] -Entries @(
        [PSCustomObject]@{ Name = '/farpilot.exe'; SourcePath = $zipCli },
        $validEntries[1]
    )
    $invalidZips['drive-qualified path'] = Join-Path $fixtures 'drive-qualified-path.zip'
    $null = Initialize-TestZipPackage -Destination $invalidZips['drive-qualified path'] -Entries @(
        [PSCustomObject]@{ Name = 'C:\farpilot.exe'; SourcePath = $zipCli },
        $validEntries[1]
    )
    $invalidZips['nested path'] = Join-Path $fixtures 'nested-path.zip'
    $null = Initialize-TestZipPackage -Destination $invalidZips['nested path'] -Entries @(
        [PSCustomObject]@{ Name = 'nested/farpilot.exe'; SourcePath = $zipCli },
        $validEntries[1]
    )
    $invalidZips['case-insensitive duplicate'] = Join-Path $fixtures 'case-duplicate.zip'
    $null = Initialize-TestZipPackage -Destination $invalidZips['case-insensitive duplicate'] -Entries @(
        $validEntries[0],
        [PSCustomObject]@{ Name = 'FARPILOT.EXE'; SourcePath = $zipCli },
        $validEntries[1]
    )
    $unixSymlinkAttributes = [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]2717843456), 0)
    $invalidZips['symlink external attributes'] = Join-Path $fixtures 'symlink-attributes.zip'
    $null = Initialize-TestZipPackage -Destination $invalidZips['symlink external attributes'] -Entries @(
        [PSCustomObject]@{ Name = 'farpilot.exe'; SourcePath = $zipCli; ExternalAttributes = $unixSymlinkAttributes },
        $validEntries[1]
    )
    $invalidZips['reparse external attributes'] = Join-Path $fixtures 'reparse-attributes.zip'
    $null = Initialize-TestZipPackage -Destination $invalidZips['reparse external attributes'] -Entries @(
        [PSCustomObject]@{ Name = 'farpilot.exe'; SourcePath = $zipCli; ExternalAttributes = [int][IO.FileAttributes]::ReparsePoint },
        $validEntries[1]
    )
    $invalidZips['Unix directory external attributes'] = Join-Path $fixtures 'unix-directory-attributes.zip'
    $null = Initialize-TestZipPackage -Destination $invalidZips['Unix directory external attributes'] -Entries @(
        [PSCustomObject]@{ Name = 'farpilot.exe'; SourcePath = $zipCli; ExternalAttributes = 1107230720 },
        $validEntries[1]
    )
    $invalidZips['DOS directory external attributes'] = Join-Path $fixtures 'dos-directory-attributes.zip'
    $null = Initialize-TestZipPackage -Destination $invalidZips['DOS directory external attributes'] -Entries @(
        [PSCustomObject]@{ Name = 'farpilot.exe'; SourcePath = $zipCli; ExternalAttributes = [int][IO.FileAttributes]::Directory },
        $validEntries[1]
    )
    $invalidZips['Unix nonregular external attributes'] = Join-Path $fixtures 'unix-nonregular-attributes.zip'
    $null = Initialize-TestZipPackage -Destination $invalidZips['Unix nonregular external attributes'] -Entries @(
        [PSCustomObject]@{ Name = 'farpilot.exe'; SourcePath = $zipCli; ExternalAttributes = 570359808 },
        $validEntries[1]
    )
    $invalidZips['oversized entry'] = Join-Path $fixtures 'oversized-entry.zip'
    $null = Initialize-TestZipPackage -Destination $invalidZips['oversized entry'] -Entries @(
        [PSCustomObject]@{ Name = 'farpilot.exe'; Size = ($MaxZipEntryBytes + 1) },
        $validEntries[1]
    )
    $invalidZips['oversized aggregate'] = Join-Path $fixtures 'oversized-aggregate.zip'
    $aggregateEntryBytes = [long]($MaxZipAggregateBytes / 2) + 1
    $null = Initialize-TestZipPackage -Destination $invalidZips['oversized aggregate'] -Entries @(
        [PSCustomObject]@{ Name = 'farpilot.exe'; Size = $aggregateEntryBytes },
        [PSCustomObject]@{ Name = 'farpilot-host-runner.exe'; Size = $aggregateEntryBytes }
    )
    $invalidZips['binary version mismatch'] = Join-Path $fixtures 'version-mismatch.zip'
    $null = Initialize-TestZipPackage -Destination $invalidZips['binary version mismatch'] -Entries @(
        $validEntries[0],
        [PSCustomObject]@{ Name = 'farpilot-host-runner.exe'; SourcePath = $mismatchedZipRunner }
    )
    $zipRejection = Initialize-ScenarioRoot 'zip-rejection'
    Install-Fixture -Scenario $zipRejection -Package $packages['0.2.0'] -Version '0.2.0' -EnableStartupTask | Out-Null
    $zipRejectionRoot = Join-Path $zipRejection 'FarPilot'
    'identity-sentinel' | Set-Content -LiteralPath (Join-Path $zipRejectionRoot 'host-identity.json')
    'config-sentinel' | Set-Content -LiteralPath (Join-Path $zipRejectionRoot 'host.json')
    $zipTask = Get-TestState -LocalAppData $zipRejection -Name 'task'
    $zipTask.Running = $true
    Write-TestStateFile -LocalAppData $zipRejection -Name 'task' -Value $zipTask
    Write-TestStateFile -LocalAppData $zipRejection -Name 'processes' -Value @(
        [PSCustomObject]@{ Id = 91; Name = 'farpilot.exe'; ExecutablePath = "$zipRejectionRoot\current\farpilot.exe"; Stopped = $false },
        [PSCustomObject]@{ Id = 92; Name = 'farpilot.exe'; ExecutablePath = 'C:\External\farpilot.exe'; Stopped = $false },
        [PSCustomObject]@{ Id = 93; Name = 'farpilot-host-runner.exe'; ExecutablePath = "$zipRejectionRoot\current\farpilot-host-runner.exe"; Stopped = $false },
        [PSCustomObject]@{ Id = 94; Name = 'farpilot-host-runner.exe'; ExecutablePath = 'C:\External\farpilot-host-runner.exe'; Stopped = $false }
    )
    $zipCurrent = Get-JunctionTarget (Join-Path $zipRejectionRoot 'current')
    $zipBin = Get-JunctionTarget (Join-Path $zipRejectionRoot 'bin')
    $zipActiveDigest = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $zipCurrent 'farpilot.exe')).Hash
    $zipPathJson = Get-Content -LiteralPath (Join-Path (Initialize-TestState $zipRejection) 'path.json') -Raw
    $zipTaskJson = Get-Content -LiteralPath (Join-Path (Initialize-TestState $zipRejection) 'task.json') -Raw
    $zipProcessJson = Get-Content -LiteralPath (Join-Path (Initialize-TestState $zipRejection) 'processes.json') -Raw
    foreach ($invalidZip in $invalidZips.GetEnumerator()) {
        $invalidSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $invalidZip.Value).Hash.ToLowerInvariant()
        $invalidResult = Invoke-InstallerProcess -LocalAppData $zipRejection -PackagePath $invalidZip.Value -Version '0.2.1' -Sha256 $invalidSha -EnableStartupTask
        Assert-True ($invalidResult.ExitCode -ne 0) "$($invalidZip.Key) ZIP unexpectedly succeeded"
        Assert-PreMutationFailureState -Scenario $zipRejection -ExpectedCurrent $zipCurrent -ExpectedBin $zipBin -ExpectedPathJson $zipPathJson -ExpectedTaskJson $zipTaskJson -ExpectedProcessJson $zipProcessJson -RejectedVersion '0.2.1' -Label "$($invalidZip.Key) ZIP"
        Assert-Equal -Expected $zipActiveDigest -Actual (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $zipCurrent 'farpilot.exe')).Hash -Message "$($invalidZip.Key) ZIP changed the active release"
    }

    # RED: the legacy installer cannot yet activate the approved exact-two-file ZIP package.
    $zipInstall = Initialize-ScenarioRoot 'zip-valid'
    $validZipSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $validZip).Hash.ToLowerInvariant()
    $validZipResult = Invoke-InstallerProcess -LocalAppData $zipInstall -PackagePath $validZip -Version '0.2.1' -Sha256 $validZipSha
    Assert-Equal -Expected 0 -Actual $validZipResult.ExitCode -Message "exact-two-file ZIP install failed: $($validZipResult.Output)"
    $zipRelease = Join-Path $zipInstall 'FarPilot\releases\0.2.1-x86_64-pc-windows-msvc'
    Assert-True (Test-Path -LiteralPath (Join-Path $zipRelease 'farpilot.exe') -PathType Leaf) 'ZIP install omitted farpilot.exe'
    Assert-True (Test-Path -LiteralPath (Join-Path $zipRelease 'farpilot-host-runner.exe') -PathType Leaf) 'ZIP install omitted farpilot-host-runner.exe'

    # Existing release bytes must match the verified package before either executable is invoked.
    $tamperedCliScenario = Initialize-ScenarioRoot 'existing-cli-preflight'
    Install-Fixture -Scenario $tamperedCliScenario -Package $packages['0.2.0'] -Version '0.2.0' | Out-Null
    $tamperedCliRoot = Join-Path $tamperedCliScenario 'FarPilot'
    $tamperedCliRelease = Get-JunctionTarget (Join-Path $tamperedCliRoot 'current')
    $tamperedCliMarker = Join-Path $tamperedCliScenario 'tampered-cli-version-marker.txt'
    $tamperedCliFixture = Join-Path $fixtures 'tampered-farpilot-0.2.0.exe'
    Initialize-FarPilotFixture -Version '0.2.0' -Destination $tamperedCliFixture -Marker 'tampered-cli' -VersionMarkerPath $tamperedCliMarker
    Copy-Item -LiteralPath $tamperedCliFixture -Destination (Join-Path $tamperedCliRelease 'farpilot.exe') -Force
    $trustedCliSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $packages['0.2.0']).Hash.ToLowerInvariant()
    $tamperedCliResult = Invoke-InstallerProcess -LocalAppData $tamperedCliScenario -PackagePath $packages['0.2.0'] -Version '0.2.0' -Sha256 $trustedCliSha
    Assert-True ($tamperedCliResult.ExitCode -ne 0) 'tampered existing CLI unexpectedly matched the verified package'
    Assert-True (-not (Test-Path -LiteralPath $tamperedCliMarker)) 'tampered existing CLI executed before byte comparison'

    $tamperedRunnerMarker = Join-Path $zipInstall 'tampered-runner-version-marker.txt'
    $tamperedRunnerFixture = Join-Path $fixtures 'tampered-farpilot-host-runner-0.2.1.exe'
    Initialize-FarPilotFixture -Version '0.2.1' -Destination $tamperedRunnerFixture -Marker 'tampered-runner' -ProductName 'farpilot-host-runner' -VersionMarkerPath $tamperedRunnerMarker
    Copy-Item -LiteralPath $tamperedRunnerFixture -Destination (Join-Path $zipRelease 'farpilot-host-runner.exe') -Force
    $tamperedRunnerResult = Invoke-InstallerProcess -LocalAppData $zipInstall -PackagePath $validZip -Version '0.2.1' -Sha256 $validZipSha
    Assert-True ($tamperedRunnerResult.ExitCode -ne 0) 'tampered existing runner unexpectedly matched the verified package'
    Assert-True (-not (Test-Path -LiteralPath $tamperedRunnerMarker)) 'tampered existing runner executed before byte comparison'

    # Fresh install creates a versioned release and managed junctions.
    $fresh = Initialize-ScenarioRoot 'fresh'
    $pathBefore = [Environment]::GetEnvironmentVariable('Path', 'User')
    Install-Fixture -Scenario $fresh -Package $packages['0.2.0'] -Version '0.2.0' | Out-Null
    $root = Join-Path $fresh 'FarPilot'
    $releaseDir = Join-Path $root 'releases\0.2.0-x86_64-pc-windows-msvc'
    $releaseExe = Join-Path $releaseDir 'farpilot.exe'
    Assert-True (Test-Path -LiteralPath $releaseExe -PathType Leaf) 'versioned release executable was not installed'
    Assert-Equal -Expected ([IO.Path]::GetFullPath($releaseDir).TrimEnd('\')) -Actual (Get-JunctionTarget (Join-Path $root 'current')) -Message 'current junction target is wrong'
    Assert-Equal -Expected ([IO.Path]::GetFullPath($releaseDir).TrimEnd('\')) -Actual (Get-JunctionTarget (Join-Path $root 'bin')) -Message 'bin junction target is wrong'
    Assert-Equal -Expected $pathBefore -Actual ([Environment]::GetEnvironmentVariable('Path', 'User')) -Message 'test PATH adapter changed the real user PATH'

    # Same release is idempotent and does not replace the executable.
    $beforeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $releaseExe).Hash
    $beforeWrite = (Get-Item -LiteralPath $releaseExe).LastWriteTimeUtc
    Install-Fixture -Scenario $fresh -Package $packages['0.2.0'] -Version '0.2.0' | Out-Null
    Assert-Equal -Expected $beforeHash -Actual (Get-FileHash -Algorithm SHA256 -LiteralPath $releaseExe).Hash -Message 'same-version reinstall changed bytes'
    Assert-Equal -Expected $beforeWrite -Actual (Get-Item -LiteralPath $releaseExe).LastWriteTimeUtc -Message 'same-version reinstall replaced the executable'

    # A same-version release with different verified package bytes must fail closed.
    $beforeSameVersionHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $releaseExe).Hash
    $beforeSameVersionCurrent = Get-JunctionTarget (Join-Path $root 'current')
    $alternateSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $alternateSameVersion).Hash
    $alternateResult = Invoke-InstallerProcess -LocalAppData $fresh -PackagePath $alternateSameVersion -Version '0.2.0' -Sha256 $alternateSha
    Assert-True ($alternateResult.ExitCode -ne 0) 'different same-version package unexpectedly activated'
    Assert-Equal -Expected $beforeSameVersionHash -Actual (Get-FileHash -Algorithm SHA256 -LiteralPath $releaseExe).Hash -Message 'same-version mismatch changed existing release bytes'
    Assert-Equal -Expected $beforeSameVersionCurrent -Actual (Get-JunctionTarget (Join-Path $root 'current')) -Message 'same-version mismatch changed current'

    # Checksum mismatch and binary-version mismatch cannot move current.
    $currentBefore = Get-JunctionTarget (Join-Path $root 'current')
    $badChecksum = Invoke-InstallerProcess -LocalAppData $fresh -PackagePath $packages['0.2.1'] -Version '0.2.1' -Sha256 ('0' * 64)
    Assert-True ($badChecksum.ExitCode -ne 0) 'checksum mismatch unexpectedly succeeded'
    Assert-Equal -Expected $currentBefore -Actual (Get-JunctionTarget (Join-Path $root 'current')) -Message 'checksum mismatch changed current'
    $wrongVersionSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $packages['0.2.0']).Hash.ToLowerInvariant()
    $wrongVersion = Invoke-InstallerProcess -LocalAppData $fresh -PackagePath $packages['0.2.0'] -Version '0.2.1' -Sha256 $wrongVersionSha
    Assert-True ($wrongVersion.ExitCode -ne 0) 'binary version mismatch unexpectedly succeeded'
    Assert-Equal -Expected $currentBefore -Actual (Get-JunctionTarget (Join-Path $root 'current')) -Message 'version mismatch changed current'

    # Legacy managed binary migrates without touching identity or config.
    $legacy = Initialize-ScenarioRoot 'legacy'
    $legacyRoot = Join-Path $legacy 'FarPilot'
    $legacyBin = Join-Path $legacyRoot 'bin'
    New-Item -ItemType Directory -Force -Path $legacyBin | Out-Null
    Copy-Item -LiteralPath $packages['0.2.0'] -Destination (Join-Path $legacyBin 'farpilot.exe')
    'identity-sentinel' | Set-Content -LiteralPath (Join-Path $legacyRoot 'host-identity.json')
    'config-sentinel' | Set-Content -LiteralPath (Join-Path $legacyRoot 'host.json')
    Install-Fixture -Scenario $legacy -Package $validZip -Version '0.2.1' | Out-Null
    Assert-Equal -Expected 'identity-sentinel' -Actual (Get-Content -LiteralPath (Join-Path $legacyRoot 'host-identity.json') -Raw).Trim() -Message 'identity changed during migration'
    Assert-Equal -Expected 'config-sentinel' -Actual (Get-Content -LiteralPath (Join-Path $legacyRoot 'host.json') -Raw).Trim() -Message 'config changed during migration'
    Assert-True (((Get-Item -LiteralPath $legacyBin -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) 'legacy bin was not converted to a managed junction'
    Assert-True (Test-Path -LiteralPath (Join-Path $legacyBin 'farpilot-host-runner.exe') -PathType Leaf) 'legacy migration did not activate the runner'

    # Unmanaged nonempty bin directories are refused and preserved.
    $unmanaged = Initialize-ScenarioRoot 'unmanaged'
    $unmanagedBin = Join-Path $unmanaged 'FarPilot\bin'
    New-Item -ItemType Directory -Force -Path $unmanagedBin | Out-Null
    'keep-me' | Set-Content -LiteralPath (Join-Path $unmanagedBin 'user.txt')
    $unmanagedResult = Invoke-InstallerProcess -LocalAppData $unmanaged -PackagePath $packages['0.2.0'] -Version '0.2.0' -Sha256 (Get-FileHash -Algorithm SHA256 $packages['0.2.0']).Hash
    Assert-True ($unmanagedResult.ExitCode -ne 0) 'unmanaged nonempty bin unexpectedly succeeded'
    Assert-Equal -Expected 'keep-me' -Actual (Get-Content -LiteralPath (Join-Path $unmanagedBin 'user.txt') -Raw).Trim() -Message 'unmanaged file was modified'

    # Junctions outside the managed releases root are refused.
    $outside = Initialize-ScenarioRoot 'outside'
    $outsideTarget = Join-Path $outside 'external-target'
    $outsideBin = Join-Path $outside 'FarPilot\bin'
    New-Item -ItemType Directory -Force -Path $outsideTarget | Out-Null
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outsideBin) | Out-Null
    New-Item -ItemType Junction -Path $outsideBin -Target $outsideTarget | Out-Null
    $outsideResult = Invoke-InstallerProcess -LocalAppData $outside -PackagePath $packages['0.2.0'] -Version '0.2.0' -Sha256 (Get-FileHash -Algorithm SHA256 $packages['0.2.0']).Hash
    Assert-True ($outsideResult.ExitCode -ne 0) 'outside junction unexpectedly succeeded'
    Assert-Equal -Expected ([IO.Path]::GetFullPath($outsideTarget).TrimEnd('\')) -Actual (Get-JunctionTarget $outsideBin) -Message 'outside junction was retargeted'

    # Dangling or incomplete in-root aliases are rejected before any mutable installer action.
    foreach ($aliasName in @('current', 'bin')) {
        $dangling = Initialize-ScenarioRoot ("dangling-" + $aliasName)
        Install-Fixture -Scenario $dangling -Package $packages['0.2.0'] -Version '0.2.0' -EnableStartupTask | Out-Null
        $danglingRoot = Join-Path $dangling 'FarPilot'
        'identity-sentinel' | Set-Content -LiteralPath (Join-Path $danglingRoot 'host-identity.json')
        'config-sentinel' | Set-Content -LiteralPath (Join-Path $danglingRoot 'host.json')
        $danglingTask = Get-TestState -LocalAppData $dangling -Name 'task'
        $danglingTask.Running = $true
        Write-TestStateFile -LocalAppData $dangling -Name 'task' -Value $danglingTask
        $danglingPathJson = Get-Content -LiteralPath (Join-Path (Initialize-TestState $dangling) 'path.json') -Raw
        $danglingTaskJson = Get-Content -LiteralPath (Join-Path (Initialize-TestState $dangling) 'task.json') -Raw
        $otherAlias = if ($aliasName -eq 'current') { 'bin' } else { 'current' }
        $otherTarget = Get-JunctionTarget (Join-Path $danglingRoot $otherAlias)
        $missingTarget = Join-Path $danglingRoot 'releases\0.1.9-x86_64-pc-windows-msvc'
        New-Item -ItemType Directory -Force -Path $missingTarget | Out-Null
        $aliasPath = Join-Path $danglingRoot $aliasName
        Remove-Item -LiteralPath $aliasPath -Force
        New-Item -ItemType Junction -Path $aliasPath -Target $missingTarget | Out-Null
        Remove-Item -LiteralPath $missingTarget -Recurse -Force
        $danglingResult = Invoke-InstallerProcess -LocalAppData $dangling -PackagePath $packages['0.2.1'] -Version '0.2.1' -Sha256 (Get-FileHash -Algorithm SHA256 $packages['0.2.1']).Hash -EnableStartupTask
        Assert-True ($danglingResult.ExitCode -ne 0) "$aliasName dangling alias unexpectedly succeeded"
        $expectedCurrent = if ($aliasName -eq 'current') { [IO.Path]::GetFullPath($missingTarget).TrimEnd('\') } else { $otherTarget }
        $expectedBin = if ($aliasName -eq 'bin') { [IO.Path]::GetFullPath($missingTarget).TrimEnd('\') } else { $otherTarget }
        Assert-PreMutationFailureState -Scenario $dangling -ExpectedCurrent $expectedCurrent -ExpectedBin $expectedBin -ExpectedPathJson $danglingPathJson -ExpectedTaskJson $danglingTaskJson -RejectedVersion '0.2.1' -Label "$aliasName dangling alias"
    }

    $incompleteAlias = Initialize-ScenarioRoot 'incomplete-current-alias'
    Install-Fixture -Scenario $incompleteAlias -Package $packages['0.2.0'] -Version '0.2.0' -EnableStartupTask | Out-Null
    $incompleteRoot = Join-Path $incompleteAlias 'FarPilot'
    'identity-sentinel' | Set-Content -LiteralPath (Join-Path $incompleteRoot 'host-identity.json')
    'config-sentinel' | Set-Content -LiteralPath (Join-Path $incompleteRoot 'host.json')
    $incompleteTask = Get-TestState -LocalAppData $incompleteAlias -Name 'task'
    $incompleteTask.Running = $true
    Write-TestStateFile -LocalAppData $incompleteAlias -Name 'task' -Value $incompleteTask
    $incompletePathJson = Get-Content -LiteralPath (Join-Path (Initialize-TestState $incompleteAlias) 'path.json') -Raw
    $incompleteTaskJson = Get-Content -LiteralPath (Join-Path (Initialize-TestState $incompleteAlias) 'task.json') -Raw
    $incompleteBinTarget = Get-JunctionTarget (Join-Path $incompleteRoot 'bin')
    $incompleteTarget = Join-Path $incompleteRoot 'releases\0.1.8-x86_64-pc-windows-msvc'
    New-Item -ItemType Directory -Force -Path $incompleteTarget | Out-Null
    Remove-Item -LiteralPath (Join-Path $incompleteRoot 'current') -Force
    New-Item -ItemType Junction -Path (Join-Path $incompleteRoot 'current') -Target $incompleteTarget | Out-Null
    $incompleteResult = Invoke-InstallerProcess -LocalAppData $incompleteAlias -PackagePath $packages['0.2.1'] -Version '0.2.1' -Sha256 (Get-FileHash -Algorithm SHA256 $packages['0.2.1']).Hash -EnableStartupTask
    Assert-True ($incompleteResult.ExitCode -ne 0) 'incomplete current alias unexpectedly succeeded'
    Assert-PreMutationFailureState -Scenario $incompleteAlias -ExpectedCurrent ([IO.Path]::GetFullPath($incompleteTarget).TrimEnd('\')) -ExpectedBin $incompleteBinTarget -ExpectedPathJson $incompletePathJson -ExpectedTaskJson $incompleteTaskJson -RejectedVersion '0.2.1' -Label 'incomplete current alias'

    $validOlderAlias = Initialize-ScenarioRoot 'valid-older-alias'
    Install-Fixture -Scenario $validOlderAlias -Package $packages['0.2.0'] -Version '0.2.0' | Out-Null
    Install-Fixture -Scenario $validOlderAlias -Package $packages['0.2.1'] -Version '0.2.1' | Out-Null
    $validNewRelease = Join-Path $validOlderAlias 'FarPilot\releases\0.2.1-x86_64-pc-windows-msvc'
    Assert-Equal -Expected ([IO.Path]::GetFullPath($validNewRelease).TrimEnd('\')) -Actual (Get-JunctionTarget (Join-Path $validOlderAlias 'FarPilot\current')) -Message 'valid older managed alias did not upgrade'

    # An incomplete destination release cannot disturb the current release.
    $failedActivationCurrent = Get-JunctionTarget (Join-Path $root 'current')
    $blockedRelease = Join-Path $root 'releases\0.2.1-x86_64-pc-windows-msvc'
    New-Item -ItemType Directory -Force -Path $blockedRelease | Out-Null
    'unmanaged' | Set-Content -LiteralPath (Join-Path $blockedRelease 'unexpected.txt')
    $blocked = Invoke-InstallerProcess -LocalAppData $fresh -PackagePath $packages['0.2.1'] -Version '0.2.1' -Sha256 (Get-FileHash -Algorithm SHA256 $packages['0.2.1']).Hash
    Assert-True ($blocked.ExitCode -ne 0) 'incomplete destination unexpectedly activated'
    Assert-Equal -Expected $failedActivationCurrent -Actual (Get-JunctionTarget (Join-Path $root 'current')) -Message 'failed activation changed current'

    # Four successful versions retain active plus two previous releases.
    $retention = Initialize-ScenarioRoot 'retention'
    foreach ($version in $versions) { Install-Fixture -Scenario $retention -Package $packages[$version] -Version $version | Out-Null }
    $releaseDirectories = @(Get-ChildItem -LiteralPath (Join-Path $retention 'FarPilot\releases') -Directory | Where-Object { -not $_.Name.StartsWith('.') })
    Assert-Equal -Expected 3 -Actual $releaseDirectories.Count -Message 'retention did not keep exactly active plus two prior releases'
    Assert-True (($releaseDirectories.Name -contains '0.2.3-x86_64-pc-windows-msvc')) 'active release was removed by retention'

    # Retention always keeps an older active release plus only the newest Retain-1 non-active releases.
    $olderActive = Initialize-ScenarioRoot 'retention-older-active'
    foreach ($version in $versions) { Install-Fixture -Scenario $olderActive -Package $packages[$version] -Version $version -Retain 10 | Out-Null }
    $olderRoot = Join-Path $olderActive 'FarPilot'
    $olderReleases = Join-Path $olderRoot 'releases'
    $oldActiveRelease = Join-Path $olderReleases '0.2.0-x86_64-pc-windows-msvc'
    foreach ($alias in @('current', 'bin')) {
        $aliasPath = Join-Path $olderRoot $alias
        Remove-Item -LiteralPath $aliasPath -Force
        New-Item -ItemType Junction -Path $aliasPath -Target $oldActiveRelease | Out-Null
    }
    (Get-Item (Join-Path $olderReleases '0.2.1-x86_64-pc-windows-msvc')).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-3)
    (Get-Item (Join-Path $olderReleases '0.2.2-x86_64-pc-windows-msvc')).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-2)
    (Get-Item (Join-Path $olderReleases '0.2.3-x86_64-pc-windows-msvc')).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-1)
    Install-Fixture -Scenario $olderActive -Package $packages['0.2.0'] -Version '0.2.0' -Retain 3 | Out-Null
    $olderKept = @(Get-ChildItem -LiteralPath $olderReleases -Directory | Where-Object { -not $_.Name.StartsWith('.') })
    Assert-Equal -Expected 3 -Actual $olderKept.Count -Message 'retention kept more than active plus Retain-1 non-active releases'
    Assert-True ($olderKept.Name -contains '0.2.0-x86_64-pc-windows-msvc') 'older active release was removed'
    Assert-True ($olderKept.Name -contains '0.2.3-x86_64-pc-windows-msvc') 'newest non-active release was removed'
    Assert-True ($olderKept.Name -contains '0.2.2-x86_64-pc-windows-msvc') 'second-newest non-active release was removed'
    Assert-True (-not ($olderKept.Name -contains '0.2.1-x86_64-pc-windows-msvc')) 'third non-active release was retained'

    # Test adapters prove PATH, process, and Scheduled Task behavior without real machine mutation.
    $adapter = Initialize-ScenarioRoot 'behavior-adapters'
    $adapterRoot = Join-Path $adapter 'FarPilot'
    $adapterRelease = Join-Path $adapterRoot 'releases\0.2.1-x86_64-pc-windows-msvc'
    Write-TestStateFile -LocalAppData $adapter -Name 'path' -Value ([PSCustomObject]@{
        Exists = $true
        Value = "C:\Unrelated;$adapterRoot\releases\0.1.0-x86_64-pc-windows-msvc;$adapterRoot\bin"
        Kind = 'String'
        ProcessValue = "C:\Unrelated;$adapterRoot\current"
    })
    Write-TestStateFile -LocalAppData $adapter -Name 'processes' -Value @(
        [PSCustomObject]@{ Id = 101; Name = 'farpilot.exe'; ExecutablePath = "$adapterRoot\releases\0.1.0-x86_64-pc-windows-msvc\farpilot.exe"; Stopped = $false; StopOrder = 0 },
        [PSCustomObject]@{ Id = 102; Name = 'farpilot.exe'; ExecutablePath = 'C:\External\farpilot.exe'; Stopped = $false },
        [PSCustomObject]@{ Id = 103; Name = 'other.exe'; ExecutablePath = "$adapterRoot\releases\0.1.0-x86_64-pc-windows-msvc\other.exe"; Stopped = $false },
        [PSCustomObject]@{ Id = 104; Name = 'farpilot.exe'; ExecutablePath = "$adapterRoot\bin\farpilot.exe"; Stopped = $false },
        [PSCustomObject]@{ Id = 105; Name = 'farpilot.exe'; ExecutablePath = "$adapterRoot\current\farpilot.exe"; Stopped = $false },
        [PSCustomObject]@{ Id = 106; Name = 'farpilot-host-runner.exe'; ExecutablePath = "$adapterRoot\releases\0.1.0-x86_64-pc-windows-msvc\farpilot-host-runner.exe"; Stopped = $false; StopOrder = 0 },
        [PSCustomObject]@{ Id = 107; Name = 'farpilot-host-runner.exe'; ExecutablePath = 'C:\External\farpilot-host-runner.exe'; Stopped = $false },
        [PSCustomObject]@{ Id = 108; Name = 'farpilot-host-runner.exe'; ExecutablePath = "$adapterRoot\bin\farpilot-host-runner.exe"; Stopped = $false },
        [PSCustomObject]@{ Id = 109; Name = 'farpilot-host-runner.exe'; ExecutablePath = "$adapterRoot\current\farpilot-host-runner.exe"; Stopped = $false },
        [PSCustomObject]@{ Id = 110; Name = 'farpilot.exe'; ExecutablePath = "$adapterRoot\releases\0.1.0-x86_64-pc-windows-msvc\farpilot.exe"; Stopped = $false; Exited = $true }
    )
    Install-Fixture -Scenario $adapter -Package $validZip -Version '0.2.1' -EnableStartupTask | Out-Null
    $pathState = Get-TestState -LocalAppData $adapter -Name 'path'
    $pathParts = @([string]$pathState.Value -split ';')
    Assert-Equal -Expected ([IO.Path]::GetFullPath($adapterRelease).TrimEnd('\')) -Actual $pathParts[0] -Message 'active release is not first on PATH'
    Assert-True ($pathParts -contains 'C:\Unrelated') 'unrelated PATH entry was removed'
    Assert-True (-not (($pathParts -join ';') -match '0\.1\.0-x86_64')) 'stale managed release remained on PATH'
    Assert-True (-not ($pathParts -contains "$adapterRoot\bin")) 'managed bin alias remained on PATH'
    $pathBeforeReinstall = Get-Content -LiteralPath (Join-Path (Initialize-TestState $adapter) 'path.json') -Raw
    Install-Fixture -Scenario $adapter -Package $validZip -Version '0.2.1' -EnableStartupTask | Out-Null
    Assert-Equal -Expected $pathBeforeReinstall -Actual (Get-Content -LiteralPath (Join-Path (Initialize-TestState $adapter) 'path.json') -Raw) -Message 'PATH update was not idempotent'
    $processState = @(Get-TestState -LocalAppData $adapter -Name 'processes')
    Assert-True ([bool]$processState[0].Stopped) 'managed FarPilot process was not stopped'
    Assert-True (-not [bool]$processState[1].Stopped) 'external same-name process was stopped'
    Assert-True (-not [bool]$processState[2].Stopped) 'non-FarPilot process was stopped'
    Assert-True ([bool]$processState[3].Stopped) 'managed bin alias CLI process was not stopped'
    Assert-True ([bool]$processState[4].Stopped) 'managed current alias CLI process was not stopped'
    Assert-True ([bool]$processState[5].Stopped) 'managed release runner process was not stopped'
    Assert-True (-not [bool]$processState[6].Stopped) 'external same-name runner process was stopped'
    Assert-True ([bool]$processState[7].Stopped) 'managed bin alias runner process was not stopped'
    Assert-True ([bool]$processState[8].Stopped) 'managed current alias runner process was not stopped'
    Assert-True ([int]$processState[0].StopOrder -gt 0) 'managed CLI stop order was not recorded'
    Assert-True ([int]$processState[5].StopOrder -gt [int]$processState[0].StopOrder) 'runner stopped before managed CLI child'
    Assert-True (-not [bool]$processState[9].Stopped) 'already-exited managed CLI was stopped again'
    $taskState = Get-TestState -LocalAppData $adapter -Name 'task'
    Assert-True ([bool]$taskState.Exists) 'default fresh install did not create startup task'
    Assert-Equal -Expected (Join-Path $adapterRoot 'bin\farpilot-host-runner.exe') -Actual ([string]$taskState.Executable) -Message 'startup task executable is not the runner'
    Assert-Equal -Expected 'run' -Actual ([string]$taskState.Arguments) -Message 'startup task arguments are not fixed to run'
    Assert-Equal -Expected $TestCurrentUserSid -Actual ([string]$taskState.UserId) -Message 'startup task user is not the current user SID'
    Assert-Equal -Expected 'Limited' -Actual ([string]$taskState.RunLevel) -Message 'startup task run level is not limited'
    Assert-True ($null -ne $taskState.PSObject.Properties['Trigger']) 'startup task trigger was not recorded'
    Assert-Equal -Expected 'AtLogOn' -Actual ([string]$taskState.Trigger) -Message 'startup task trigger is not AtLogOn'
    Assert-True ($null -ne $taskState.PSObject.Properties['TriggerUserId']) 'startup task trigger user was not recorded'
    Assert-Equal -Expected $TestCurrentUserSid -Actual ([string]$taskState.TriggerUserId) -Message 'startup task trigger user is not current user SID'
    Assert-True ($null -ne $taskState.PSObject.Properties['LogonType']) 'startup task logon type was not recorded'
    Assert-Equal -Expected 'Interactive' -Actual ([string]$taskState.LogonType) -Message 'startup task logon type is not Interactive'

    # PID reuse/path mismatch and bounded stop timeout fail before activation.
    foreach ($processRaceCase in @('pid-path-mismatch', 'stop-timeout')) {
        $processRaceScenario = Initialize-ScenarioRoot ("process-race-" + $processRaceCase)
        Install-Fixture -Scenario $processRaceScenario -Package $packages['0.2.0'] -Version '0.2.0' | Out-Null
        $processRaceRoot = Join-Path $processRaceScenario 'FarPilot'
        $processRaceCurrent = Get-JunctionTarget (Join-Path $processRaceRoot 'current')
        $processRecord = [PSCustomObject]@{
            Id = 151
            Name = 'farpilot.exe'
            ExecutablePath = (Join-Path $processRaceCurrent 'farpilot.exe')
            Stopped = $false
        }
        if ($processRaceCase -ceq 'pid-path-mismatch') {
            $processRecord | Add-Member -NotePropertyName CurrentName -NotePropertyValue 'other.exe'
            $processRecord | Add-Member -NotePropertyName CurrentExecutablePath -NotePropertyValue 'C:\External\other.exe'
        } else {
            $processRecord | Add-Member -NotePropertyName WaitTimedOut -NotePropertyValue $true
        }
        Write-TestStateFile -LocalAppData $processRaceScenario -Name 'processes' -Value @($processRecord)
        $processRaceResult = Invoke-InstallerProcess -LocalAppData $processRaceScenario -PackagePath $validZip -Version '0.2.1' -Sha256 $validZipSha
        Assert-True ($processRaceResult.ExitCode -ne 0) "$processRaceCase unexpectedly activated"
        Assert-Equal -Expected $processRaceCurrent -Actual (Get-JunctionTarget (Join-Path $processRaceRoot 'current')) -Message "$processRaceCase changed current"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $processRaceRoot 'releases\0.2.1-x86_64-pc-windows-msvc'))) "$processRaceCase left new release"
    }

    $noTask = Initialize-ScenarioRoot 'no-startup-task'
    Install-Fixture -Scenario $noTask -Package $packages['0.2.0'] -Version '0.2.0' | Out-Null
    Assert-True (-not [bool](Get-TestState -LocalAppData $noTask -Name 'task').Exists) 'NoStartupTask created a startup task'

    # A prior running legacy CLI task is migrated to the runner and restarted after activation.
    $runningTask = Initialize-ScenarioRoot 'running-task'
    Install-Fixture -Scenario $runningTask -Package $packages['0.2.0'] -Version '0.2.0' -EnableStartupTask | Out-Null
    $runningLegacyTask = Get-TestState -LocalAppData $runningTask -Name 'task'
    $runningLegacyTask.Running = $true
    Write-TestStateFile -LocalAppData $runningTask -Name 'task' -Value $runningLegacyTask
    Install-Fixture -Scenario $runningTask -Package $validZip -Version '0.2.1' -EnableStartupTask | Out-Null
    $runningTaskState = Get-TestState -LocalAppData $runningTask -Name 'task'
    Assert-True ([bool]$runningTaskState.Running) 'prior running task was not restarted'
    Assert-Equal -Expected (Join-Path $runningTask 'FarPilot\bin\farpilot-host-runner.exe') -Actual ([string]$runningTaskState.Executable) -Message 'existing task was not updated to runner'
    Assert-Equal -Expected 'run' -Actual ([string]$runningTaskState.Arguments) -Message 'existing task arguments were not updated to run'

    # Equivalent current-user account representations normalize to the same SID.
    foreach ($equivalentIdentity in @(("DOMAIN\" + $env:USERNAME), $TestCurrentUserSid)) {
        $equivalentTaskScenario = Initialize-ScenarioRoot ("equivalent-task-identity-" + ($equivalentIdentity -replace '[^A-Za-z0-9]', '-'))
        Install-Fixture -Scenario $equivalentTaskScenario -Package $validZip -Version '0.2.1' -EnableStartupTask | Out-Null
        $equivalentTask = Get-TestState -LocalAppData $equivalentTaskScenario -Name 'task'
        $equivalentTask.UserId = $equivalentIdentity
        $equivalentTask.TriggerUserId = $equivalentIdentity
        Write-TestStateFile -LocalAppData $equivalentTaskScenario -Name 'task' -Value $equivalentTask
        $equivalentTaskResult = Invoke-InstallerProcess -LocalAppData $equivalentTaskScenario -PackagePath $validZip -Version '0.2.1' -Sha256 $validZipSha -EnableStartupTask
        Assert-Equal -Expected 0 -Actual $equivalentTaskResult.ExitCode -Message "equivalent task identity was rejected: $equivalentIdentity`n$($equivalentTaskResult.Output)"
    }

    # Existing task evidence is validated even when install-state metadata exists.
    foreach ($invalidTaskCase in @('external-executable', 'wrong-arguments', 'wrong-user', 'elevated-runlevel', 'wrong-trigger', 'wrong-trigger-user', 'wrong-logon-type')) {
        $invalidTaskScenario = Initialize-ScenarioRoot ("invalid-existing-task-" + $invalidTaskCase)
        Install-Fixture -Scenario $invalidTaskScenario -Package $validZip -Version '0.2.1' -EnableStartupTask | Out-Null
        $invalidTaskRoot = Join-Path $invalidTaskScenario 'FarPilot'
        $invalidTask = Get-TestState -LocalAppData $invalidTaskScenario -Name 'task'
        switch ($invalidTaskCase) {
            'external-executable' { $invalidTask.Executable = 'C:\External\farpilot-host-runner.exe' }
            'wrong-arguments' { $invalidTask.Arguments = 'host start' }
            'wrong-user' { $invalidTask.UserId = 'S-1-5-21-2000' }
            'elevated-runlevel' { $invalidTask.RunLevel = 'Highest' }
            'wrong-trigger' { $invalidTask.Trigger = 'AtStartup' }
            'wrong-trigger-user' { $invalidTask | Add-Member -NotePropertyName TriggerUserId -NotePropertyValue 'S-1-5-21-2000' -Force }
            'wrong-logon-type' { $invalidTask | Add-Member -NotePropertyName LogonType -NotePropertyValue 'ServiceAccount' -Force }
        }
        Write-TestStateFile -LocalAppData $invalidTaskScenario -Name 'task' -Value $invalidTask
        $invalidTaskJson = Get-Content -LiteralPath (Join-Path (Initialize-TestState $invalidTaskScenario) 'task.json') -Raw
        $invalidTaskCurrent = Get-JunctionTarget (Join-Path $invalidTaskRoot 'current')
        $invalidTaskResult = Invoke-InstallerProcess -LocalAppData $invalidTaskScenario -PackagePath $validZip -Version '0.2.1' -Sha256 $validZipSha -EnableStartupTask
        Assert-True ($invalidTaskResult.ExitCode -ne 0) "$invalidTaskCase existing task unexpectedly upgraded"
        Assert-Equal -Expected $invalidTaskJson -Actual (Get-Content -LiteralPath (Join-Path (Initialize-TestState $invalidTaskScenario) 'task.json') -Raw) -Message "$invalidTaskCase existing task changed before validation"
        Assert-Equal -Expected $invalidTaskCurrent -Actual (Get-JunctionTarget (Join-Path $invalidTaskRoot 'current')) -Message "$invalidTaskCase existing task changed current"
    }

    $invalidUninstallTask = Initialize-ScenarioRoot 'invalid-existing-task-uninstall'
    Install-Fixture -Scenario $invalidUninstallTask -Package $validZip -Version '0.2.1' -EnableStartupTask | Out-Null
    $invalidUninstallRoot = Join-Path $invalidUninstallTask 'FarPilot'
    $invalidUninstallTaskState = Get-TestState -LocalAppData $invalidUninstallTask -Name 'task'
    $invalidUninstallTaskState.Executable = 'C:\External\farpilot-host-runner.exe'
    Write-TestStateFile -LocalAppData $invalidUninstallTask -Name 'task' -Value $invalidUninstallTaskState
    $invalidUninstallTaskJson = Get-Content -LiteralPath (Join-Path (Initialize-TestState $invalidUninstallTask) 'task.json') -Raw
    $invalidUninstallCurrent = Get-JunctionTarget (Join-Path $invalidUninstallRoot 'current')
    $invalidUninstallResult = Invoke-UninstallerProcess -LocalAppData $invalidUninstallTask
    Assert-True ($invalidUninstallResult.ExitCode -ne 0) 'external existing task unexpectedly uninstalled managed state'
    Assert-Equal -Expected $invalidUninstallTaskJson -Actual (Get-Content -LiteralPath (Join-Path (Initialize-TestState $invalidUninstallTask) 'task.json') -Raw) -Message 'external existing task changed during rejected uninstall'
    Assert-Equal -Expected $invalidUninstallCurrent -Actual (Get-JunctionTarget (Join-Path $invalidUninstallRoot 'current')) -Message 'external existing task uninstall changed current'

    # Injected failures after each activation boundary restore all prior observable state.
    foreach ($failurePoint in @('DuringPathStateCapture', 'DuringManagedProcessStop', 'AfterCurrentJunction', 'AfterBinJunction', 'AfterPathUpdate', 'DuringTaskUpdate', 'DuringTaskStart')) {
        $transaction = Initialize-ScenarioRoot ("transaction-" + $failurePoint)
        Install-Fixture -Scenario $transaction -Package $packages['0.2.0'] -Version '0.2.0' -EnableStartupTask | Out-Null
        $transactionRoot = Join-Path $transaction 'FarPilot'
        'identity-sentinel' | Set-Content -LiteralPath (Join-Path $transactionRoot 'host-identity.json')
        'config-sentinel' | Set-Content -LiteralPath (Join-Path $transactionRoot 'host.json')
        $priorTask = Get-TestState -LocalAppData $transaction -Name 'task'
        $priorTask.Running = $true
        Write-TestStateFile -LocalAppData $transaction -Name 'task' -Value $priorTask
        $priorCurrent = Get-JunctionTarget (Join-Path $transactionRoot 'current')
        $priorBin = Get-JunctionTarget (Join-Path $transactionRoot 'bin')
        $priorPathJson = Get-Content -LiteralPath (Join-Path (Initialize-TestState $transaction) 'path.json') -Raw
        $priorTaskJson = Get-Content -LiteralPath (Join-Path (Initialize-TestState $transaction) 'task.json') -Raw
        $failure = Invoke-InstallerProcess -LocalAppData $transaction -PackagePath $validZip -Version '0.2.1' -Sha256 (Get-FileHash -Algorithm SHA256 $validZip).Hash -EnableStartupTask -FailAfter $failurePoint
        Assert-True ($failure.ExitCode -ne 0) "$failurePoint unexpectedly succeeded"
        Assert-Equal -Expected $priorCurrent -Actual (Get-JunctionTarget (Join-Path $transactionRoot 'current')) -Message "$failurePoint did not restore current"
        Assert-Equal -Expected $priorBin -Actual (Get-JunctionTarget (Join-Path $transactionRoot 'bin')) -Message "$failurePoint did not restore bin"
        Assert-Equal -Expected $priorPathJson -Actual (Get-Content -LiteralPath (Join-Path (Initialize-TestState $transaction) 'path.json') -Raw) -Message "$failurePoint did not restore PATH"
        Assert-Equal -Expected $priorTaskJson -Actual (Get-Content -LiteralPath (Join-Path (Initialize-TestState $transaction) 'task.json') -Raw) -Message "$failurePoint did not restore task"
        Assert-True ([bool](Get-TestState -LocalAppData $transaction -Name 'task').Running) "$failurePoint did not keep the prior Host task running"
        Assert-Equal -Expected 'identity-sentinel' -Actual (Get-Content -LiteralPath (Join-Path $transactionRoot 'host-identity.json') -Raw).Trim() -Message "$failurePoint changed identity"
        Assert-Equal -Expected 'config-sentinel' -Actual (Get-Content -LiteralPath (Join-Path $transactionRoot 'host.json') -Raw).Trim() -Message "$failurePoint changed config"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $transactionRoot 'releases\0.2.1-x86_64-pc-windows-msvc'))) "$failurePoint left new release"
        $transactionArtifacts = @(Get-ChildItem -LiteralPath $transactionRoot -Force -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\.(staging|backup|legacy)\.' })
        Assert-Equal -Expected 0 -Actual $transactionArtifacts.Count -Message "$failurePoint left transaction artifacts"
    }

    # A started runner must report fresh online status or the complete activation rolls back.
    $onlineRollback = Initialize-ScenarioRoot 'online-deadline-rollback'
    Install-Fixture -Scenario $onlineRollback -Package $packages['0.2.0'] -Version '0.2.0' -EnableStartupTask | Out-Null
    $onlineRollbackRoot = Join-Path $onlineRollback 'FarPilot'
    $onlinePriorTask = Get-TestState -LocalAppData $onlineRollback -Name 'task'
    $onlinePriorTask.Running = $true
    Write-TestStateFile -LocalAppData $onlineRollback -Name 'task' -Value $onlinePriorTask
    Write-TestStateFile -LocalAppData $onlineRollback -Name 'online' -Value ([PSCustomObject]@{ Online = $false })
    $onlinePriorCurrent = Get-JunctionTarget (Join-Path $onlineRollbackRoot 'current')
    $onlinePriorBin = Get-JunctionTarget (Join-Path $onlineRollbackRoot 'bin')
    $onlinePriorPathJson = Get-Content -LiteralPath (Join-Path (Initialize-TestState $onlineRollback) 'path.json') -Raw
    $onlinePriorTaskJson = Get-Content -LiteralPath (Join-Path (Initialize-TestState $onlineRollback) 'task.json') -Raw
    $onlineFailure = Invoke-InstallerProcess -LocalAppData $onlineRollback -PackagePath $validZip -Version '0.2.1' -Sha256 $validZipSha -EnableStartupTask
    Assert-True ($onlineFailure.ExitCode -ne 0) 'offline managed Host unexpectedly committed activation'
    Assert-Equal -Expected $onlinePriorCurrent -Actual (Get-JunctionTarget (Join-Path $onlineRollbackRoot 'current')) -Message 'online deadline did not restore current'
    Assert-Equal -Expected $onlinePriorBin -Actual (Get-JunctionTarget (Join-Path $onlineRollbackRoot 'bin')) -Message 'online deadline did not restore bin'
    Assert-Equal -Expected $onlinePriorPathJson -Actual (Get-Content -LiteralPath (Join-Path (Initialize-TestState $onlineRollback) 'path.json') -Raw) -Message 'online deadline did not restore PATH'
    Assert-Equal -Expected $onlinePriorTaskJson -Actual (Get-Content -LiteralPath (Join-Path (Initialize-TestState $onlineRollback) 'task.json') -Raw) -Message 'online deadline did not restore task'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $onlineRollbackRoot 'releases\0.2.1-x86_64-pc-windows-msvc'))) 'online deadline left failed release'

    # Cleanup failure after commit keeps the healthy new activation and exits successfully with a warning.
    $cleanup = Initialize-ScenarioRoot 'cleanup-incomplete'
    $cleanupRoot = Join-Path $cleanup 'FarPilot'
    $cleanupBin = Join-Path $cleanupRoot 'bin'
    New-Item -ItemType Directory -Force -Path $cleanupBin | Out-Null
    Copy-Item -LiteralPath $packages['0.2.0'] -Destination (Join-Path $cleanupBin 'farpilot.exe')
    'identity-sentinel' | Set-Content -LiteralPath (Join-Path $cleanupRoot 'host-identity.json')
    'config-sentinel' | Set-Content -LiteralPath (Join-Path $cleanupRoot 'host.json')
    $cleanupResult = Invoke-InstallerProcess -LocalAppData $cleanup -PackagePath $packages['0.2.1'] -Version '0.2.1' -Sha256 (Get-FileHash -Algorithm SHA256 $packages['0.2.1']).Hash -FailAfter 'DuringCleanup'
    Assert-Equal -Expected 0 -Actual $cleanupResult.ExitCode -Message "cleanup failure rolled back healthy activation: $($cleanupResult.Output)"
    Assert-True ($cleanupResult.Output -match 'installed successfully; cleanup incomplete') 'cleanup failure warning was not reported'
    $cleanupRelease = Join-Path $cleanupRoot 'releases\0.2.1-x86_64-pc-windows-msvc'
    Assert-Equal -Expected ([IO.Path]::GetFullPath($cleanupRelease).TrimEnd('\')) -Actual (Get-JunctionTarget (Join-Path $cleanupRoot 'current')) -Message 'cleanup failure changed current activation'
    Assert-Equal -Expected ([IO.Path]::GetFullPath($cleanupRelease).TrimEnd('\')) -Actual (Get-JunctionTarget (Join-Path $cleanupRoot 'bin')) -Message 'cleanup failure changed bin activation'
    $cleanupPath = Get-TestState -LocalAppData $cleanup -Name 'path'
    $cleanupCanonicalRelease = [IO.Path]::GetFullPath($cleanupRelease).TrimEnd('\')
    Assert-True ([string]$cleanupPath.Value -like "$cleanupCanonicalRelease*") 'cleanup failure did not commit PATH'
    Assert-Equal -Expected 'identity-sentinel' -Actual (Get-Content -LiteralPath (Join-Path $cleanupRoot 'host-identity.json') -Raw).Trim() -Message 'cleanup failure changed identity'
    Assert-Equal -Expected 'config-sentinel' -Actual (Get-Content -LiteralPath (Join-Path $cleanupRoot 'host.json') -Raw).Trim() -Message 'cleanup failure changed config'
    $cleanupBackups = @(Get-ChildItem -LiteralPath $cleanupRoot -Directory -Force | Where-Object { $_.Name -like 'bin.legacy.*' })
    Assert-Equal -Expected 1 -Actual $cleanupBackups.Count -Message 'cleanup failure did not leave the safe legacy backup for retry'

    # Default uninstall removes only managed executable state and preserves identity/config/unrelated state.
    $uninstall = Initialize-ScenarioRoot 'uninstall-default'
    Install-Fixture -Scenario $uninstall -Package $validZip -Version '0.2.1' -EnableStartupTask | Out-Null
    $uninstallRoot = Join-Path $uninstall 'FarPilot'
    'identity-sentinel' | Set-Content -LiteralPath (Join-Path $uninstallRoot 'host-identity.json')
    'config-sentinel' | Set-Content -LiteralPath (Join-Path $uninstallRoot 'host.json')
    'unrelated-sentinel' | Set-Content -LiteralPath (Join-Path $uninstallRoot 'user-notes.txt')
    $runtime = Join-Path $uninstallRoot 'runtime'
    New-Item -ItemType Directory -Path $runtime | Out-Null
    foreach ($runtimeFile in @('host-status.json', 'runner-status.json', 'host.log', 'host.log.1', 'host.log.2')) {
        'runtime-sentinel' | Set-Content -LiteralPath (Join-Path $runtime $runtimeFile)
    }
    Write-TestStateFile -LocalAppData $uninstall -Name 'processes' -Value @(
        [PSCustomObject]@{ Id = 201; Name = 'farpilot.exe'; ExecutablePath = "$uninstallRoot\releases\0.2.1-x86_64-pc-windows-msvc\farpilot.exe"; Stopped = $false },
        [PSCustomObject]@{ Id = 202; Name = 'farpilot.exe'; ExecutablePath = 'C:\External\farpilot.exe'; Stopped = $false },
        [PSCustomObject]@{ Id = 203; Name = 'farpilot-host-runner.exe'; ExecutablePath = "$uninstallRoot\releases\0.2.1-x86_64-pc-windows-msvc\farpilot-host-runner.exe"; Stopped = $false },
        [PSCustomObject]@{ Id = 204; Name = 'farpilot-host-runner.exe'; ExecutablePath = 'C:\External\farpilot-host-runner.exe'; Stopped = $false }
    )
    $defaultUninstall = Invoke-UninstallerProcess -LocalAppData $uninstall
    Assert-Equal -Expected 0 -Actual $defaultUninstall.ExitCode -Message "default uninstall failed: $($defaultUninstall.Output)"
    Assert-True ($defaultUninstall.Output -match '(?i)revoke') 'default uninstall omitted Gateway revocation warning'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $uninstallRoot 'current'))) 'default uninstall left current junction'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $uninstallRoot 'bin'))) 'default uninstall left bin junction'
    $remainingReleases = @()
    if (Test-Path -LiteralPath (Join-Path $uninstallRoot 'releases')) {
        $remainingReleases = @(Get-ChildItem -LiteralPath (Join-Path $uninstallRoot 'releases') -Force)
    }
    Assert-Equal -Expected 0 -Actual $remainingReleases.Count -Message 'default uninstall left release files'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $uninstallRoot 'install.lock'))) 'default uninstall left install lock'
    Assert-True (-not (Test-Path -LiteralPath $runtime)) 'default uninstall left managed runtime logs or status'
    Assert-Equal -Expected 'identity-sentinel' -Actual (Get-Content -LiteralPath (Join-Path $uninstallRoot 'host-identity.json') -Raw).Trim() -Message 'default uninstall removed identity'
    Assert-Equal -Expected 'config-sentinel' -Actual (Get-Content -LiteralPath (Join-Path $uninstallRoot 'host.json') -Raw).Trim() -Message 'default uninstall removed config'
    Assert-Equal -Expected 'unrelated-sentinel' -Actual (Get-Content -LiteralPath (Join-Path $uninstallRoot 'user-notes.txt') -Raw).Trim() -Message 'default uninstall removed unrelated state'
    $uninstallProcesses = @(Get-TestState -LocalAppData $uninstall -Name 'processes')
    Assert-True ([bool]$uninstallProcesses[0].Stopped) 'default uninstall did not stop managed CLI process'
    Assert-True (-not [bool]$uninstallProcesses[1].Stopped) 'default uninstall stopped external CLI process'
    Assert-True ([bool]$uninstallProcesses[2].Stopped) 'default uninstall did not stop managed runner process'
    Assert-True (-not [bool]$uninstallProcesses[3].Stopped) 'default uninstall stopped external runner process'
    Assert-True (-not [bool](Get-TestState -LocalAppData $uninstall -Name 'task').Exists) 'default uninstall left managed task'
    $uninstallPath = Get-TestState -LocalAppData $uninstall -Name 'path'
    Assert-Equal -Expected 'C:\Unrelated' -Actual ([string]$uninstallPath.Value) -Message 'default uninstall did not restore unrelated-only user PATH'

    # Repeated uninstall is idempotent and keeps preserved state.
    $secondUninstall = Invoke-UninstallerProcess -LocalAppData $uninstall
    Assert-Equal -Expected 0 -Actual $secondUninstall.ExitCode -Message "repeated uninstall failed: $($secondUninstall.Output)"
    Assert-Equal -Expected 'identity-sentinel' -Actual (Get-Content -LiteralPath (Join-Path $uninstallRoot 'host-identity.json') -Raw).Trim() -Message 'repeated uninstall removed identity'

    # Install, upgrade, and uninstall removes every managed release while retaining state.
    $upgradeUninstall = Initialize-ScenarioRoot 'uninstall-after-upgrade'
    Install-Fixture -Scenario $upgradeUninstall -Package $packages['0.2.0'] -Version '0.2.0' | Out-Null
    Install-Fixture -Scenario $upgradeUninstall -Package $packages['0.2.1'] -Version '0.2.1' | Out-Null
    $upgradeRoot = Join-Path $upgradeUninstall 'FarPilot'
    'identity-upgrade' | Set-Content -LiteralPath (Join-Path $upgradeRoot 'host-identity.json')
    'config-upgrade' | Set-Content -LiteralPath (Join-Path $upgradeRoot 'host.json')
    $upgradeUninstallResult = Invoke-UninstallerProcess -LocalAppData $upgradeUninstall
    Assert-Equal -Expected 0 -Actual $upgradeUninstallResult.ExitCode -Message "upgrade uninstall failed: $($upgradeUninstallResult.Output)"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $upgradeRoot 'current'))) 'upgrade uninstall left current'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $upgradeRoot 'bin'))) 'upgrade uninstall left bin'
    Assert-Equal -Expected 'identity-upgrade' -Actual (Get-Content -LiteralPath (Join-Path $upgradeRoot 'host-identity.json') -Raw).Trim() -Message 'upgrade uninstall removed identity'
    Assert-Equal -Expected 'config-upgrade' -Actual (Get-Content -LiteralPath (Join-Path $upgradeRoot 'host.json') -Raw).Trim() -Message 'upgrade uninstall removed config'

    # A custom visible bin is persisted, upgraded, and removed without touching default/unrelated paths.
    $customInstall = Initialize-ScenarioRoot 'custom-install-dir'
    $customBin = Join-Path $customInstall 'Visible FarPilot Bin'
    $customSibling = Join-Path $customInstall 'unrelated-sibling'
    New-Item -ItemType Directory -Path $customSibling | Out-Null
    'sibling-sentinel' | Set-Content -LiteralPath (Join-Path $customSibling 'keep.txt')
    Install-Fixture -Scenario $customInstall -Package $packages['0.2.0'] -Version '0.2.0' -InstallDir $customBin | Out-Null
    Install-Fixture -Scenario $customInstall -Package $packages['0.2.1'] -Version '0.2.1' -InstallDir $customBin | Out-Null
    $customRoot = Join-Path $customInstall 'FarPilot'
    $customState = Get-Content -LiteralPath (Join-Path $customRoot 'install-state.json') -Raw | ConvertFrom-Json
    Assert-Equal -Expected ([IO.Path]::GetFullPath($customBin).TrimEnd('\')) -Actual ([string]$customState.visible_bin) -Message 'custom visible bin was not persisted'
    $customCurrentBeforeHint = Get-JunctionTarget (Join-Path $customRoot 'current')
    $unnecessaryHint = Invoke-UninstallerProcess -LocalAppData $customInstall -LegacyInstallDir $customBin
    Assert-True ($unnecessaryHint.ExitCode -ne 0) 'InstallDir hint with metadata unexpectedly succeeded'
    Assert-Equal -Expected $customCurrentBeforeHint -Actual (Get-JunctionTarget (Join-Path $customRoot 'current')) -Message 'unnecessary InstallDir hint mutated current'
    $customStateArtifacts = @(Get-ChildItem -LiteralPath $customRoot -Force | Where-Object { $_.Name -like '.install-state.*' })
    Assert-Equal -Expected 0 -Actual $customStateArtifacts.Count -Message 'custom upgrade left install-state temp or backup artifacts'
    $defaultBin = Join-Path $customRoot 'bin'
    New-Item -ItemType Directory -Path $defaultBin | Out-Null
    'default-bin-sentinel' | Set-Content -LiteralPath (Join-Path $defaultBin 'keep.txt')
    $customUninstall = Invoke-UninstallerProcess -LocalAppData $customInstall
    Assert-Equal -Expected 0 -Actual $customUninstall.ExitCode -Message "custom uninstall failed: $($customUninstall.Output)"
    Assert-True (-not (Test-Path -LiteralPath $customBin)) 'custom visible bin junction remained after uninstall'
    Assert-Equal -Expected 'sibling-sentinel' -Actual (Get-Content -LiteralPath (Join-Path $customSibling 'keep.txt') -Raw).Trim() -Message 'custom uninstall changed unrelated sibling'
    Assert-Equal -Expected 'default-bin-sentinel' -Actual (Get-Content -LiteralPath (Join-Path $defaultBin 'keep.txt') -Raw).Trim() -Message 'custom uninstall removed unrelated default bin'

    # Legacy custom installs without metadata discover their visible bin from the managed task.
    $legacyCustom = Initialize-ScenarioRoot 'legacy-custom-install-dir'
    $legacyCustomBin = Join-Path $legacyCustom 'legacy-visible-bin'
    $legacyDefaultBin = Join-Path $legacyCustom 'FarPilot\bin'
    Install-Fixture -Scenario $legacyCustom -Package $packages['0.2.0'] -Version '0.2.0' -InstallDir $legacyCustomBin -EnableStartupTask | Out-Null
    Remove-Item -LiteralPath (Join-Path $legacyCustom 'FarPilot\install-state.json') -Force
    New-Item -ItemType Directory -Path $legacyDefaultBin | Out-Null
    'legacy-default-sentinel' | Set-Content -LiteralPath (Join-Path $legacyDefaultBin 'keep.txt')
    $legacyCustomUninstall = Invoke-UninstallerProcess -LocalAppData $legacyCustom
    Assert-Equal -Expected 0 -Actual $legacyCustomUninstall.ExitCode -Message "legacy custom uninstall failed: $($legacyCustomUninstall.Output)"
    Assert-True (-not (Test-Path -LiteralPath $legacyCustomBin)) 'legacy custom visible bin remained after uninstall'
    Assert-Equal -Expected 'legacy-default-sentinel' -Actual (Get-Content -LiteralPath (Join-Path $legacyDefaultBin 'keep.txt') -Raw).Trim() -Message 'legacy custom uninstall removed unrelated default bin'

    # A no-task legacy custom install can be recovered only with a validated InstallDir hint.
    $legacyHint = Initialize-ScenarioRoot 'legacy-custom-hint'
    $legacyHintBin = Join-Path $legacyHint 'hint-visible-bin'
    Install-Fixture -Scenario $legacyHint -Package $packages['0.2.0'] -Version '0.2.0' -InstallDir $legacyHintBin | Out-Null
    $legacyHintRoot = Join-Path $legacyHint 'FarPilot'
    Remove-Item -LiteralPath (Join-Path $legacyHintRoot 'install-state.json') -Force
    $legacyHintResult = Invoke-UninstallerProcess -LocalAppData $legacyHint -LegacyInstallDir $legacyHintBin
    Assert-Equal -Expected 0 -Actual $legacyHintResult.ExitCode -Message "legacy InstallDir hint uninstall failed: $($legacyHintResult.Output)"
    Assert-True (-not (Test-Path -LiteralPath $legacyHintBin)) 'legacy InstallDir hint left custom junction'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $legacyHintRoot 'releases'))) 'legacy InstallDir hint left releases'

    # An external/non-junction InstallDir hint is rejected before mutation.
    $maliciousHint = Initialize-ScenarioRoot 'legacy-malicious-hint'
    $managedHintBin = Join-Path $maliciousHint 'managed-hint-bin'
    Install-Fixture -Scenario $maliciousHint -Package $packages['0.2.0'] -Version '0.2.0' -InstallDir $managedHintBin | Out-Null
    $maliciousHintRoot = Join-Path $maliciousHint 'FarPilot'
    Remove-Item -LiteralPath (Join-Path $maliciousHintRoot 'install-state.json') -Force
    $externalHint = Join-Path $maliciousHint 'external-hint'
    New-Item -ItemType Directory -Path $externalHint | Out-Null
    'external-hint-sentinel' | Set-Content -LiteralPath (Join-Path $externalHint 'keep.txt')
    $maliciousHintPathJson = Get-Content -LiteralPath (Join-Path (Initialize-TestState $maliciousHint) 'path.json') -Raw
    $maliciousHintCurrent = Get-JunctionTarget (Join-Path $maliciousHintRoot 'current')
    $maliciousHintResult = Invoke-UninstallerProcess -LocalAppData $maliciousHint -LegacyInstallDir $externalHint
    Assert-True ($maliciousHintResult.ExitCode -ne 0) 'external InstallDir hint unexpectedly uninstalled'
    Assert-Equal -Expected $maliciousHintCurrent -Actual (Get-JunctionTarget (Join-Path $maliciousHintRoot 'current')) -Message 'external InstallDir hint changed current'
    Assert-Equal -Expected $maliciousHintPathJson -Actual (Get-Content -LiteralPath (Join-Path (Initialize-TestState $maliciousHint) 'path.json') -Raw) -Message 'external InstallDir hint changed PATH'
    Assert-Equal -Expected 'external-hint-sentinel' -Actual (Get-Content -LiteralPath (Join-Path $externalHint 'keep.txt') -Raw).Trim() -Message 'external InstallDir hint changed external state'

    # A legacy task that points outside a managed junction is rejected before mutation.
    $maliciousTask = Initialize-ScenarioRoot 'legacy-external-task'
    Install-Fixture -Scenario $maliciousTask -Package $packages['0.2.0'] -Version '0.2.0' -EnableStartupTask | Out-Null
    $maliciousRoot = Join-Path $maliciousTask 'FarPilot'
    Remove-Item -LiteralPath (Join-Path $maliciousRoot 'install-state.json') -Force
    $externalTaskDir = Join-Path $maliciousTask 'external-task-bin'
    New-Item -ItemType Directory -Path $externalTaskDir | Out-Null
    'external-task-sentinel' | Set-Content -LiteralPath (Join-Path $externalTaskDir 'farpilot.exe')
    $maliciousTaskState = Get-TestState -LocalAppData $maliciousTask -Name 'task'
    $maliciousTaskState.Executable = Join-Path $externalTaskDir 'farpilot.exe'
    $maliciousTaskState.Running = $true
    Write-TestStateFile -LocalAppData $maliciousTask -Name 'task' -Value $maliciousTaskState
    $maliciousTaskJson = Get-Content -LiteralPath (Join-Path (Initialize-TestState $maliciousTask) 'task.json') -Raw
    $maliciousPathJson = Get-Content -LiteralPath (Join-Path (Initialize-TestState $maliciousTask) 'path.json') -Raw
    $maliciousCurrent = Get-JunctionTarget (Join-Path $maliciousRoot 'current')
    $maliciousResult = Invoke-UninstallerProcess -LocalAppData $maliciousTask
    Assert-True ($maliciousResult.ExitCode -ne 0) 'external legacy task path unexpectedly uninstalled'
    Assert-Equal -Expected $maliciousCurrent -Actual (Get-JunctionTarget (Join-Path $maliciousRoot 'current')) -Message 'external legacy task changed current'
    Assert-Equal -Expected $maliciousTaskJson -Actual (Get-Content -LiteralPath (Join-Path (Initialize-TestState $maliciousTask) 'task.json') -Raw) -Message 'external legacy task changed task'
    Assert-Equal -Expected $maliciousPathJson -Actual (Get-Content -LiteralPath (Join-Path (Initialize-TestState $maliciousTask) 'path.json') -Raw) -Message 'external legacy task changed PATH'
    Assert-Equal -Expected 'external-task-sentinel' -Actual (Get-Content -LiteralPath (Join-Path $externalTaskDir 'farpilot.exe') -Raw).Trim() -Message 'external legacy task target changed'

    # Corrupt/external install metadata fails before task, PATH, alias, or release mutation.
    $corruptState = Initialize-ScenarioRoot 'corrupt-install-state'
    $corruptBin = Join-Path $corruptState 'managed-custom-bin'
    Install-Fixture -Scenario $corruptState -Package $packages['0.2.0'] -Version '0.2.0' -InstallDir $corruptBin -EnableStartupTask | Out-Null
    $corruptRoot = Join-Path $corruptState 'FarPilot'
    $externalMetadataTarget = Join-Path $corruptState 'external-unmanaged-bin'
    New-Item -ItemType Directory -Path $externalMetadataTarget | Out-Null
    'external-state' | Set-Content -LiteralPath (Join-Path $externalMetadataTarget 'keep.txt')
    [PSCustomObject]@{ schema_version = 1; visible_bin = $externalMetadataTarget } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $corruptRoot 'install-state.json') -Encoding UTF8
    $corruptTask = Get-TestState -LocalAppData $corruptState -Name 'task'
    $corruptTask.Running = $true
    Write-TestStateFile -LocalAppData $corruptState -Name 'task' -Value $corruptTask
    $corruptTaskJson = Get-Content -LiteralPath (Join-Path (Initialize-TestState $corruptState) 'task.json') -Raw
    $corruptPathJson = Get-Content -LiteralPath (Join-Path (Initialize-TestState $corruptState) 'path.json') -Raw
    $corruptCurrent = Get-JunctionTarget (Join-Path $corruptRoot 'current')
    $corruptUninstall = Invoke-UninstallerProcess -LocalAppData $corruptState
    Assert-True ($corruptUninstall.ExitCode -ne 0) 'corrupt install-state unexpectedly uninstalled'
    Assert-Equal -Expected $corruptCurrent -Actual (Get-JunctionTarget (Join-Path $corruptRoot 'current')) -Message 'corrupt install-state changed current'
    Assert-Equal -Expected $corruptTaskJson -Actual (Get-Content -LiteralPath (Join-Path (Initialize-TestState $corruptState) 'task.json') -Raw) -Message 'corrupt install-state changed task'
    Assert-Equal -Expected $corruptPathJson -Actual (Get-Content -LiteralPath (Join-Path (Initialize-TestState $corruptState) 'path.json') -Raw) -Message 'corrupt install-state changed PATH'
    Assert-Equal -Expected 'external-state' -Actual (Get-Content -LiteralPath (Join-Path $externalMetadataTarget 'keep.txt') -Raw).Trim() -Message 'corrupt install-state touched external target'

    # Failed atomic install-state replacement preserves the previous metadata and activation.
    $stateRollback = Initialize-ScenarioRoot 'install-state-replace-failure'
    Install-Fixture -Scenario $stateRollback -Package $packages['0.2.0'] -Version '0.2.0' | Out-Null
    $stateRollbackRoot = Join-Path $stateRollback 'FarPilot'
    $statePath = Join-Path $stateRollbackRoot 'install-state.json'
    $stateHashBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $statePath).Hash
    $stateCurrentBefore = Get-JunctionTarget (Join-Path $stateRollbackRoot 'current')
    $stateFailure = Invoke-InstallerProcess -LocalAppData $stateRollback -PackagePath $packages['0.2.1'] -Version '0.2.1' -Sha256 (Get-FileHash -Algorithm SHA256 $packages['0.2.1']).Hash -FailAfter 'DuringInstallStateReplace'
    Assert-True ($stateFailure.ExitCode -ne 0) 'install-state replacement failure unexpectedly succeeded'
    Assert-Equal -Expected $stateHashBefore -Actual (Get-FileHash -Algorithm SHA256 -LiteralPath $statePath).Hash -Message 'install-state replacement failure changed prior metadata'
    Assert-Equal -Expected $stateCurrentBefore -Actual (Get-JunctionTarget (Join-Path $stateRollbackRoot 'current')) -Message 'install-state replacement failure changed current'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $stateRollbackRoot 'releases\0.2.1-x86_64-pc-windows-msvc'))) 'install-state replacement failure left new release'
    $stateFailureArtifacts = @(Get-ChildItem -LiteralPath $stateRollbackRoot -Force | Where-Object { $_.Name -like '.install-state.*' })
    Assert-Equal -Expected 0 -Actual $stateFailureArtifacts.Count -Message 'install-state replacement failure left temp or backup artifacts'

    # Purge mode validation fails before mutation when Uninstall or confirmation is missing.
    $purgeValidation = Initialize-ScenarioRoot 'purge-validation'
    Install-Fixture -Scenario $purgeValidation -Package $packages['0.2.0'] -Version '0.2.0' | Out-Null
    $purgeRoot = Join-Path $purgeValidation 'FarPilot'
    'identity-purge' | Set-Content -LiteralPath (Join-Path $purgeRoot 'host-identity.json')
    'config-purge' | Set-Content -LiteralPath (Join-Path $purgeRoot 'host.json')
    $purgeWithoutUninstall = Invoke-RawInstallerProcess -LocalAppData $purgeValidation -InstallerArguments @('-PurgeState', '-TestStateDirectory', (Initialize-TestState $purgeValidation))
    Assert-True ($purgeWithoutUninstall.ExitCode -ne 0) 'PurgeState without Uninstall unexpectedly succeeded'
    Assert-True (Test-Path -LiteralPath (Join-Path $purgeRoot 'current')) 'PurgeState without Uninstall mutated install'
    $purgeWithoutConfirmation = Invoke-UninstallerProcess -LocalAppData $purgeValidation -PurgeState
    Assert-True ($purgeWithoutConfirmation.ExitCode -ne 0) 'PurgeState without confirmation unexpectedly succeeded'
    Assert-Equal -Expected 'identity-purge' -Actual (Get-Content -LiteralPath (Join-Path $purgeRoot 'host-identity.json') -Raw).Trim() -Message 'unconfirmed purge removed identity'
    $unguardedConfirmation = Invoke-UnguardedPurgeConfirmation -LocalAppData $purgeValidation
    Assert-True ($unguardedConfirmation.ExitCode -ne 0) 'ConfirmPurge outside guarded test mode unexpectedly succeeded'
    Assert-True (Test-Path -LiteralPath (Join-Path $purgeRoot 'host.json')) 'unguarded ConfirmPurge removed state'

    # Guarded confirmed purge removes only known state and preserves unknown files for review.
    $confirmedPurge = Initialize-ScenarioRoot 'purge-confirmed'
    Install-Fixture -Scenario $confirmedPurge -Package $packages['0.2.0'] -Version '0.2.0' | Out-Null
    $confirmedRoot = Join-Path $confirmedPurge 'FarPilot'
    'identity-confirmed' | Set-Content -LiteralPath (Join-Path $confirmedRoot 'host-identity.json')
    'config-confirmed' | Set-Content -LiteralPath (Join-Path $confirmedRoot 'host.json')
    'legacy-config-confirmed' | Set-Content -LiteralPath (Join-Path $confirmedRoot 'host-config.json')
    'preserve-unknown' | Set-Content -LiteralPath (Join-Path $confirmedRoot 'operator-note.txt')
    $confirmedResult = Invoke-UninstallerProcess -LocalAppData $confirmedPurge -PurgeState -PurgeConfirmation 'PURGE FARPILOT STATE'
    Assert-Equal -Expected 0 -Actual $confirmedResult.ExitCode -Message "confirmed purge failed: $($confirmedResult.Output)"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $confirmedRoot 'host-identity.json'))) 'confirmed purge left identity'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $confirmedRoot 'host.json'))) 'confirmed purge left config'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $confirmedRoot 'host-config.json'))) 'confirmed purge left legacy config'
    Assert-Equal -Expected 'preserve-unknown' -Actual (Get-Content -LiteralPath (Join-Path $confirmedRoot 'operator-note.txt') -Raw).Trim() -Message 'confirmed purge removed unknown state'
    Assert-True ($confirmedResult.Output -match 'operator-note') 'confirmed purge did not report preserved unknown state'

    # Sensitive purge cleanup failure is nonzero and retains recoverable quarantined state.
    $purgeCleanupFailure = Initialize-ScenarioRoot 'purge-cleanup-incomplete'
    Install-Fixture -Scenario $purgeCleanupFailure -Package $packages['0.2.0'] -Version '0.2.0' | Out-Null
    $purgeCleanupRoot = Join-Path $purgeCleanupFailure 'FarPilot'
    'purge-cleanup-identity' | Set-Content -LiteralPath (Join-Path $purgeCleanupRoot 'host-identity.json')
    'purge-cleanup-config' | Set-Content -LiteralPath (Join-Path $purgeCleanupRoot 'host.json')
    'purge-cleanup-unknown' | Set-Content -LiteralPath (Join-Path $purgeCleanupRoot 'operator-note.txt')
    $purgeCleanupResult = Invoke-UninstallerProcess -LocalAppData $purgeCleanupFailure -PurgeState -PurgeConfirmation 'PURGE FARPILOT STATE' -FailAfter 'DuringPurgeCleanup'
    Assert-True ($purgeCleanupResult.ExitCode -ne 0) 'sensitive purge cleanup failure unexpectedly succeeded'
    Assert-True ($purgeCleanupResult.Output -match 'purge incomplete') 'sensitive purge cleanup failure omitted purge-incomplete error'
    Assert-True ($purgeCleanupResult.Output -notmatch 'FarPilot uninstall completed\.') 'sensitive purge cleanup failure printed false success'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $purgeCleanupRoot 'host-identity.json'))) 'sensitive purge cleanup failure restored live identity path'
    $identityQuarantine = @(Get-ChildItem -LiteralPath $purgeCleanupRoot -Force | Where-Object { $_.Name -like '.farpilot-uninstall.*.host-identity.json' })
    Assert-Equal -Expected 1 -Actual $identityQuarantine.Count -Message 'sensitive identity quarantine was not retained exactly once'
    Assert-Equal -Expected 'purge-cleanup-identity' -Actual (Get-Content -LiteralPath $identityQuarantine[0].FullName -Raw).Trim() -Message 'retained identity quarantine content changed'
    Assert-True ($purgeCleanupResult.Output -match [regex]::Escape($identityQuarantine[0].FullName)) 'purge-incomplete error omitted retained sensitive path'
    Assert-Equal -Expected 'purge-cleanup-unknown' -Actual (Get-Content -LiteralPath (Join-Path $purgeCleanupRoot 'operator-note.txt') -Raw).Trim() -Message 'sensitive purge cleanup failure changed unknown state'

    # Uninstall failures stop before broader destructive cleanup.
    foreach ($failurePoint in @('DuringManagedProcessStop', 'DuringAliasQuarantine', 'DuringReleaseQuarantine', 'DuringTaskRemoval', 'DuringPathRemoval')) {
        $failedUninstall = Initialize-ScenarioRoot ("uninstall-failure-" + $failurePoint)
        Install-Fixture -Scenario $failedUninstall -Package $packages['0.2.0'] -Version '0.2.0' -EnableStartupTask | Out-Null
        $failedRoot = Join-Path $failedUninstall 'FarPilot'
        $failedRuntime = Join-Path $failedRoot 'runtime'
        New-Item -ItemType Directory -Path $failedRuntime | Out-Null
        'runtime-status-sentinel' | Set-Content -LiteralPath (Join-Path $failedRuntime 'host-status.json')
        'runtime-log-sentinel' | Set-Content -LiteralPath (Join-Path $failedRuntime 'host.log')
        $failedTask = Get-TestState -LocalAppData $failedUninstall -Name 'task'
        $failedTask.Running = $true
        Write-TestStateFile -LocalAppData $failedUninstall -Name 'task' -Value $failedTask
        $failedTaskJson = Get-Content -LiteralPath (Join-Path (Initialize-TestState $failedUninstall) 'task.json') -Raw
        $failedPathJson = Get-Content -LiteralPath (Join-Path (Initialize-TestState $failedUninstall) 'path.json') -Raw
        $failedCurrent = Get-JunctionTarget (Join-Path $failedRoot 'current')
        $failedBin = Get-JunctionTarget (Join-Path $failedRoot 'bin')
        $failure = Invoke-UninstallerProcess -LocalAppData $failedUninstall -FailAfter $failurePoint
        Assert-True ($failure.ExitCode -ne 0) "$failurePoint unexpectedly succeeded"
        Assert-Equal -Expected $failedCurrent -Actual (Get-JunctionTarget (Join-Path $failedRoot 'current')) -Message "$failurePoint removed current before safe cleanup"
        Assert-Equal -Expected $failedBin -Actual (Get-JunctionTarget (Join-Path $failedRoot 'bin')) -Message "$failurePoint removed bin before safe cleanup"
        Assert-True (Test-Path -LiteralPath (Join-Path $failedRoot 'releases\0.2.0-x86_64-pc-windows-msvc\farpilot.exe')) "$failurePoint removed releases"
        Assert-Equal -Expected $failedTaskJson -Actual (Get-Content -LiteralPath (Join-Path (Initialize-TestState $failedUninstall) 'task.json') -Raw) -Message "$failurePoint did not restore running task"
        Assert-Equal -Expected $failedPathJson -Actual (Get-Content -LiteralPath (Join-Path (Initialize-TestState $failedUninstall) 'path.json') -Raw) -Message "$failurePoint changed PATH"
        Assert-Equal -Expected 'runtime-status-sentinel' -Actual (Get-Content -LiteralPath (Join-Path $failedRuntime 'host-status.json') -Raw).Trim() -Message "$failurePoint did not restore runtime status"
        Assert-Equal -Expected 'runtime-log-sentinel' -Actual (Get-Content -LiteralPath (Join-Path $failedRuntime 'host.log') -Raw).Trim() -Message "$failurePoint did not restore runtime log"
        Assert-True ($failure.Output -match '(?i)remaining|failed') "$failurePoint did not report remaining managed state"
    }

    # Post-commit quarantine cleanup failure reports success with safe retained artifacts.
    $uninstallCleanup = Initialize-ScenarioRoot 'uninstall-cleanup-incomplete'
    Install-Fixture -Scenario $uninstallCleanup -Package $packages['0.2.0'] -Version '0.2.0' | Out-Null
    $uninstallCleanupRoot = Join-Path $uninstallCleanup 'FarPilot'
    'cleanup-identity' | Set-Content -LiteralPath (Join-Path $uninstallCleanupRoot 'host-identity.json')
    'cleanup-config' | Set-Content -LiteralPath (Join-Path $uninstallCleanupRoot 'host.json')
    $uninstallCleanupResult = Invoke-UninstallerProcess -LocalAppData $uninstallCleanup -FailAfter 'DuringUninstallCleanup'
    Assert-Equal -Expected 0 -Actual $uninstallCleanupResult.ExitCode -Message "uninstall cleanup failure rolled back committed uninstall: $($uninstallCleanupResult.Output)"
    Assert-True ($uninstallCleanupResult.Output -match 'cleanup incomplete') 'uninstall cleanup failure warning was not reported'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $uninstallCleanupRoot 'current'))) 'cleanup failure restored current after commit'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $uninstallCleanupRoot 'bin'))) 'cleanup failure restored bin after commit'
    Assert-Equal -Expected 'cleanup-identity' -Actual (Get-Content -LiteralPath (Join-Path $uninstallCleanupRoot 'host-identity.json') -Raw).Trim() -Message 'cleanup failure changed identity'
    Assert-Equal -Expected 'cleanup-config' -Actual (Get-Content -LiteralPath (Join-Path $uninstallCleanupRoot 'host.json') -Raw).Trim() -Message 'cleanup failure changed config'
    $retainedQuarantine = @(Get-ChildItem -LiteralPath $uninstallCleanup -Force -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '.farpilot-uninstall.*' })
    Assert-True ($retainedQuarantine.Count -gt 0) 'cleanup failure did not retain safe quarantine artifacts'

    # Dry-run uninstall and mixed install arguments are rejected or non-mutating by contract.
    $dryUninstall = Initialize-ScenarioRoot 'uninstall-dry-run'
    Install-Fixture -Scenario $dryUninstall -Package $packages['0.2.0'] -Version '0.2.0' | Out-Null
    $dryUninstallRoot = Join-Path $dryUninstall 'FarPilot'
    $dryCurrent = Get-JunctionTarget (Join-Path $dryUninstallRoot 'current')
    $dryUninstallResult = Invoke-UninstallerProcess -LocalAppData $dryUninstall -DryRun
    Assert-Equal -Expected 0 -Actual $dryUninstallResult.ExitCode -Message "uninstall DryRun failed: $($dryUninstallResult.Output)"
    Assert-Equal -Expected $dryCurrent -Actual (Get-JunctionTarget (Join-Path $dryUninstallRoot 'current')) -Message 'uninstall DryRun mutated current'
    $mixedMode = Invoke-UninstallerProcess -LocalAppData $dryUninstall -AdditionalArguments @('-Version', '0.2.0')
    Assert-True ($mixedMode.ExitCode -ne 0) 'Uninstall with install-only Version unexpectedly succeeded'
    Assert-Equal -Expected $dryCurrent -Actual (Get-JunctionTarget (Join-Path $dryUninstallRoot 'current')) -Message 'mixed uninstall mode mutated current'

    # Unmanaged aliases/reparse points are refused without deleting their external targets.
    $uninstallUnsafe = Initialize-ScenarioRoot 'uninstall-unsafe'
    $uninstallUnsafeRoot = Join-Path $uninstallUnsafe 'FarPilot'
    $uninstallExternal = Join-Path $uninstallUnsafe 'external-release'
    New-Item -ItemType Directory -Force -Path $uninstallExternal | Out-Null
    'external-sentinel' | Set-Content -LiteralPath (Join-Path $uninstallExternal 'keep.txt')
    New-Item -ItemType Directory -Force -Path $uninstallUnsafeRoot | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $uninstallUnsafeRoot 'current') -Target $uninstallExternal | Out-Null
    $unsafeUninstallResult = Invoke-UninstallerProcess -LocalAppData $uninstallUnsafe
    Assert-True ($unsafeUninstallResult.ExitCode -ne 0) 'uninstall followed unmanaged current junction'
    Assert-Equal -Expected 'external-sentinel' -Actual (Get-Content -LiteralPath (Join-Path $uninstallExternal 'keep.txt') -Raw).Trim() -Message 'uninstall deleted external target'

    # Unknown or reparse runtime entries are rejected before task, PATH, alias, or release mutation.
    foreach ($unsafeRuntimeCase in @('unknown-file', 'reparse-entry')) {
        $unsafeRuntimeScenario = Initialize-ScenarioRoot ("uninstall-unsafe-runtime-" + $unsafeRuntimeCase)
        Install-Fixture -Scenario $unsafeRuntimeScenario -Package $validZip -Version '0.2.1' -EnableStartupTask | Out-Null
        $unsafeRuntimeRoot = Join-Path $unsafeRuntimeScenario 'FarPilot'
        $unsafeRuntimeDir = Join-Path $unsafeRuntimeRoot 'runtime'
        New-Item -ItemType Directory -Force -Path $unsafeRuntimeDir | Out-Null
        $unsafeRuntimeExternal = $null
        if ($unsafeRuntimeCase -ceq 'unknown-file') {
            'unknown-runtime-sentinel' | Set-Content -LiteralPath (Join-Path $unsafeRuntimeDir 'operator-note.txt')
        } else {
            $unsafeRuntimeExternal = Join-Path $unsafeRuntimeScenario 'external-runtime-target'
            New-Item -ItemType Directory -Path $unsafeRuntimeExternal | Out-Null
            'external-runtime-sentinel' | Set-Content -LiteralPath (Join-Path $unsafeRuntimeExternal 'keep.txt')
            New-Item -ItemType Junction -Path (Join-Path $unsafeRuntimeDir 'host.log.1') -Target $unsafeRuntimeExternal | Out-Null
        }
        $unsafeRuntimeCurrent = Get-JunctionTarget (Join-Path $unsafeRuntimeRoot 'current')
        $unsafeRuntimeBin = Get-JunctionTarget (Join-Path $unsafeRuntimeRoot 'bin')
        $unsafeRuntimeTaskJson = Get-Content -LiteralPath (Join-Path (Initialize-TestState $unsafeRuntimeScenario) 'task.json') -Raw
        $unsafeRuntimePathJson = Get-Content -LiteralPath (Join-Path (Initialize-TestState $unsafeRuntimeScenario) 'path.json') -Raw
        $unsafeRuntimeResult = Invoke-UninstallerProcess -LocalAppData $unsafeRuntimeScenario
        Assert-True ($unsafeRuntimeResult.ExitCode -ne 0) "$unsafeRuntimeCase runtime unexpectedly uninstalled"
        Assert-Equal -Expected $unsafeRuntimeCurrent -Actual (Get-JunctionTarget (Join-Path $unsafeRuntimeRoot 'current')) -Message "$unsafeRuntimeCase runtime changed current"
        Assert-Equal -Expected $unsafeRuntimeBin -Actual (Get-JunctionTarget (Join-Path $unsafeRuntimeRoot 'bin')) -Message "$unsafeRuntimeCase runtime changed bin"
        Assert-Equal -Expected $unsafeRuntimeTaskJson -Actual (Get-Content -LiteralPath (Join-Path (Initialize-TestState $unsafeRuntimeScenario) 'task.json') -Raw) -Message "$unsafeRuntimeCase runtime changed task"
        Assert-Equal -Expected $unsafeRuntimePathJson -Actual (Get-Content -LiteralPath (Join-Path (Initialize-TestState $unsafeRuntimeScenario) 'path.json') -Raw) -Message "$unsafeRuntimeCase runtime changed PATH"
        if ($unsafeRuntimeCase -ceq 'unknown-file') {
            Assert-Equal -Expected 'unknown-runtime-sentinel' -Actual (Get-Content -LiteralPath (Join-Path $unsafeRuntimeDir 'operator-note.txt') -Raw).Trim() -Message 'unknown runtime file changed'
        } else {
            Assert-Equal -Expected 'external-runtime-sentinel' -Actual (Get-Content -LiteralPath (Join-Path $unsafeRuntimeExternal 'keep.txt') -Raw).Trim() -Message 'runtime reparse target changed'
        }
    }

    # The complete release deletion tree is preflighted before task/process/PATH mutation.
    $preflightCases = @('unmanaged-directory', 'reparse-entry', 'unknown-nested-file', 'nested-release-junction')
    foreach ($preflightCase in $preflightCases) {
        $preflight = Initialize-ScenarioRoot ("uninstall-preflight-" + $preflightCase)
        Install-Fixture -Scenario $preflight -Package $packages['0.2.0'] -Version '0.2.0' -EnableStartupTask | Out-Null
        $preflightRoot = Join-Path $preflight 'FarPilot'
        $preflightReleases = Join-Path $preflightRoot 'releases'
        $preflightTask = Get-TestState -LocalAppData $preflight -Name 'task'
        $preflightTask.Running = $true
        Write-TestStateFile -LocalAppData $preflight -Name 'task' -Value $preflightTask
        $preflightTaskJson = Get-Content -LiteralPath (Join-Path (Initialize-TestState $preflight) 'task.json') -Raw
        $preflightPathJson = Get-Content -LiteralPath (Join-Path (Initialize-TestState $preflight) 'path.json') -Raw
        $preflightCurrent = Get-JunctionTarget (Join-Path $preflightRoot 'current')
        $preflightBin = Get-JunctionTarget (Join-Path $preflightRoot 'bin')
        switch ($preflightCase) {
            'unmanaged-directory' {
                $unmanagedRelease = Join-Path $preflightReleases 'operator-data'
                New-Item -ItemType Directory -Path $unmanagedRelease | Out-Null
                'release-sentinel' | Set-Content -LiteralPath (Join-Path $unmanagedRelease 'keep.txt')
            }
            'reparse-entry' {
                $externalRelease = Join-Path $preflight 'external-release-entry'
                New-Item -ItemType Directory -Path $externalRelease | Out-Null
                'reparse-sentinel' | Set-Content -LiteralPath (Join-Path $externalRelease 'keep.txt')
                New-Item -ItemType Junction -Path (Join-Path $preflightReleases '.staging.external') -Target $externalRelease | Out-Null
            }
            'unknown-nested-file' {
                'nested-note-sentinel' | Set-Content -LiteralPath (Join-Path $preflightCurrent 'notes.txt')
            }
            'nested-release-junction' {
                $externalRelease = Join-Path $preflight 'external-nested-release-entry'
                New-Item -ItemType Directory -Path $externalRelease | Out-Null
                'nested-reparse-sentinel' | Set-Content -LiteralPath (Join-Path $externalRelease 'keep.txt')
                New-Item -ItemType Junction -Path (Join-Path $preflightCurrent 'nested-link') -Target $externalRelease | Out-Null
            }
        }
        $preflightResult = Invoke-UninstallerProcess -LocalAppData $preflight
        Assert-True ($preflightResult.ExitCode -ne 0) "$preflightCase preflight unexpectedly succeeded"
        Assert-Equal -Expected $preflightCurrent -Actual (Get-JunctionTarget (Join-Path $preflightRoot 'current')) -Message "$preflightCase changed current"
        Assert-Equal -Expected $preflightBin -Actual (Get-JunctionTarget (Join-Path $preflightRoot 'bin')) -Message "$preflightCase changed bin"
        Assert-Equal -Expected $preflightTaskJson -Actual (Get-Content -LiteralPath (Join-Path (Initialize-TestState $preflight) 'task.json') -Raw) -Message "$preflightCase changed task before preflight completed"
        Assert-Equal -Expected $preflightPathJson -Actual (Get-Content -LiteralPath (Join-Path (Initialize-TestState $preflight) 'path.json') -Raw) -Message "$preflightCase changed PATH before preflight completed"
        Assert-True (Test-Path -LiteralPath (Join-Path $preflightCurrent 'farpilot.exe')) "$preflightCase removed active release"
        switch ($preflightCase) {
            'unmanaged-directory' {
                Assert-Equal -Expected 'release-sentinel' -Actual (Get-Content -LiteralPath (Join-Path $preflightReleases 'operator-data\keep.txt') -Raw).Trim() -Message 'unmanaged release data changed'
            }
            'reparse-entry' {
                Assert-Equal -Expected 'reparse-sentinel' -Actual (Get-Content -LiteralPath (Join-Path $preflight 'external-release-entry\keep.txt') -Raw).Trim() -Message 'release reparse target changed'
            }
            'unknown-nested-file' {
                Assert-Equal -Expected 'nested-note-sentinel' -Actual (Get-Content -LiteralPath (Join-Path $preflightCurrent 'notes.txt') -Raw).Trim() -Message 'unknown nested release file changed'
            }
            'nested-release-junction' {
                Assert-Equal -Expected 'nested-reparse-sentinel' -Actual (Get-Content -LiteralPath (Join-Path $preflight 'external-nested-release-entry\keep.txt') -Raw).Trim() -Message 'nested release junction target changed'
            }
        }
    }

    # DryRun makes no FarPilot root and leaves user PATH unchanged.
    $dryRun = Initialize-ScenarioRoot 'dry-run'
    $dryPathBefore = [Environment]::GetEnvironmentVariable('Path', 'User')
    $dry = Invoke-InstallerProcess -LocalAppData $dryRun -PackagePath $packages['0.2.0'] -Version '0.2.0' -Sha256 (Get-FileHash -Algorithm SHA256 $packages['0.2.0']).Hash -DryRun
    Assert-Equal -Expected 0 -Actual $dry.ExitCode -Message "DryRun failed: $($dry.Output)"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $dryRun 'FarPilot'))) 'DryRun created FarPilot root'
    Assert-Equal -Expected $dryPathBefore -Actual ([Environment]::GetEnvironmentVariable('Path', 'User')) -Message 'DryRun changed user PATH'

    # Production code must isolate process and task operations behind explicit functions.
    $source = Get-Content -LiteralPath $Installer -Raw
    Assert-True ($source -match 'function\s+Invoke-ManagedFarPilotProcessStop') 'managed process stop boundary is missing'
    Assert-True ($source -match 'function\s+Invoke-FarPilotStartupTaskUpdate') 'startup task boundary is missing'
    Assert-True ($source -match "New-ScheduledTaskAction\s+-Execute\s+\`$Executable\s+-Argument\s+'run'") 'startup task does not use fixed runner arguments'
    Assert-True ($source -match 'function\s+Restore-FarPilotStartupTask') 'startup task rollback boundary is missing'
    Assert-True ($source -match 'function\s+Restore-UserPath') 'PATH rollback boundary is missing'
    Assert-True ($source -match 'function\s+Get-ManagedFarPilotProcessState') 'process snapshot boundary is missing'
    Assert-True ($source -match 'function\s+Compare-FarPilotReleaseContent') 'same-version release content comparison boundary is missing'
    Assert-True ($source -match 'Compare-FarPilotReleaseContent\s+-Expected\s+\$stagedLayout\s+-Actual\s+\$existingLayout') 'same-version release content comparison is missing'
    Assert-True ($source -match 'function\s+Assert-ManagedReleaseTarget') 'managed alias target validation is missing'
    Assert-True ($source -match 'function\s+Test-JunctionReleaseReference') 'rollback alias reference guard is missing'
    Assert-True ($source -notmatch '\[switch\]\$ConfirmPurge') 'public ConfirmPurge bypass parameter must not exist'
    Assert-True ($source -match 'Read-Host.+PURGE FARPILOT STATE') 'typed purge confirmation boundary is missing'

    Write-Output 'FarPilot Windows installer behavior verified'
} finally {
    if ($null -eq $OriginalLocalAppData) { Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue } else { $env:LOCALAPPDATA = $OriginalLocalAppData }
    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

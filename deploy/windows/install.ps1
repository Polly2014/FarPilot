[CmdletBinding()]
param(
    [string]$Version,
    [string]$ManifestUrl,
    [string]$InstallDir,
    [switch]$NoStartupTask,
    [switch]$DryRun,
    [switch]$Uninstall,
    [switch]$PurgeState,
    [int]$Retain = 3,
    [string]$LocalPackagePath,
    [string]$LocalPackageVersion,
    [string]$LocalPackageSha256,
    [string]$TestStateDirectory,
    [ValidateSet('', 'DuringPathStateCapture', 'DuringManagedProcessStop', 'DuringTaskRemoval', 'DuringPathRemoval', 'DuringAliasQuarantine', 'DuringReleaseQuarantine', 'DuringUninstallCleanup', 'DuringPurgeCleanup', 'DuringInstallStateReplace', 'AfterCurrentJunction', 'AfterBinJunction', 'AfterPathUpdate', 'DuringTaskUpdate', 'DuringTaskStart', 'DuringCleanup')]
    [string]$TestFailAfter = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.IO.Compression

$TargetTriple = 'x86_64-pc-windows-msvc'
$TargetName = 'windows-x86_64'
$RepositoryOwner = 'Polly2014'
$RepositoryName = 'FarPilot'
$TaskName = 'FarPilot Host'
$MaxZipEntryBytes = [long](64MB)
$MaxZipAggregateBytes = [long](96MB)
$script:UseTestAdapters = $false
$script:TestStateRoot = $null

function Write-Step {
    param([string]$Message)
    Write-Output "==> $Message"
}

function Get-TestStatePath {
    param([string]$Name)
    if (-not $script:UseTestAdapters) { throw 'Test adapter requested outside test mode' }
    return Join-Path $script:TestStateRoot "$Name.json"
}

function Read-TestState {
    param([string]$Name, [object]$DefaultValue)
    $path = Get-TestStatePath $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $DefaultValue }
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}

function Write-TestState {
    param([string]$Name, [object]$Value)
    $path = Get-TestStatePath $Name
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding UTF8
}

function Invoke-TestFailure {
    param([string]$Point)
    if ($script:UseTestAdapters -and $TestFailAfter -ceq $Point) {
        throw "Injected FarPilot installer failure: $Point"
    }
}

function Normalize-Version {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $normalized = $Value.Trim()
    if ($normalized.StartsWith('v', [StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring(1)
    }
    if ($normalized -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
        throw "FarPilot version must use X.Y.Z or vX.Y.Z: $Value"
    }
    return $normalized
}

function Test-RegularFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    return -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Test-RegularDirectory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    return -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Get-CanonicalPath {
    param([string]$Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd([char]'\')
}

function Test-PathInside {
    param([string]$Path, [string]$Parent)
    $candidate = Get-CanonicalPath $Path
    $root = Get-CanonicalPath $Parent
    return $candidate.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Test-FileDigest {
    param([string]$Path, [string]$Expected)
    if ($Expected -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'FarPilot manifest contains an invalid SHA-256 digest'
    }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
    if ($actual -ne $Expected.ToLowerInvariant()) {
        throw "FarPilot SHA256 mismatch: expected $Expected but got $actual"
    }
}

function Get-ExecutableVersion {
    param([string]$Path, [string]$ProductName = 'farpilot')
    $output = & $Path --version 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "FarPilot executable failed --version: $Path"
    }
    $line = $output.Trim()
    $product = [regex]::Escape($ProductName)
    if ($line -notmatch "^$product ([0-9]+\.[0-9]+\.[0-9]+)$") {
        throw "FarPilot executable returned an invalid version: $line"
    }
    return $Matches[1]
}

function Test-AuthenticodePolicy {
    param([string]$Path)
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -notin @('Valid', 'NotSigned')) {
        throw "FarPilot Authenticode signature is $($signature.Status)"
    }
}

function Expand-VerifiedFarPilotPackage {
    param([string]$ArchivePath, [string]$Destination)
    if (-not (Test-RegularFile $ArchivePath)) { throw "FarPilot ZIP is not a regular file: $ArchivePath" }
    if (Test-Path -LiteralPath $Destination) { throw "FarPilot ZIP destination already exists: $Destination" }
    $destinationParent = Split-Path -Parent $Destination
    if (-not (Test-RegularDirectory $destinationParent)) { throw "FarPilot ZIP destination parent is unsafe: $destinationParent" }
    $createdDestination = $false
    try {
        $archiveFile = [IO.File]::Open($ArchivePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $archive = [IO.Compression.ZipArchive]::new($archiveFile, [IO.Compression.ZipArchiveMode]::Read, $false)
            try {
                $entries = @($archive.Entries)
                if ($entries.Count -ne 2) { throw 'FarPilot ZIP must contain exactly two entries' }
                $accepted = @{}
                $aggregate = [long]0
                foreach ($entry in $entries) {
                    $name = [string]$entry.FullName
                    if ([string]::IsNullOrWhiteSpace($name) -or $name.EndsWith('/') -or $name.EndsWith('\')) {
                        throw 'FarPilot ZIP contains a directory or empty entry'
                    }
                    if ([IO.Path]::IsPathRooted($name) -or $name.Contains('/') -or $name.Contains('\') -or
                        $name.Contains('..') -or $name.Contains(':')) {
                        throw "FarPilot ZIP contains an unsafe entry name: $name"
                    }
                    $canonicalName = if ($name -ieq 'farpilot.exe') {
                        'farpilot.exe'
                    } elseif ($name -ieq 'farpilot-host-runner.exe') {
                        'farpilot-host-runner.exe'
                    } else {
                        throw "FarPilot ZIP contains an unexpected entry: $name"
                    }
                    if ($accepted.ContainsKey($canonicalName)) { throw "FarPilot ZIP contains a duplicate entry: $name" }
                    $attributeBits = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$entry.ExternalAttributes), 0)
                    $unixFileType = ($attributeBits -shr 16) -band [uint32]0xF000
                    if ($unixFileType -eq [uint32]0xA000 -or
                        ($attributeBits -band [uint32]0x400) -ne 0) {
                        throw "FarPilot ZIP contains a symlink or reparse entry: $name"
                    }
                    if ([long]$entry.Length -le 0 -or [long]$entry.Length -gt $MaxZipEntryBytes) {
                        throw "FarPilot ZIP entry exceeds the size limit: $name"
                    }
                    $aggregate += [long]$entry.Length
                    if ($aggregate -gt $MaxZipAggregateBytes) { throw 'FarPilot ZIP exceeds the aggregate size limit' }
                    $accepted[$canonicalName] = $entry
                }
                if (-not $accepted.ContainsKey('farpilot.exe') -or -not $accepted.ContainsKey('farpilot-host-runner.exe')) {
                    throw 'FarPilot ZIP is missing a required executable'
                }

                New-Item -ItemType Directory -Path $Destination | Out-Null
                $createdDestination = $true
                foreach ($canonicalName in @('farpilot.exe', 'farpilot-host-runner.exe')) {
                    $entry = $accepted[$canonicalName]
                    $outputPath = Join-Path $Destination $canonicalName
                    $input = $entry.Open()
                    try {
                        $output = [IO.File]::Open($outputPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                        try {
                            $buffer = [byte[]]::new(1MB)
                            $written = [long]0
                            while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
                                $written += [long]$read
                                if ($written -gt [long]$entry.Length -or $written -gt $MaxZipEntryBytes) {
                                    throw "FarPilot ZIP entry expanded beyond its declared limit: $canonicalName"
                                }
                                $output.Write($buffer, 0, $read)
                            }
                            if ($written -ne [long]$entry.Length) {
                                throw "FarPilot ZIP entry length changed during extraction: $canonicalName"
                            }
                            $output.Flush($true)
                        } finally {
                            $output.Dispose()
                        }
                    } finally {
                        $input.Dispose()
                    }
                }
            } finally {
                $archive.Dispose()
            }
        } finally {
            $archiveFile.Dispose()
        }
        foreach ($required in @('farpilot.exe', 'farpilot-host-runner.exe')) {
            $path = Join-Path $Destination $required
            if (-not (Test-RegularFile $path)) { throw "FarPilot ZIP extracted an unsafe executable: $required" }
        }
    } catch {
        if ($createdDestination -and (Test-RegularDirectory $Destination)) {
            Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Get-FarPilotReleaseLayout {
    param([string]$Path, [string]$Label = 'release')
    if (-not (Test-RegularDirectory $Path)) { throw "FarPilot $Label is not a regular directory: $Path" }
    $entries = @(Get-ChildItem -LiteralPath $Path -Force)
    if ($entries.Count -eq 1 -and $entries[0].Name -ieq 'farpilot.exe' -and (Test-RegularFile $entries[0].FullName)) {
        return [PSCustomObject]@{
            Format = 'exe'
            Cli = (Join-Path $Path 'farpilot.exe')
            Runner = $null
            FileNames = @('farpilot.exe')
        }
    }
    if ($entries.Count -eq 2) {
        $cli = Join-Path $Path 'farpilot.exe'
        $runner = Join-Path $Path 'farpilot-host-runner.exe'
        if ((Test-RegularFile $cli) -and (Test-RegularFile $runner) -and
            @($entries | Where-Object { $_.Name -inotmatch '^farpilot(?:-host-runner)?\.exe$' }).Count -eq 0) {
            return [PSCustomObject]@{
                Format = 'zip'
                Cli = $cli
                Runner = $runner
                FileNames = @('farpilot.exe', 'farpilot-host-runner.exe')
            }
        }
    }
    throw "FarPilot $Label has unexpected contents: $Path"
}

function Assert-FarPilotReleaseBinaries {
    param([object]$Layout, [string]$ExpectedVersion, [string]$Label)
    Test-AuthenticodePolicy $Layout.Cli
    $cliVersion = Get-ExecutableVersion $Layout.Cli
    if ($cliVersion -cne $ExpectedVersion) { throw "$Label CLI version $cliVersion does not match $ExpectedVersion" }
    if ($Layout.Format -ceq 'zip') {
        Test-AuthenticodePolicy $Layout.Runner
        $runnerVersion = Get-ExecutableVersion -Path $Layout.Runner -ProductName 'farpilot-host-runner'
        if ($runnerVersion -cne $ExpectedVersion) { throw "$Label runner version $runnerVersion does not match $ExpectedVersion" }
    }
}

function Compare-FarPilotReleaseBytes {
    param([object]$Expected, [object]$Actual)
    if ($Expected.Format -cne $Actual.Format) { return $false }
    foreach ($name in @($Expected.FileNames)) {
        $expectedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path (Split-Path -Parent $Expected.Cli) $name)).Hash
        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path (Split-Path -Parent $Actual.Cli) $name)).Hash
        if ($expectedHash -cne $actualHash) { return $false }
    }
    return $true
}

function Invoke-CurlDownload {
    param([string]$Uri, [string]$Destination)
    $parsed = $null
    if (-not [Uri]::TryCreate($Uri, [UriKind]::Absolute, [ref]$parsed) -or $parsed.Scheme -ne 'https') {
        throw "FarPilot download URL must use HTTPS: $Uri"
    }
    $curl = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $curl) { throw 'FarPilot installation requires curl.exe' }
    $arguments = @(
        '--fail', '--silent', '--show-error', '--location',
        '--proto', '=https', '--tlsv1.2',
        '--connect-timeout', '10', '--max-time', '120',
        '--output', $Destination, '--', $Uri
    )
    $output = & $curl.Source @arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $detail = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        throw "Failed to download $Uri`: $detail"
    }
}

function Assert-DeterministicManifestShape {
    param([string]$Raw)
    $expectations = @(
        @{ Indent = 2; Key = 'schema_version'; Count = 1 },
        @{ Indent = 2; Key = 'version'; Count = 1 },
        @{ Indent = 2; Key = 'tag'; Count = 1 },
        @{ Indent = 2; Key = 'assets'; Count = 1 },
        @{ Indent = 2; Key = 'installers'; Count = 1 },
        @{ Indent = 4; Key = 'linux-x86_64'; Count = 1 },
        @{ Indent = 4; Key = 'linux-aarch64'; Count = 1 },
        @{ Indent = 4; Key = 'macos-x86_64'; Count = 1 },
        @{ Indent = 4; Key = 'macos-aarch64'; Count = 1 },
        @{ Indent = 4; Key = 'windows-x86_64'; Count = 1 },
        @{ Indent = 4; Key = 'gateway'; Count = 1 },
        @{ Indent = 6; Key = 'url'; Count = 6 },
        @{ Indent = 6; Key = 'sha256'; Count = 6 },
        @{ Indent = 6; Key = 'format'; Count = 5 }
    )
    foreach ($expectation in $expectations) {
        $spaces = ' ' * [int]$expectation.Indent
        $key = [regex]::Escape([string]$expectation.Key)
        $pattern = '(?m)^' + [regex]::Escape($spaces) + '"' + $key + '"\s*:'
        $count = [regex]::Matches($Raw, $pattern).Count
        if ($count -ne [int]$expectation.Count) {
            throw "FarPilot manifest has an invalid or duplicate $($expectation.Key) field"
        }
    }
}

function Get-RemoteManifest {
    param([string]$Uri)
    $path = Join-Path ([IO.Path]::GetTempPath()) ('farpilot-manifest-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        Invoke-CurlDownload -Uri $Uri -Destination $path
        $raw = Get-Content -LiteralPath $path -Raw
        Assert-DeterministicManifestShape $raw
        return $raw | ConvertFrom-Json
    } finally {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Assert-ExactPropertySet {
    param([object]$Value, [string[]]$Expected, [string]$Label)
    if ($null -eq $Value) { throw "$Label is missing" }
    $actual = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
    $difference = @(Compare-Object -ReferenceObject $Expected -DifferenceObject $actual)
    if ($difference.Count -ne 0) {
        throw "$Label has an unexpected property set"
    }
}

function Get-ManifestPackage {
    param([object]$Manifest, [string]$RequestedVersion)
    Assert-ExactPropertySet -Value $Manifest -Expected @('schema_version', 'version', 'tag', 'assets', 'installers') -Label 'FarPilot manifest'
    if ([int]$Manifest.schema_version -ne 1) {
        throw 'Unsupported FarPilot manifest schema'
    }
    $manifestVersion = Normalize-Version ([string]$Manifest.version)
    if ([string]$Manifest.tag -cne "v$manifestVersion") {
        throw 'FarPilot manifest tag does not match its version'
    }
    if (-not [string]::IsNullOrWhiteSpace($RequestedVersion) -and $manifestVersion -cne $RequestedVersion) {
        throw "FarPilot manifest version $manifestVersion does not match requested version $RequestedVersion"
    }
    $assetsProperty = $Manifest.PSObject.Properties['assets']
    if ($null -eq $assetsProperty -or $null -eq $assetsProperty.Value) {
        throw 'FarPilot manifest assets are missing'
    }
    Assert-ExactPropertySet -Value $assetsProperty.Value -Expected @(
        'linux-x86_64', 'linux-aarch64', 'macos-x86_64', 'macos-aarch64', 'windows-x86_64'
    ) -Label 'FarPilot manifest assets'
    Assert-ExactPropertySet -Value $Manifest.installers -Expected @('gateway') -Label 'FarPilot manifest installers'
    Assert-ExactPropertySet -Value $Manifest.installers.gateway -Expected @('url', 'sha256') -Label 'FarPilot gateway installer'
    $assetProperty = $assetsProperty.Value.PSObject.Properties[$TargetName]
    if ($null -eq $assetProperty -or $null -eq $assetProperty.Value) {
        throw "FarPilot manifest has no $TargetName asset"
    }
    $asset = $assetProperty.Value
    Assert-ExactPropertySet -Value $asset -Expected @('url', 'sha256', 'format') -Label 'FarPilot Windows asset'
    if ([string]$asset.format -cne 'zip') {
        throw 'FarPilot Windows manifest asset must use zip format'
    }
    $sha = [string]$asset.sha256
    if ($sha -notmatch '^[0-9a-f]{64}$') {
        throw 'FarPilot Windows manifest asset has an invalid SHA-256 digest'
    }
    $uri = $null
    $url = [string]$asset.url
    if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') {
        throw 'FarPilot Windows manifest asset URL must use HTTPS'
    }
    if ($uri.Host -cne 'github.com' -or -not [string]::IsNullOrEmpty($uri.UserInfo) -or -not $uri.IsDefaultPort -or
        -not [string]::IsNullOrEmpty($uri.Query) -or -not [string]::IsNullOrEmpty($uri.Fragment)) {
        throw 'FarPilot Windows manifest asset URL is not an allowed GitHub Release URL'
    }
    $segments = @($uri.AbsolutePath.Trim('/').Split('/'))
    if ($segments.Count -ne 6 -or $segments[0] -cne $RepositoryOwner -or $segments[1] -cne $RepositoryName -or
        $segments[2] -cne 'releases' -or $segments[3] -cne 'download' -or
        $segments[4] -cne "v$manifestVersion" -or $segments[5] -cne 'farpilot-windows-x86_64.zip') {
        throw 'FarPilot Windows manifest asset URL has an invalid Release path'
    }
    return [PSCustomObject]@{ Version = $manifestVersion; Url = $url; Sha256 = $sha; Format = 'zip' }
}

function Enter-InstallLock {
    param([string]$Path, [int]$TimeoutMilliseconds = 5000)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    while ($true) {
        try {
            return [IO.File]::Open($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Delete)
        } catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) {
                throw 'Another FarPilot installation is already running'
            }
            Start-Sleep -Milliseconds 200
        }
    }
}

function Get-JunctionTarget {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType -ne 'Junction') {
        throw "FarPilot managed path is not a junction: $Path"
    }
    $target = [string]$item.Target
    if ([string]::IsNullOrWhiteSpace($target)) { throw "FarPilot junction has no target: $Path" }
    return Get-CanonicalPath $target
}

function Assert-ManagedReleaseTarget {
    param([string]$Target, [string]$ReleasesDir, [string]$AliasPath)
    if (-not (Test-PathInside -Path $Target -Parent $ReleasesDir)) {
        throw "Refusing FarPilot junction outside managed releases: $AliasPath -> $Target"
    }
    if (-not (Test-RegularDirectory $Target)) {
        throw "FarPilot junction target is missing, unsafe, or not a regular directory: $AliasPath -> $Target"
    }
    $parent = Get-CanonicalPath (Split-Path -Parent $Target)
    if ($parent -ine (Get-CanonicalPath $ReleasesDir)) {
        throw "FarPilot junction target must be a direct release directory: $AliasPath -> $Target"
    }
    $releaseName = Split-Path -Leaf $Target
    if ($releaseName -notmatch '^([0-9]+\.[0-9]+\.[0-9]+)-x86_64-pc-windows-msvc$') {
        throw "FarPilot junction target has an invalid release name: $AliasPath -> $Target"
    }
    $expectedVersion = $Matches[1]
    $layout = Get-FarPilotReleaseLayout -Path $Target -Label 'junction target release'
    Assert-FarPilotReleaseBinaries -Layout $layout -ExpectedVersion $expectedVersion -Label 'FarPilot junction target'
}

function Get-JunctionState {
    param(
        [string]$Path,
        [string]$ReleasesDir,
        [bool]$AllowLegacyBinary
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return [PSCustomObject]@{ Kind = 'Missing'; Target = $null; Backup = $null }
    }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        if ($item.LinkType -ne 'Junction') { throw "Refusing non-junction reparse point: $Path" }
        $target = Get-JunctionTarget $Path
        Assert-ManagedReleaseTarget -Target $target -ReleasesDir $ReleasesDir -AliasPath $Path
        return [PSCustomObject]@{ Kind = 'Junction'; Target = $target; Backup = $null }
    }
    if (-not $item.PSIsContainer) { throw "Refusing to replace file at managed junction path: $Path" }
    $entries = @(Get-ChildItem -LiteralPath $Path -Force)
    if ($entries.Count -eq 0) {
        return [PSCustomObject]@{ Kind = 'EmptyDirectory'; Target = $null; Backup = $null }
    }
    if ($AllowLegacyBinary -and $entries.Count -eq 1 -and $entries[0].Name -ieq 'farpilot.exe' -and (Test-RegularFile $entries[0].FullName)) {
        return [PSCustomObject]@{ Kind = 'LegacyBinary'; Target = $null; Backup = $null }
    }
    throw "Refusing to replace unmanaged nonempty directory: $Path"
}

function Invoke-ManagedJunctionActivation {
    param(
        [string]$Path,
        [string]$Target,
        [object]$State,
        [string]$Root
    )
    if ($State.Kind -eq 'Junction' -and $State.Target -ieq (Get-CanonicalPath $Target)) { return $State }
    if ($State.Kind -eq 'Junction') {
        Remove-Item -LiteralPath $Path -Force
    } elseif ($State.Kind -eq 'EmptyDirectory') {
        Remove-Item -LiteralPath $Path -Force
    } elseif ($State.Kind -eq 'LegacyBinary') {
        $backup = Join-Path $Root ('bin.legacy.' + [guid]::NewGuid().ToString('N'))
        Move-Item -LiteralPath $Path -Destination $backup
        $State.Backup = $backup
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    New-Item -ItemType Junction -Path $Path -Target $Target | Out-Null
    return $State
}

function Restore-ManagedJunction {
    param([string]$Path, [object]$State)
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            Remove-Item -LiteralPath $Path -Force
        }
    }
    if ($State.Kind -eq 'Junction') {
        New-Item -ItemType Junction -Path $Path -Target $State.Target | Out-Null
    } elseif ($State.Kind -eq 'EmptyDirectory') {
        New-Item -ItemType Directory -Path $Path | Out-Null
    } elseif ($State.Kind -eq 'LegacyBinary' -and -not [string]::IsNullOrWhiteSpace([string]$State.Backup) -and (Test-Path -LiteralPath $State.Backup)) {
        Move-Item -LiteralPath $State.Backup -Destination $Path
    }
}

function Get-ManagedFarPilotProcessState {
    if ($script:UseTestAdapters) {
        return @(Read-TestState -Name 'processes' -DefaultValue @())
    }
    return @(Get-CimInstance Win32_Process -Filter "Name = 'farpilot.exe'" -ErrorAction SilentlyContinue)
}

function Test-JunctionReleaseReference {
    param([string]$Path, [string]$ReleaseDir)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $item = Get-Item -LiteralPath $Path -Force
        if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType -ne 'Junction') {
            return $true
        }
        return (Get-JunctionTarget $Path) -ieq (Get-CanonicalPath $ReleaseDir)
    } catch {
        return $true
    }
}

function Invoke-ManagedFarPilotProcessStop {
    param(
        [object[]]$ProcessState,
        [string]$ReleasesDir,
        [string[]]$ManagedAliases = @()
    )
    Invoke-TestFailure -Point 'DuringManagedProcessStop'
    foreach ($process in @($ProcessState)) {
        $path = [string]$process.ExecutablePath
        $name = if ($process.PSObject.Properties['Name']) { [string]$process.Name } else { 'farpilot.exe' }
        $managed = -not [string]::IsNullOrWhiteSpace($path) -and (Test-PathInside -Path $path -Parent $ReleasesDir)
        if (-not $managed -and -not [string]::IsNullOrWhiteSpace($path)) {
            foreach ($alias in $ManagedAliases) {
                if (Test-PathInside -Path $path -Parent $alias) {
                    $managed = $true
                    break
                }
            }
        }
        if ($name -ieq 'farpilot.exe' -and $managed) {
            if ($script:UseTestAdapters) {
                $process.Stopped = $true
            } else {
                Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
            }
        }
    }
    if ($script:UseTestAdapters) {
        Write-TestState -Name 'processes' -Value @($ProcessState)
    }
}

function Get-FarPilotStartupTaskState {
    if ($script:UseTestAdapters) {
        $missing = [PSCustomObject]@{
            Exists = $false; Running = $false; Executable = $null; Arguments = $null
            UserId = $null; RunLevel = $null; Definition = $null
        }
        $state = Read-TestState -Name 'task' -DefaultValue $missing
        return [PSCustomObject]@{
            Exists = [bool]$state.Exists
            Running = [bool]$state.Running
            Executable = [string]$state.Executable
            Arguments = [string]$state.Arguments
            UserId = [string]$state.UserId
            RunLevel = [string]$state.RunLevel
            Definition = $state
        }
    }
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        return [PSCustomObject]@{ Exists = $false; Running = $false; Definition = $null }
    }
    $actions = @($task.Actions)
    $executable = if ($actions.Count -eq 1) { [string]$actions[0].Execute } else { $null }
    $arguments = if ($actions.Count -eq 1) { [string]$actions[0].Arguments } else { $null }
    return [PSCustomObject]@{
        Exists = $true
        Running = ($task.State -eq 'Running')
        Executable = $executable
        Arguments = $arguments
        UserId = [string]$task.Principal.UserId
        RunLevel = [string]$task.Principal.RunLevel
        Definition = $task
    }
}

function Invoke-FarPilotStartupTaskStop {
    param([object]$State)
    if (-not ($State.Exists -and $State.Running)) { return }
    if ($script:UseTestAdapters) {
        $updated = Read-TestState -Name 'task' -DefaultValue $State.Definition
        $updated.Running = $false
        Write-TestState -Name 'task' -Value $updated
        return
    }
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop
}

function Invoke-FarPilotStartupTaskUpdate {
    param([string]$Executable, [object]$PreviousState, [bool]$CreateTask)
    if (-not $CreateTask -and -not $PreviousState.Exists) { return }
    if ($script:UseTestAdapters) {
        $updated = [PSCustomObject]@{
            Exists = $true
            Running = $false
            Executable = $Executable
            Arguments = 'host start'
            UserId = $env:USERNAME
            RunLevel = 'Limited'
        }
        Write-TestState -Name 'task' -Value $updated
        Invoke-TestFailure -Point 'DuringTaskUpdate'
        if ($PreviousState.Running) {
            Invoke-TestFailure -Point 'DuringTaskStart'
            $updated.Running = $true
            Write-TestState -Name 'task' -Value $updated
        }
        return
    }
    $action = New-ScheduledTaskAction -Execute $Executable -Argument 'host start'
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
    Invoke-TestFailure -Point 'DuringTaskUpdate'
    if ($PreviousState.Running) {
        Invoke-TestFailure -Point 'DuringTaskStart'
        Start-ScheduledTask -TaskName $TaskName
    }
}

function Restore-FarPilotStartupTask {
    param([object]$State)
    if ($script:UseTestAdapters) {
        if ($State.Exists) {
            Write-TestState -Name 'task' -Value $State.Definition
        } else {
            Write-TestState -Name 'task' -Value ([PSCustomObject]@{
                Exists = $false; Running = $false; Executable = $null; Arguments = $null
                UserId = $null; RunLevel = $null
            })
        }
        return
    }
    $current = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $State.Exists) {
        if ($null -ne $current) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        }
        return
    }
    Register-ScheduledTask -TaskName $TaskName -InputObject $State.Definition -Force | Out-Null
    if ($State.Running) {
        Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    } else {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    }
}

function Prepend-ManagedPath {
    param([string]$PathValue, [string]$Entry, [string]$ReleasesDir, [string[]]$Aliases)
    $normalizedEntry = Get-CanonicalPath $Entry
    $segments = @($normalizedEntry)
    if (-not [string]::IsNullOrWhiteSpace($PathValue)) {
        foreach ($raw in $PathValue.Split(';', [StringSplitOptions]::RemoveEmptyEntries)) {
            $candidate = $raw.Trim().Trim('"')
            try { $normalized = Get-CanonicalPath ([Environment]::ExpandEnvironmentVariables($candidate)) } catch { $normalized = $candidate }
            $ownedRelease = Test-PathInside -Path $normalized -Parent $ReleasesDir
            $ownedAlias = $false
            foreach ($alias in $Aliases) {
                if ($normalized -ieq (Get-CanonicalPath $alias)) { $ownedAlias = $true }
            }
            if (-not $ownedRelease -and -not $ownedAlias -and $normalized -ine $normalizedEntry) {
                $segments += $raw
            }
        }
    }
    return ($segments -join ';')
}

function Publish-EnvironmentChange {
    if (-not ('FarPilotInstaller.EnvironmentNativeMethods' -as [type])) {
        Add-Type -Namespace FarPilotInstaller -Name EnvironmentNativeMethods -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint message, System.UIntPtr wParam, string lParam, uint flags, uint timeout, out System.UIntPtr result);
'@
    }
    $result = [UIntPtr]::Zero
    [FarPilotInstaller.EnvironmentNativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x1a, [UIntPtr]::Zero, 'Environment', 0x0002, 1000, [ref]$result) | Out-Null
}

function Get-UserPathState {
    Invoke-TestFailure -Point 'DuringPathStateCapture'
    if ($script:UseTestAdapters) {
        $default = [PSCustomObject]@{ Exists = $false; Value = $null; Kind = 'String'; ProcessValue = $env:Path }
        $state = Read-TestState -Name 'path' -DefaultValue $default
        return [PSCustomObject]@{
            Exists = [bool]$state.Exists
            Value = [string]$state.Value
            Kind = [string]$state.Kind
            ProcessValue = [string]$state.ProcessValue
        }
    }
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false)
    try {
        if ($null -eq $key -or -not ($key.GetValueNames() -contains 'Path')) {
            return [PSCustomObject]@{
                Exists = $false
                Value = $null
                Kind = [Microsoft.Win32.RegistryValueKind]::String
                ProcessValue = $env:Path
            }
        }
        $options = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
        return [PSCustomObject]@{
            Exists = $true
            Value = [string]$key.GetValue('Path', $null, $options)
            Kind = $key.GetValueKind('Path')
            ProcessValue = $env:Path
        }
    } finally {
        if ($null -ne $key) { $key.Dispose() }
    }
}

function Invoke-UserPathUpdate {
    param([string]$Entry, [string]$ReleasesDir, [string[]]$Aliases)
    if ($script:UseTestAdapters) {
        $state = Get-UserPathState
        $updated = Prepend-ManagedPath -PathValue $state.Value -Entry $Entry -ReleasesDir $ReleasesDir -Aliases $Aliases
        $processUpdated = Prepend-ManagedPath -PathValue $state.ProcessValue -Entry $Entry -ReleasesDir $ReleasesDir -Aliases $Aliases
        Write-TestState -Name 'path' -Value ([PSCustomObject]@{
            Exists = $true; Value = $updated; Kind = $state.Kind; ProcessValue = $processUpdated
        })
        Invoke-TestFailure -Point 'AfterPathUpdate'
        return
    }
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
    if ($null -eq $key) { throw 'Unable to open current-user environment registry key' }
    try {
        $options = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
        $current = $key.GetValue('Path', $null, $options)
        $kind = if ($null -eq $current) { [Microsoft.Win32.RegistryValueKind]::String } else { $key.GetValueKind('Path') }
        $updated = Prepend-ManagedPath -PathValue ([string]$current) -Entry $Entry -ReleasesDir $ReleasesDir -Aliases $Aliases
        if ($updated -cne [string]$current) { $key.SetValue('Path', $updated, $kind) }
        $env:Path = Prepend-ManagedPath -PathValue $env:Path -Entry $Entry -ReleasesDir $ReleasesDir -Aliases $Aliases
    } finally {
        $key.Dispose()
    }
    Publish-EnvironmentChange
}

function Restore-UserPath {
    param([object]$State)
    if ($script:UseTestAdapters) {
        Write-TestState -Name 'path' -Value ([PSCustomObject]@{
            Exists = $State.Exists; Value = $State.Value; Kind = $State.Kind; ProcessValue = $State.ProcessValue
        })
        return
    }
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
    if ($null -eq $key) { throw 'Unable to open current-user environment registry key during rollback' }
    try {
        if ($State.Exists) {
            $key.SetValue('Path', $State.Value, $State.Kind)
        } else {
            $key.DeleteValue('Path', $false)
        }
        $env:Path = $State.ProcessValue
    } finally {
        $key.Dispose()
    }
    Publish-EnvironmentChange
}

function Get-PathWithoutManagedEntry {
    param([string]$PathValue, [string]$ReleasesDir, [string[]]$Aliases)
    $segments = @()
    if (-not [string]::IsNullOrWhiteSpace($PathValue)) {
        foreach ($raw in $PathValue.Split(';', [StringSplitOptions]::RemoveEmptyEntries)) {
            $candidate = $raw.Trim().Trim('"')
            try { $normalized = Get-CanonicalPath ([Environment]::ExpandEnvironmentVariables($candidate)) } catch { $normalized = $candidate }
            $owned = Test-PathInside -Path $normalized -Parent $ReleasesDir
            foreach ($alias in $Aliases) {
                if ($normalized -ieq (Get-CanonicalPath $alias)) { $owned = $true }
            }
            if (-not $owned) { $segments += $raw }
        }
    }
    return ($segments -join ';')
}

function Invoke-UserPathRemoval {
    param([string]$ReleasesDir, [string[]]$Aliases)
    Invoke-TestFailure -Point 'DuringPathRemoval'
    $state = Get-UserPathState
    $updated = Get-PathWithoutManagedEntry -PathValue $state.Value -ReleasesDir $ReleasesDir -Aliases $Aliases
    $processUpdated = Get-PathWithoutManagedEntry -PathValue $state.ProcessValue -ReleasesDir $ReleasesDir -Aliases $Aliases
    if ($script:UseTestAdapters) {
        Write-TestState -Name 'path' -Value ([PSCustomObject]@{
            Exists = $state.Exists; Value = $updated; Kind = $state.Kind; ProcessValue = $processUpdated
        })
        return
    }
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
    if ($null -eq $key) { throw 'Unable to open current-user environment registry key for uninstall' }
    try {
        if ($state.Exists) { $key.SetValue('Path', $updated, $state.Kind) } else { $key.DeleteValue('Path', $false) }
        $env:Path = $processUpdated
    } finally {
        $key.Dispose()
    }
    Publish-EnvironmentChange
}

function Get-FarPilotInstallState {
    param([string]$Path, [string]$DefaultBinDir)
    if (-not (Test-Path -LiteralPath $Path)) {
        return [PSCustomObject]@{ Exists = $false; Raw = $null; Bytes = $null; VisibleBin = (Get-CanonicalPath $DefaultBinDir) }
    }
    if (-not (Test-RegularFile $Path)) { throw "Refusing unsafe FarPilot install-state file: $Path" }
    $raw = Get-Content -LiteralPath $Path -Raw
    $value = $raw | ConvertFrom-Json
    Assert-ExactPropertySet -Value $value -Expected @('schema_version', 'visible_bin') -Label 'FarPilot install state'
    if ([int]$value.schema_version -ne 1 -or [string]::IsNullOrWhiteSpace([string]$value.visible_bin)) {
        throw 'FarPilot install state is invalid'
    }
    $visibleBin = Get-CanonicalPath ([string]$value.visible_bin)
    if (-not [IO.Path]::IsPathRooted($visibleBin)) { throw 'FarPilot visible bin path must be absolute' }
    return [PSCustomObject]@{ Exists = $true; Raw = $raw; Bytes = [IO.File]::ReadAllBytes($Path); VisibleBin = $visibleBin }
}

function Resolve-FarPilotUninstallBinDir {
    param(
        [object]$InstallState,
        [object]$TaskState,
        [string]$DefaultBinDir,
        [string]$CurrentDir,
        [string]$ReleasesDir,
        [string]$LegacyHint
    )
    if ($InstallState.Exists) {
        if (-not [string]::IsNullOrWhiteSpace($LegacyHint)) { throw 'InstallDir is unnecessary and forbidden when install-state metadata exists' }
        return [string]$InstallState.VisibleBin
    }
    if ($TaskState.Exists) {
        if (-not [string]::IsNullOrWhiteSpace($LegacyHint)) { throw 'InstallDir is forbidden when a managed FarPilot task identifies the visible bin' }
        $executable = [string]$TaskState.Executable
        if ([string]::IsNullOrWhiteSpace($executable) -or (Split-Path -Leaf $executable) -ine 'farpilot.exe' -or
            [string]$TaskState.Arguments -cne 'host start') {
            throw 'Existing FarPilot task does not contain a valid managed executable path'
        }
        $candidate = Get-CanonicalPath (Split-Path -Parent $executable)
        $state = Get-JunctionState -Path $candidate -ReleasesDir $ReleasesDir -AllowLegacyBinary $false
        if ($state.Kind -ne 'Junction') { throw 'Existing FarPilot task executable is not under a managed visible-bin junction' }
        return $candidate
    }
    if (-not [string]::IsNullOrWhiteSpace($LegacyHint)) {
        $candidate = Get-CanonicalPath $LegacyHint
        $state = Get-JunctionState -Path $candidate -ReleasesDir $ReleasesDir -AllowLegacyBinary $false
        if ($state.Kind -ne 'Junction') { throw 'Legacy InstallDir must be a managed FarPilot junction' }
        return $candidate
    }
    $defaultCandidate = Get-CanonicalPath $DefaultBinDir
    $defaultState = Get-JunctionState -Path $defaultCandidate -ReleasesDir $ReleasesDir -AllowLegacyBinary $true
    if ($defaultState.Kind -eq 'Missing' -and (Test-Path -LiteralPath $CurrentDir)) {
        throw 'FarPilot visible bin cannot be inferred; rerun Uninstall with the legacy InstallDir path'
    }
    return $defaultCandidate
}

function Write-FarPilotInstallState {
    param([string]$Path, [string]$VisibleBin)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $identifier = [guid]::NewGuid().ToString('N')
    $temp = Join-Path $parent ('.install-state.' + $identifier + '.json')
    $backup = Join-Path $parent ('.install-state.backup.' + $identifier + '.json')
    try {
        [PSCustomObject]@{ schema_version = 1; visible_bin = (Get-CanonicalPath $VisibleBin) } |
            ConvertTo-Json | Set-Content -LiteralPath $temp -Encoding UTF8
        if (Test-Path -LiteralPath $Path) {
            Invoke-TestFailure -Point 'DuringInstallStateReplace'
            try {
                [IO.File]::Replace($temp, $Path, $backup)
            } catch {
                $replaceError = $_
                if (Test-Path -LiteralPath $backup) {
                    if (Test-Path -LiteralPath $Path) {
                        if (-not (Test-RegularFile $Path)) { throw "Install-state replacement left an unsafe destination: $Path" }
                        Remove-Item -LiteralPath $Path -Force
                    }
                    [IO.File]::Move($backup, $Path)
                }
                throw $replaceError
            }
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        } else {
            [IO.File]::Move($temp, $Path)
        }
    } finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
    }
}

function Restore-FarPilotInstallState {
    param([string]$Path, [object]$State)
    if (-not $State.Exists) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        return
    }
    $parent = Split-Path -Parent $Path
    $identifier = [guid]::NewGuid().ToString('N')
    $temp = Join-Path $parent ('.install-state.restore.' + $identifier + '.json')
    $backup = Join-Path $parent ('.install-state.restore-backup.' + $identifier + '.json')
    try {
        [IO.File]::WriteAllBytes($temp, [byte[]]$State.Bytes)
        if (Test-Path -LiteralPath $Path) {
            [IO.File]::Replace($temp, $Path, $backup)
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        } else {
            [IO.File]::Move($temp, $Path)
        }
    } finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-FarPilotStartupTaskRemoval {
    param([object]$State)
    Invoke-TestFailure -Point 'DuringTaskRemoval'
    if (-not $State.Exists) { return }
    if ($script:UseTestAdapters) {
        Write-TestState -Name 'task' -Value ([PSCustomObject]@{
            Exists = $false; Running = $false; Executable = $null; Arguments = $null
            UserId = $null; RunLevel = $null
        })
        return
    }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
}

function Assert-SafeUninstallDirectory {
    param([string]$Path, [string]$Root, [string]$Label)
    if (-not (Test-PathInside -Path $Path -Parent $Root)) { throw "Refusing $Label outside FarPilot root: $Path" }
    if (-not (Test-RegularDirectory $Path)) { throw "Refusing unsafe $Label path: $Path" }
}

function Assert-NoReparseTree {
    param([string]$Path, [string]$Label)
    if (-not (Test-RegularDirectory $Path)) { throw "Refusing unsafe $Label directory: $Path" }
    foreach ($entry in @(Get-ChildItem -LiteralPath $Path -Force)) {
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Refusing reparse point inside ${Label}: $($entry.FullName)"
        }
        if ($entry.PSIsContainer) {
            Assert-NoReparseTree -Path $entry.FullName -Label $Label
        } elseif (-not (Test-RegularFile $entry.FullName)) {
            throw "Refusing nonregular file inside ${Label}: $($entry.FullName)"
        }
    }
}

function Assert-FarPilotReleaseDirectoryShape {
    param([string]$Path, [string]$Kind)
    Assert-NoReparseTree -Path $Path -Label $Kind
    Get-FarPilotReleaseLayout -Path $Path -Label $Kind | Out-Null
}

function Get-FarPilotUninstallDeletionPlan {
    param([string]$Root, [string]$ReleasesDir, [string]$CurrentDir, [string]$BinDir, [string]$LockPath, [string]$InstallStatePath)
    $aliases = @()
    foreach ($aliasSpec in @(
        [PSCustomObject]@{ Path = $CurrentDir; AllowLegacy = $false },
        [PSCustomObject]@{ Path = $BinDir; AllowLegacy = $true }
    )) {
        $state = Get-JunctionState -Path $aliasSpec.Path -ReleasesDir $ReleasesDir -AllowLegacyBinary $aliasSpec.AllowLegacy
        if ($state.Kind -ne 'Missing') { $aliases += [string]$aliasSpec.Path }
    }
    $releaseEntries = @()
    if (Test-Path -LiteralPath $ReleasesDir) {
        Assert-SafeUninstallDirectory -Path $ReleasesDir -Root $Root -Label 'releases directory'
        foreach ($entry in @(Get-ChildItem -LiteralPath $ReleasesDir -Force)) {
            if (-not $entry.PSIsContainer -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "Refusing unsafe release entry during uninstall: $($entry.FullName)"
            }
            Assert-SafeUninstallDirectory -Path $entry.FullName -Root $ReleasesDir -Label 'release entry'
            if ($entry.Name -match '^[0-9]+\.[0-9]+\.[0-9]+-x86_64-pc-windows-msvc$') {
                Assert-FarPilotReleaseDirectoryShape -Path $entry.FullName -Kind 'release'
            } elseif ($entry.Name -match '^\.staging\.[0-9]+\.[0-9]+\.[0-9]+-x86_64-pc-windows-msvc\.[0-9]+$') {
                Assert-FarPilotReleaseDirectoryShape -Path $entry.FullName -Kind 'staging'
            } else {
                throw "Refusing unmanaged release directory during uninstall: $($entry.FullName)"
            }
            $releaseEntries += [string]$entry.FullName
        }
    }
    $legacyEntries = @()
    foreach ($entry in @(Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'bin.legacy.*' })) {
        if ($entry.Name -notmatch '^bin\.legacy\.[A-Fa-f0-9]{32}$') {
            throw "Refusing unmanaged legacy directory during uninstall: $($entry.FullName)"
        }
        Assert-SafeUninstallDirectory -Path $entry.FullName -Root $Root -Label 'legacy backup'
        Assert-FarPilotReleaseDirectoryShape -Path $entry.FullName -Kind 'legacy backup'
        $legacyEntries += [string]$entry.FullName
    }
    if (Test-Path -LiteralPath $LockPath) {
        if (-not (Test-RegularFile $LockPath) -or -not (Test-PathInside -Path $LockPath -Parent $Root)) {
            throw "Refusing unsafe install lock during uninstall: $LockPath"
        }
    }
    $metadata = @()
    if (Test-Path -LiteralPath $InstallStatePath) {
        if (-not (Test-RegularFile $InstallStatePath) -or -not (Test-PathInside -Path $InstallStatePath -Parent $Root)) {
            throw "Refusing unsafe install state during uninstall: $InstallStatePath"
        }
        $metadata += $InstallStatePath
    }
    return [PSCustomObject]@{
        Aliases = @($aliases)
        ReleaseEntries = @($releaseEntries)
        LegacyEntries = @($legacyEntries)
        Metadata = @($metadata)
        LockPath = $LockPath
        ReleasesDir = $ReleasesDir
    }
}

function Invoke-FarPilotUninstallQuarantine {
    param([object]$Plan)
    $targets = @($Plan.Aliases)
    if (Test-Path -LiteralPath $Plan.ReleasesDir) { $targets += [string]$Plan.ReleasesDir }
    $targets += @($Plan.LegacyEntries)
    $targets += @($Plan.Metadata)
    if (Test-Path -LiteralPath $Plan.LockPath) { $targets += [string]$Plan.LockPath }
    $seen = @{}
    $moved = @()
    try {
        foreach ($target in $targets) {
            $canonical = Get-CanonicalPath $target
            if ($seen.ContainsKey($canonical)) { continue }
            $seen[$canonical] = $true
            if (-not (Test-Path -LiteralPath $target)) { throw "Managed uninstall target changed after preflight: $target" }
            $parent = Split-Path -Parent $target
            $leaf = Split-Path -Leaf $target
            $quarantine = Join-Path $parent ('.farpilot-uninstall.' + [guid]::NewGuid().ToString('N') + '.' + $leaf)
            if (Test-Path -LiteralPath $quarantine) { throw "FarPilot uninstall quarantine collision: $quarantine" }
            Move-Item -LiteralPath $target -Destination $quarantine
            $moved += [PSCustomObject]@{ Original = $target; Quarantine = $quarantine }
            if (@($Plan.Aliases) -contains $target) { Invoke-TestFailure -Point 'DuringAliasQuarantine' }
            if ($target -ieq [string]$Plan.ReleasesDir) { Invoke-TestFailure -Point 'DuringReleaseQuarantine' }
        }
    } catch {
        $moveError = $_
        $restoreErrors = @(Restore-FarPilotUninstallQuarantine -Entries $moved)
        if ($restoreErrors.Count -ne 0) {
            throw "FarPilot quarantine failed: $($moveError.Exception.Message). Quarantine rollback failed: $($restoreErrors -join '; ')"
        }
        throw $moveError
    }
    return @($moved)
}

function Restore-FarPilotUninstallQuarantine {
    param([object[]]$Entries)
    $errors = @()
    $reverse = @($Entries)
    [array]::Reverse($reverse)
    foreach ($entry in $reverse) {
        try {
            if (Test-Path -LiteralPath $entry.Original) { throw "restore destination already exists: $($entry.Original)" }
            if (Test-Path -LiteralPath $entry.Quarantine) {
                Move-Item -LiteralPath $entry.Quarantine -Destination $entry.Original
            }
        } catch {
            $errors += $_.Exception.Message
        }
    }
    return @($errors)
}

function Invoke-FarPilotUninstallQuarantineCleanup {
    param([object[]]$Entries, [string]$FailurePoint = 'DuringUninstallCleanup')
    $errors = @()
    foreach ($entry in @($Entries)) {
        if (-not (Test-Path -LiteralPath $entry.Quarantine)) { continue }
        try {
            Invoke-TestFailure -Point $FailurePoint
            $item = Get-Item -LiteralPath $entry.Quarantine -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                Remove-Item -LiteralPath $entry.Quarantine -Force
            } elseif ($item.PSIsContainer) {
                Assert-NoReparseTree -Path $entry.Quarantine -Label 'uninstall quarantine'
                Remove-Item -LiteralPath $entry.Quarantine -Recurse -Force
            } elseif ($item.PSIsContainer -eq $false) {
                Remove-Item -LiteralPath $entry.Quarantine -Force
            }
        } catch {
            $errors += "$($entry.Quarantine): $($_.Exception.Message)"
        }
    }
    return @($errors)
}

function Invoke-FarPilotUninstall {
    param(
        [string]$Root,
        [string]$ReleasesDir,
        [string]$CurrentDir,
        [string]$BinDir,
        [string]$LockPath,
        [string]$InstallStatePath,
        [bool]$Purge,
        [bool]$Preview
    )
    Write-Warning 'Revoke FarPilot Host and device grants on the Gateway before or immediately after uninstalling.'
    if ($Preview) {
        Write-Step "Dry run: uninstall managed task, processes, PATH entries, junctions and releases under $Root"
        if ($Purge) { Write-Step 'Dry run: purge known Host identity and configuration files after confirmation' }
        return
    }
    if (-not (Test-Path -LiteralPath $Root)) {
        Write-Step 'FarPilot is already uninstalled; no managed root exists.'
        return
    }
    if (-not (Test-RegularDirectory $Root)) { throw "Refusing unsafe FarPilot root during uninstall: $Root" }
    Get-FarPilotUninstallDeletionPlan -Root $Root -ReleasesDir $ReleasesDir -CurrentDir $CurrentDir -BinDir $BinDir -LockPath $LockPath -InstallStatePath $InstallStatePath | Out-Null
    $taskState = Get-FarPilotStartupTaskState
    $pathState = Get-UserPathState
    $processState = @(Get-ManagedFarPilotProcessState)
    $lock = Enter-InstallLock $LockPath
    $deletionPlan = Get-FarPilotUninstallDeletionPlan -Root $Root -ReleasesDir $ReleasesDir -CurrentDir $CurrentDir -BinDir $BinDir -LockPath $LockPath -InstallStatePath $InstallStatePath
    $taskMutated = $false
    $pathMutated = $false
    $quarantined = @()
    $committed = $false
    try {
        try {
            $taskMutated = [bool]$taskState.Exists
            Invoke-FarPilotStartupTaskStop -State $taskState
            Invoke-ManagedFarPilotProcessStop -ProcessState $processState -ReleasesDir $ReleasesDir -ManagedAliases @($BinDir, $CurrentDir)
            $quarantined = @(Invoke-FarPilotUninstallQuarantine -Plan $deletionPlan)
            Invoke-FarPilotStartupTaskRemoval -State $taskState
            $pathMutated = $true
            Invoke-UserPathRemoval -ReleasesDir $ReleasesDir -Aliases @($CurrentDir, $BinDir)
            $committed = $true
        } catch {
            $failure = $_
            $restoreErrors = @(Restore-FarPilotUninstallQuarantine -Entries $quarantined)
            if ($pathMutated) { try { Restore-UserPath -State $pathState } catch { $restoreErrors += "PATH: $($_.Exception.Message)" } }
            if ($taskMutated) { try { Restore-FarPilotStartupTask -State $taskState } catch { $restoreErrors += "task: $($_.Exception.Message)" } }
            $remaining = @($CurrentDir, $BinDir, $ReleasesDir, $InstallStatePath) | Where-Object { Test-Path -LiteralPath $_ }
            $message = "FarPilot uninstall transaction failed: $($failure.Exception.Message). Remaining managed paths: $($remaining -join ', ')"
            if ($restoreErrors.Count -ne 0) { $message += ". Restore errors: $($restoreErrors -join '; ')" }
            throw $message
        }
    } finally {
        if ($null -ne $lock) { $lock.Dispose() }
    }
    if (-not $committed) { throw 'FarPilot uninstall did not reach commit' }
    $cleanupErrors = @(Invoke-FarPilotUninstallQuarantineCleanup -Entries $quarantined)
    $purgeCleanupErrors = @()
    $purgeQuarantine = @()
    if ($Purge) {
        $knownState = @()
        foreach ($known in @('host-identity.json', 'host.json', 'host-config.json')) {
            $path = Join-Path $Root $known
            if (Test-Path -LiteralPath $path) {
                if (-not (Test-RegularFile $path)) { throw "Refusing unsafe FarPilot state file: $path" }
                $knownState += $path
            }
        }
        if ($knownState.Count -ne 0) {
            $purgePlan = [PSCustomObject]@{
                Aliases = @($knownState); ReleaseEntries = @(); LegacyEntries = @(); Metadata = @()
                LockPath = (Join-Path $Root '.no-purge-lock'); ReleasesDir = (Join-Path $Root '.no-purge-releases')
            }
            $purgeQuarantine = @(Invoke-FarPilotUninstallQuarantine -Plan $purgePlan)
            $purgeCleanupErrors = @(Invoke-FarPilotUninstallQuarantineCleanup -Entries $purgeQuarantine -FailurePoint 'DuringPurgeCleanup')
        }
    }
    if ($purgeCleanupErrors.Count -ne 0) {
        $retainedSensitive = @($purgeQuarantine | Where-Object { Test-Path -LiteralPath $_.Quarantine } | ForEach-Object { $_.Quarantine })
        throw "FarPilot purge incomplete; sensitive state remains in protected quarantine: $($retainedSensitive -join ', '). Cleanup errors: $($purgeCleanupErrors -join '; ')"
    }
    $remainingState = @(Get-ChildItem -LiteralPath $Root -Force -ErrorAction SilentlyContinue)
    if ($remainingState.Count -eq 0) {
        Remove-Item -LiteralPath $Root -Force
    } else {
        Write-Step "Preserved FarPilot state: $($remainingState.Name -join ', ')"
    }
    Write-Step 'FarPilot uninstall completed.'
    if ($cleanupErrors.Count -ne 0) {
        Write-Warning "FarPilot uninstall completed; cleanup incomplete: $($cleanupErrors -join '; ')"
    }
}

function Invoke-OldReleaseCleanup {
    param([string]$ReleasesDir, [string]$ActiveRelease, [int]$Keep)
    if ($Keep -lt 1) { throw 'Retain must be at least 1' }
    $active = Get-CanonicalPath $ActiveRelease
    $directories = @(Get-ChildItem -LiteralPath $ReleasesDir -Directory -Force | Where-Object {
        -not $_.Name.StartsWith('.') -and (Test-RegularDirectory $_.FullName)
    } | Sort-Object LastWriteTimeUtc -Descending)
    $nonActiveKept = 0
    $nonActiveLimit = $Keep - 1
    foreach ($directory in $directories) {
        $path = Get-CanonicalPath $directory.FullName
        if ($path -ieq $active) { continue }
        if ($nonActiveKept -lt $nonActiveLimit) {
            $nonActiveKept += 1
            continue
        }
        if (Test-PathInside -Path $path -Parent $ReleasesDir) {
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }
}

if ($env:OS -ne 'Windows_NT') { throw 'install.ps1 supports Windows only' }
if (-not [Environment]::Is64BitOperatingSystem) { throw 'FarPilot requires 64-bit Windows' }
if ($Retain -lt 1) { throw 'Retain must be at least 1' }
if ($PurgeState -and -not $Uninstall) { throw 'PurgeState requires Uninstall' }

$localFields = @($LocalPackagePath, $LocalPackageVersion, $LocalPackageSha256 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
if ($localFields -notin @(0, 3)) { throw 'Local package mode requires path, version, and SHA-256 together' }
$localMode = $localFields -eq 3
$testAdapterRequested = -not [string]::IsNullOrWhiteSpace($TestStateDirectory) -or -not [string]::IsNullOrWhiteSpace($TestFailAfter)
if ($testAdapterRequested) {
    if ($env:FARPILOT_INSTALLER_TEST_MODE -cne '1') {
        throw 'FarPilot installer test adapters require FARPILOT_INSTALLER_TEST_MODE=1'
    }
    if (-not $Uninstall -and -not $localMode) {
        throw 'FarPilot installation test adapters require local-package mode'
    }
    if ([string]::IsNullOrWhiteSpace($TestStateDirectory) -or -not (Test-RegularDirectory $TestStateDirectory)) {
        throw 'TestStateDirectory must be an existing regular directory'
    }
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA) -or
        -not (Test-PathInside -Path $TestStateDirectory -Parent $env:LOCALAPPDATA)) {
        throw 'TestStateDirectory must be inside the test LOCALAPPDATA root'
    }
    $script:UseTestAdapters = $true
    $script:TestStateRoot = Get-CanonicalPath $TestStateDirectory
}

if ($Uninstall) {
    foreach ($installOnly in @('Version', 'ManifestUrl', 'NoStartupTask', 'Retain', 'LocalPackagePath', 'LocalPackageVersion', 'LocalPackageSha256')) {
        if ($PSBoundParameters.ContainsKey($installOnly)) { throw "$installOnly cannot be used with Uninstall" }
    }
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is not set' }
    if ($PurgeState) {
        $confirmation = Read-Host 'Type PURGE FARPILOT STATE to permanently remove Host identity and configuration'
        if ($confirmation -cne 'PURGE FARPILOT STATE') { throw 'PurgeState confirmation did not match' }
    }
    $uninstallRoot = Get-CanonicalPath (Join-Path $env:LOCALAPPDATA 'FarPilot')
    $uninstallReleases = Join-Path $uninstallRoot 'releases'
    $uninstallCurrent = Join-Path $uninstallRoot 'current'
    $uninstallStatePath = Join-Path $uninstallRoot 'install-state.json'
    $uninstallState = Get-FarPilotInstallState -Path $uninstallStatePath -DefaultBinDir (Join-Path $uninstallRoot 'bin')
    $uninstallTaskEvidence = Get-FarPilotStartupTaskState
    $uninstallBin = Resolve-FarPilotUninstallBinDir -InstallState $uninstallState -TaskState $uninstallTaskEvidence -DefaultBinDir (Join-Path $uninstallRoot 'bin') -CurrentDir $uninstallCurrent -ReleasesDir $uninstallReleases -LegacyHint $InstallDir
    $uninstallLock = Join-Path $uninstallRoot 'install.lock'
    Invoke-FarPilotUninstall -Root $uninstallRoot -ReleasesDir $uninstallReleases -CurrentDir $uninstallCurrent -BinDir $uninstallBin -LockPath $uninstallLock -InstallStatePath $uninstallStatePath -Purge ([bool]$PurgeState) -Preview ([bool]$DryRun)
    return
}
$requestedVersion = Normalize-Version $Version

if ($localMode) {
    $packageVersion = Normalize-Version $LocalPackageVersion
    if (-not [string]::IsNullOrWhiteSpace($requestedVersion) -and $requestedVersion -cne $packageVersion) {
        throw 'Version and LocalPackageVersion disagree'
    }
    $requestedVersion = $packageVersion
    if (-not (Test-RegularFile $LocalPackagePath)) { throw "Local FarPilot package is not a regular file: $LocalPackagePath" }
    $extension = [IO.Path]::GetExtension($LocalPackagePath).ToLowerInvariant()
    $packageFormat = if ($extension -ceq '.zip') { 'zip' } elseif ($extension -ceq '.exe') { 'exe' } else {
        throw "Local FarPilot package must be a .zip or legacy .exe file: $LocalPackagePath"
    }
    $package = [PSCustomObject]@{
        Version = $packageVersion
        Path = (Get-CanonicalPath $LocalPackagePath)
        Sha256 = $LocalPackageSha256
        Url = $null
        Format = $packageFormat
    }
    $sourceDescription = $package.Path
} else {
    if ([string]::IsNullOrWhiteSpace($ManifestUrl)) {
        if ([string]::IsNullOrWhiteSpace($requestedVersion)) {
            $ManifestUrl = 'https://farpilot.polly.wang/latest.json'
        } else {
            $ManifestUrl = "https://github.com/$RepositoryOwner/$RepositoryName/releases/download/v$requestedVersion/manifest.json"
        }
    }
    $manifestUri = $null
    if (-not [Uri]::TryCreate($ManifestUrl, [UriKind]::Absolute, [ref]$manifestUri) -or $manifestUri.Scheme -ne 'https') {
        throw 'ManifestUrl must use HTTPS'
    }
    $manifest = Get-RemoteManifest $ManifestUrl
    $remote = Get-ManifestPackage -Manifest $manifest -RequestedVersion $requestedVersion
    $package = [PSCustomObject]@{ Version = $remote.Version; Path = $null; Sha256 = $remote.Sha256; Url = $remote.Url; Format = $remote.Format }
    $requestedVersion = $remote.Version
    $sourceDescription = $remote.Url
}

if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is not set' }
if ($DryRun) {
    $plannedRoot = Get-CanonicalPath (Join-Path $env:LOCALAPPDATA 'FarPilot')
    $plannedBin = if ([string]::IsNullOrWhiteSpace($InstallDir)) { Join-Path $plannedRoot 'bin' } else { Get-CanonicalPath $InstallDir }
    $plannedRelease = Join-Path $plannedRoot "releases\$requestedVersion-$TargetTriple"
    $manifestDescription = if ($localMode) { 'local-package' } else { $ManifestUrl }
    Write-Step "Dry run: role=host target=$TargetName version=$requestedVersion manifest=$manifestDescription source=$sourceDescription release=$plannedRelease bin=$plannedBin"
    return
}

$Root = Get-CanonicalPath (Join-Path $env:LOCALAPPDATA 'FarPilot')
$ReleasesDir = Join-Path $Root 'releases'
$CurrentDir = Join-Path $Root 'current'
$BinDir = if ([string]::IsNullOrWhiteSpace($InstallDir)) { Join-Path $Root 'bin' } else { Get-CanonicalPath $InstallDir }
$ReleaseName = "$requestedVersion-$TargetTriple"
$ReleaseDir = Join-Path $ReleasesDir $ReleaseName
$ReleaseExe = Join-Path $ReleaseDir 'farpilot.exe'
$LockPath = Join-Path $Root 'install.lock'
$InstallStatePath = Join-Path $Root 'install-state.json'

New-Item -ItemType Directory -Force -Path $Root, $ReleasesDir | Out-Null
$lock = Enter-InstallLock $LockPath
Get-JunctionState -Path $CurrentDir -ReleasesDir $ReleasesDir -AllowLegacyBinary $false | Out-Null
Get-JunctionState -Path $BinDir -ReleasesDir $ReleasesDir -AllowLegacyBinary $true | Out-Null
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ('farpilot-install-' + [guid]::NewGuid().ToString('N'))
$stagingDir = Join-Path $ReleasesDir ('.staging.' + $ReleaseName + '.' + $PID)
$taskState = [PSCustomObject]@{ Exists = $false; Running = $false; Definition = $null }
try {
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    $downloadName = if ($package.Format -ceq 'zip') { 'farpilot-windows-x86_64.zip' } else { 'farpilot.exe' }
    $download = if ($localMode) { $package.Path } else { Join-Path $tempDir $downloadName }
    if (-not $localMode) { Invoke-CurlDownload -Uri $package.Url -Destination $download }
    Test-FileDigest -Path $download -Expected $package.Sha256

    if (Test-Path -LiteralPath $stagingDir) { throw "Staging path already exists: $stagingDir" }
    if ($package.Format -ceq 'zip') {
        Expand-VerifiedFarPilotPackage -ArchivePath $download -Destination $stagingDir
    } else {
        New-Item -ItemType Directory -Path $stagingDir | Out-Null
        Copy-Item -LiteralPath $download -Destination (Join-Path $stagingDir 'farpilot.exe')
        Test-FileDigest -Path (Join-Path $stagingDir 'farpilot.exe') -Expected $package.Sha256
    }
    $stagedLayout = Get-FarPilotReleaseLayout -Path $stagingDir -Label 'staged release'
    if ($stagedLayout.Format -cne $package.Format) { throw 'Staged FarPilot release format does not match the package format' }
    Assert-FarPilotReleaseBinaries -Layout $stagedLayout -ExpectedVersion $requestedVersion -Label 'Staged FarPilot release'

    $releaseExists = Test-Path -LiteralPath $ReleaseDir
    if ($releaseExists) {
        $existingLayout = Get-FarPilotReleaseLayout -Path $ReleaseDir -Label 'existing release'
        Assert-FarPilotReleaseBinaries -Layout $existingLayout -ExpectedVersion $requestedVersion -Label 'Existing FarPilot release'
        if (-not (Compare-FarPilotReleaseBytes -Expected $stagedLayout -Actual $existingLayout)) {
            throw 'Existing FarPilot release bytes differ from the verified package'
        }
    }

    # Capture every non-mutating rollback input before stopping the task or processes.
    $currentState = Get-JunctionState -Path $CurrentDir -ReleasesDir $ReleasesDir -AllowLegacyBinary $false
    $binState = Get-JunctionState -Path $BinDir -ReleasesDir $ReleasesDir -AllowLegacyBinary $true
    $taskState = Get-FarPilotStartupTaskState
    $pathState = Get-UserPathState
    $processState = @(Get-ManagedFarPilotProcessState)
    $installState = Get-FarPilotInstallState -Path $InstallStatePath -DefaultBinDir (Join-Path $Root 'bin')

    $releaseCreated = $false
    $taskStopAttempted = $false
    $currentAttempted = $false
    $binAttempted = $false
    $pathAttempted = $false
    $installStateAttempted = $false
    try {
        $taskStopAttempted = $true
        Invoke-FarPilotStartupTaskStop $taskState
        Invoke-ManagedFarPilotProcessStop -ProcessState $processState -ReleasesDir $ReleasesDir -ManagedAliases @($BinDir, $CurrentDir)
        if (-not $releaseExists) {
            Move-Item -LiteralPath $stagingDir -Destination $ReleaseDir
            $releaseCreated = $true
        }
        $currentAttempted = $true
        $currentState = Invoke-ManagedJunctionActivation -Path $CurrentDir -Target $ReleaseDir -State $currentState -Root $Root
        Invoke-TestFailure -Point 'AfterCurrentJunction'
        $binAttempted = $true
        $binState = Invoke-ManagedJunctionActivation -Path $BinDir -Target $ReleaseDir -State $binState -Root $Root
        Invoke-TestFailure -Point 'AfterBinJunction'
        $pathAttempted = $true
        Invoke-UserPathUpdate -Entry $ReleaseDir -ReleasesDir $ReleasesDir -Aliases @($CurrentDir, $BinDir)
        Invoke-FarPilotStartupTaskUpdate -Executable (Join-Path $BinDir 'farpilot.exe') -PreviousState $taskState -CreateTask (-not $NoStartupTask)
        $installStateAttempted = $true
        Write-FarPilotInstallState -Path $InstallStatePath -VisibleBin $BinDir
    } catch {
        $activationError = $_
        $rollbackErrors = @()
        if ($installStateAttempted) {
            try { Restore-FarPilotInstallState -Path $InstallStatePath -State $installState } catch { $rollbackErrors += "install state: $($_.Exception.Message)" }
        }
        if ($taskStopAttempted) {
            try { Restore-FarPilotStartupTask -State $taskState } catch { $rollbackErrors += "startup task: $($_.Exception.Message)" }
        }
        if ($pathAttempted) {
            try { Restore-UserPath -State $pathState } catch { $rollbackErrors += "user PATH: $($_.Exception.Message)" }
        }
        if ($binAttempted) {
            try { Restore-ManagedJunction -Path $BinDir -State $binState } catch { $rollbackErrors += "bin junction: $($_.Exception.Message)" }
        }
        if ($currentAttempted) {
            try { Restore-ManagedJunction -Path $CurrentDir -State $currentState } catch { $rollbackErrors += "current junction: $($_.Exception.Message)" }
        }
        if ($releaseCreated -and $rollbackErrors.Count -eq 0 -and (Test-RegularDirectory $ReleaseDir)) {
            $releaseReferenced = (Test-JunctionReleaseReference -Path $CurrentDir -ReleaseDir $ReleaseDir) -or
                (Test-JunctionReleaseReference -Path $BinDir -ReleaseDir $ReleaseDir)
            if ($releaseReferenced) {
                $rollbackErrors += 'new release cleanup refused because a managed alias still references it'
            } else {
                try { Remove-Item -LiteralPath $ReleaseDir -Recurse -Force } catch { $rollbackErrors += "new release cleanup: $($_.Exception.Message)" }
            }
        }
        if ($rollbackErrors.Count -ne 0) {
            throw "FarPilot activation failed: $($activationError.Exception.Message). Rollback also failed: $($rollbackErrors -join '; ')"
        }
        throw $activationError
    }

    # Activation is committed. Cleanup is best-effort and must not roll back a healthy release.
    $cleanupErrors = @()
    foreach ($state in @($currentState, $binState)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$state.Backup) -and (Test-Path -LiteralPath $state.Backup)) {
            try {
                Invoke-TestFailure -Point 'DuringCleanup'
                $backupName = Split-Path -Leaf $state.Backup
                if (-not (Test-PathInside -Path $state.Backup -Parent $Root) -or
                    $backupName -notlike 'bin.legacy.*' -or -not (Test-RegularDirectory $state.Backup)) {
                    throw "Refusing unsafe legacy backup cleanup: $($state.Backup)"
                }
                Remove-Item -LiteralPath $state.Backup -Recurse -Force
            } catch {
                $cleanupErrors += "legacy backup: $($_.Exception.Message)"
            }
        }
    }
    try {
        (Get-Item -LiteralPath $ReleaseDir).LastWriteTimeUtc = [DateTime]::UtcNow
        Invoke-OldReleaseCleanup -ReleasesDir $ReleasesDir -ActiveRelease $ReleaseDir -Keep $Retain
    } catch {
        $cleanupErrors += "release retention: $($_.Exception.Message)"
    }
    Write-Step "Installed FarPilot $requestedVersion to $ReleaseExe"
    if ($cleanupErrors.Count -ne 0) {
        Write-Warning "FarPilot installed successfully; cleanup incomplete: $($cleanupErrors -join '; ')"
    }
    Write-Output 'FarPilot opens no inbound port and creates no firewall rule.'
} finally {
    Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    if ($null -ne $lock) { $lock.Dispose() }
}

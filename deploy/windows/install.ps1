[CmdletBinding()]
param(
    [string]$Version,
    [string]$ManifestUrl,
    [string]$InstallDir,
    [switch]$NoStartupTask,
    [switch]$DryRun,
    [int]$Retain = 3,
    [string]$LocalPackagePath,
    [string]$LocalPackageVersion,
    [string]$LocalPackageSha256,
    [switch]$SkipPathMutation,
    [switch]$SkipProcessManagement,
    [switch]$SkipStartupTaskOperations
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$TargetTriple = 'x86_64-pc-windows-msvc'
$TargetName = 'windows-x86_64'
$RepositoryOwner = 'Polly2014'
$RepositoryName = 'FarPilot'
$TaskName = 'FarPilot Host'

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message"
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
    param([string]$Path)
    $output = & $Path --version 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "FarPilot executable failed --version: $Path"
    }
    $line = $output.Trim()
    if ($line -notmatch '^farpilot ([0-9]+\.[0-9]+\.[0-9]+)$') {
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

function Assert-ExactProperties {
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
    Assert-ExactProperties -Value $Manifest -Expected @('schema_version', 'version', 'tag', 'assets', 'installers') -Label 'FarPilot manifest'
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
    Assert-ExactProperties -Value $assetsProperty.Value -Expected @(
        'linux-x86_64', 'linux-aarch64', 'macos-x86_64', 'macos-aarch64', 'windows-x86_64'
    ) -Label 'FarPilot manifest assets'
    Assert-ExactProperties -Value $Manifest.installers -Expected @('gateway') -Label 'FarPilot manifest installers'
    Assert-ExactProperties -Value $Manifest.installers.gateway -Expected @('url', 'sha256') -Label 'FarPilot gateway installer'
    $assetProperty = $assetsProperty.Value.PSObject.Properties[$TargetName]
    if ($null -eq $assetProperty -or $null -eq $assetProperty.Value) {
        throw "FarPilot manifest has no $TargetName asset"
    }
    $asset = $assetProperty.Value
    Assert-ExactProperties -Value $asset -Expected @('url', 'sha256', 'format') -Label 'FarPilot Windows asset'
    if ([string]$asset.format -cne 'exe') {
        throw 'FarPilot Windows manifest asset must use exe format'
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
        $segments[4] -cne "v$manifestVersion" -or $segments[5] -cne 'farpilot-windows-x86_64.exe') {
        throw 'FarPilot Windows manifest asset URL has an invalid Release path'
    }
    return [PSCustomObject]@{ Version = $manifestVersion; Url = $url; Sha256 = $sha }
}

function Enter-InstallLock {
    param([string]$Path, [int]$TimeoutMilliseconds = 5000)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    while ($true) {
        try {
            return [IO.File]::Open($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
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
        if (-not (Test-PathInside -Path $target -Parent $ReleasesDir)) {
            throw "Refusing FarPilot junction outside managed releases: $Path -> $target"
        }
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

function Set-ManagedJunction {
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

function Stop-ManagedFarPilotProcesses {
    param([string]$ReleasesDir)
    $processes = Get-CimInstance Win32_Process -Filter "Name = 'farpilot.exe'" -ErrorAction SilentlyContinue
    foreach ($process in @($processes)) {
        $path = [string]$process.ExecutablePath
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-PathInside -Path $path -Parent $ReleasesDir)) {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
        }
    }
}

function Get-FarPilotStartupTaskState {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        return [PSCustomObject]@{ Exists = $false; Running = $false; Definition = $null }
    }
    return [PSCustomObject]@{
        Exists = $true
        Running = ($task.State -eq 'Running')
        Definition = $task
    }
}

function Stop-FarPilotStartupTask {
    param([object]$State)
    if ($State.Exists -and $State.Running) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    }
}

function Set-FarPilotStartupTask {
    param([string]$Executable, [object]$PreviousState, [bool]$CreateTask)
    if (-not $CreateTask -and -not $PreviousState.Exists) { return }
    $action = New-ScheduledTaskAction -Execute $Executable -Argument 'host start'
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
    if ($PreviousState.Running) {
        Start-ScheduledTask -TaskName $TaskName
    }
}

function Restore-FarPilotStartupTask {
    param([object]$State)
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

function Update-UserPath {
    param([string]$Entry, [string]$ReleasesDir, [string[]]$Aliases)
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

function Remove-OldReleases {
    param([string]$ReleasesDir, [string]$ActiveRelease, [int]$Keep)
    if ($Keep -lt 1) { throw 'Retain must be at least 1' }
    $active = Get-CanonicalPath $ActiveRelease
    $directories = @(Get-ChildItem -LiteralPath $ReleasesDir -Directory -Force | Where-Object {
        -not $_.Name.StartsWith('.') -and (Test-RegularDirectory $_.FullName)
    } | Sort-Object LastWriteTimeUtc -Descending)
    $kept = 0
    foreach ($directory in $directories) {
        $path = Get-CanonicalPath $directory.FullName
        if ($path -ieq $active) {
            $kept += 1
            continue
        }
        if ($kept -lt $Keep) {
            $kept += 1
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

$localFields = @($LocalPackagePath, $LocalPackageVersion, $LocalPackageSha256 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
if ($localFields -notin @(0, 3)) { throw 'Local package mode requires path, version, and SHA-256 together' }
$localMode = $localFields -eq 3
$requestedVersion = Normalize-Version $Version

if ($localMode) {
    $packageVersion = Normalize-Version $LocalPackageVersion
    if (-not [string]::IsNullOrWhiteSpace($requestedVersion) -and $requestedVersion -cne $packageVersion) {
        throw 'Version and LocalPackageVersion disagree'
    }
    $requestedVersion = $packageVersion
    if (-not (Test-RegularFile $LocalPackagePath)) { throw "Local FarPilot package is not a regular file: $LocalPackagePath" }
    $package = [PSCustomObject]@{ Version = $packageVersion; Path = (Get-CanonicalPath $LocalPackagePath); Sha256 = $LocalPackageSha256; Url = $null }
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
    $package = [PSCustomObject]@{ Version = $remote.Version; Path = $null; Sha256 = $remote.Sha256; Url = $remote.Url }
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

New-Item -ItemType Directory -Force -Path $Root, $ReleasesDir | Out-Null
$lock = Enter-InstallLock $LockPath
Get-JunctionState -Path $CurrentDir -ReleasesDir $ReleasesDir -AllowLegacyBinary $false | Out-Null
Get-JunctionState -Path $BinDir -ReleasesDir $ReleasesDir -AllowLegacyBinary $true | Out-Null
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ('farpilot-install-' + [guid]::NewGuid().ToString('N'))
$stagingDir = Join-Path $ReleasesDir ('.staging.' + $ReleaseName + '.' + $PID)
$taskState = [PSCustomObject]@{ Exists = $false; Running = $false; Definition = $null }
try {
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    $download = if ($localMode) { $package.Path } else { Join-Path $tempDir 'farpilot.exe' }
    if (-not $localMode) { Invoke-CurlDownload -Uri $package.Url -Destination $download }
    Test-FileDigest -Path $download -Expected $package.Sha256
    Test-AuthenticodePolicy $download
    $reported = Get-ExecutableVersion $download
    if ($reported -cne $requestedVersion) { throw "FarPilot binary version $reported does not match $requestedVersion" }

    $releaseExists = Test-Path -LiteralPath $ReleaseDir
    if ($releaseExists) {
        if (-not (Test-RegularDirectory $ReleaseDir)) { throw "Existing FarPilot release path is unsafe: $ReleaseDir" }
        $entries = @(Get-ChildItem -LiteralPath $ReleaseDir -Force)
        if ($entries.Count -ne 1 -or $entries[0].Name -ine 'farpilot.exe' -or -not (Test-RegularFile $ReleaseExe)) {
            throw "Existing FarPilot release is incomplete or unmanaged: $ReleaseDir"
        }
        $existingVersion = Get-ExecutableVersion $ReleaseExe
        if ($existingVersion -cne $requestedVersion) { throw "Existing release has wrong version: $existingVersion" }
    } else {
        if (Test-Path -LiteralPath $stagingDir) { throw "Staging path already exists: $stagingDir" }
        New-Item -ItemType Directory -Path $stagingDir | Out-Null
        Copy-Item -LiteralPath $download -Destination (Join-Path $stagingDir 'farpilot.exe')
        $stagedExe = Join-Path $stagingDir 'farpilot.exe'
        Test-FileDigest -Path $stagedExe -Expected $package.Sha256
        if ((Get-ExecutableVersion $stagedExe) -cne $requestedVersion) { throw 'Staged FarPilot version changed during copy' }
        Move-Item -LiteralPath $stagingDir -Destination $ReleaseDir
    }

    $currentState = Get-JunctionState -Path $CurrentDir -ReleasesDir $ReleasesDir -AllowLegacyBinary $false
    $binState = Get-JunctionState -Path $BinDir -ReleasesDir $ReleasesDir -AllowLegacyBinary $true
    $pathState = $null

    if (-not $SkipStartupTaskOperations) {
        $taskState = Get-FarPilotStartupTaskState
        Stop-FarPilotStartupTask $taskState
    }
    if (-not $SkipProcessManagement) { Stop-ManagedFarPilotProcesses $ReleasesDir }
    if (-not $SkipPathMutation) { $pathState = Get-UserPathState }

    $currentAttempted = $false
    $binAttempted = $false
    $pathAttempted = $false
    $taskAttempted = $false
    try {
        $currentAttempted = $true
        $currentState = Set-ManagedJunction -Path $CurrentDir -Target $ReleaseDir -State $currentState -Root $Root
        $binAttempted = $true
        $binState = Set-ManagedJunction -Path $BinDir -Target $ReleaseDir -State $binState -Root $Root
        if (-not $SkipPathMutation) {
            $pathAttempted = $true
            Update-UserPath -Entry $ReleaseDir -ReleasesDir $ReleasesDir -Aliases @($CurrentDir, $BinDir)
        }
        if (-not $SkipStartupTaskOperations) {
            $taskAttempted = $true
            Set-FarPilotStartupTask -Executable (Join-Path $BinDir 'farpilot.exe') -PreviousState $taskState -CreateTask (-not $NoStartupTask)
        }
    } catch {
        $activationError = $_
        $rollbackErrors = @()
        if ($taskAttempted) {
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
        if (-not $releaseExists -and $rollbackErrors.Count -eq 0 -and (Test-RegularDirectory $ReleaseDir)) {
            try { Remove-Item -LiteralPath $ReleaseDir -Recurse -Force } catch { $rollbackErrors += "new release cleanup: $($_.Exception.Message)" }
        }
        if ($rollbackErrors.Count -ne 0) {
            throw "FarPilot activation failed: $($activationError.Exception.Message). Rollback also failed: $($rollbackErrors -join '; ')"
        }
        throw $activationError
    }

    foreach ($state in @($currentState, $binState)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$state.Backup) -and (Test-Path -LiteralPath $state.Backup)) {
            Remove-Item -LiteralPath $state.Backup -Recurse -Force
        }
    }
    (Get-Item -LiteralPath $ReleaseDir).LastWriteTimeUtc = [DateTime]::UtcNow
    Remove-OldReleases -ReleasesDir $ReleasesDir -ActiveRelease $ReleaseDir -Keep $Retain
    Write-Step "Installed FarPilot $requestedVersion to $ReleaseExe"
    Write-Host 'FarPilot opens no inbound port and creates no firewall rule.'
} finally {
    Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    if ($null -ne $lock) { $lock.Dispose() }
}

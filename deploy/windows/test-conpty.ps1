$ErrorActionPreference = 'Stop'

$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Push-Location $ProjectRoot
try {
    cargo test -p farpilot-host --test windows_conpty -- --nocapture
    if ($LASTEXITCODE -ne 0) {
        throw "FarPilot Windows ConPTY validation failed with exit code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}

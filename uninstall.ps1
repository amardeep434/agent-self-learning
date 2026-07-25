# uninstall.ps1 — Windows wrapper. Requires Git for Windows (bash) or WSL.
# Same bash-resolution caveat as install.ps1: the first `bash` on PATH may be
# WSL's launcher, which would operate on a different filesystem and a
# different $HOME. scripts/lib/find-bash.ps1 probes for that functionally.
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $repoRoot "scripts/lib/find-bash.ps1")

$scriptPath = ($repoRoot -replace '\\', '/') + "/uninstall.sh"

try {
    $bashExe = Resolve-DelegableBash -ScriptPath $scriptPath
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}

& $bashExe $scriptPath @args
exit $LASTEXITCODE

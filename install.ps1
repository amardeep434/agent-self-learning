# install.ps1 — Windows wrapper. Requires Git for Windows (bash) or WSL.
# All installation logic lives in install.sh; this locates bash and delegates.
#
# "Locates bash" is doing real work here: the first `bash` on a Windows PATH
# may be WSL's launcher, which cannot see this repo's Windows path at all
# and whose $HOME is a different user's. scripts/lib/find-bash.ps1 probes
# for that functionally (never by filename) and fails with an explanation
# rather than delegating into the wrong filesystem. See its header.
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $repoRoot "scripts/lib/find-bash.ps1")

# Forward slashes throughout: Git Bash accepts 'C:/repo/install.sh' as-is,
# and a mixed 'C:\repo/install.sh' is needlessly harder to read in the error
# message the probe may print.
$scriptPath = ($repoRoot -replace '\\', '/') + "/install.sh"

try {
    $bashExe = Resolve-DelegableBash -ScriptPath $scriptPath
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}

& $bashExe $scriptPath @args
exit $LASTEXITCODE

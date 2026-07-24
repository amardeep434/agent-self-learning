# install.ps1 — Windows wrapper. Requires Git for Windows (bash) or WSL.
# All installation logic lives in install.sh; this locates bash and delegates.
$ErrorActionPreference = "Stop"

$bash = Get-Command bash -ErrorAction SilentlyContinue
if (-not $bash) {
    Write-Error @"
bash was not found on PATH. Install one of:
  - Git for Windows (https://git-scm.com/download/win) — provides Git Bash
  - WSL (wsl --install) — then run 'bash install.sh' inside WSL instead
Then re-run: .\install.ps1
"@
    exit 1
}

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
& $bash.Source "$repoRoot/install.sh" @args
exit $LASTEXITCODE

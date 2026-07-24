# uninstall.ps1 — Windows wrapper. Requires Git for Windows (bash) or WSL.
$ErrorActionPreference = "Stop"
$bash = Get-Command bash -ErrorAction SilentlyContinue
if (-not $bash) { Write-Error "bash not found on PATH (install Git for Windows or WSL)."; exit 1 }
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
& $bash.Source "$repoRoot/uninstall.sh" @args
exit $LASTEXITCODE

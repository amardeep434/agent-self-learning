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

# Python is probed here as well as in install.sh, for the message only: without
# it the failure surfaces from inside bash, several layers down, in whichever
# terminal the user is NOT looking at. Same discipline as the bash probe above:
# functional, never by name. `Get-Command python3` is not the question -- the
# python.org/winget installers create python.exe and the py launcher and never a
# python3, while Windows' Microsoft-Store App Execution Alias creates a
# python3.exe that exists and is not Python. So each candidate must RUN and
# report Python 3. Plain single-quoted literals only (see find-bash.ps1's
# STYLE NOTE).
function Test-PythonCandidate {
    param(
        [Parameter(Mandatory = $true)] [string] $Exe,
        [string[]] $Prefix = @()
    )
    if (-not (Get-Command $Exe -ErrorAction SilentlyContinue)) { return $false }
    try {
        $out = & $Exe @Prefix '--version' 2>&1
    }
    catch {
        return $false
    }
    if ($LASTEXITCODE -ne 0) { return $false }
    return (($out | Out-String) -match 'Python 3')
}

$pythonOk = (Test-PythonCandidate -Exe 'python3') -or
            (Test-PythonCandidate -Exe 'python') -or
            (Test-PythonCandidate -Exe 'py' -Prefix @('-3'))

if (-not $pythonOk) {
    $noPython = @(
        'No working Python 3 was found. Tried, in order: python3, python, py -3.',
        'Each was run with --version and had to report Python 3 -- a name on PATH is',
        'not enough.',
        '',
        'Install it with:',
        '    winget install Python.Python.3.12',
        '',
        'If python3 APPEARS to exist but prints nothing and opens the Microsoft Store,',
        'that is the Store App Execution Alias, not Python. Turn it off under',
        'Settings > Apps > Advanced app settings > App execution aliases, or just',
        'install Python properly with the command above.'
    )
    Write-Error ($noPython -join [Environment]::NewLine)
    exit 1
}

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

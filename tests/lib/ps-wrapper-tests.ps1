# tests/lib/ps-wrapper-tests.ps1
#
# BEHAVIOURAL tests for scripts/lib/find-bash.ps1, run wherever pwsh exists.
#
# Parse-checking proves the file is syntactically valid. It says nothing
# about whether the resolver actually accepts a usable bash and refuses an
# unusable one -- and that decision is the entire point of the file. GitHub's
# ubuntu runners ship pwsh, so this logic CAN be executed in CI even though
# there is no Windows PowerShell job: the resolver's two branches are
# platform-independent (it asks whichever bash it found whether it can see a
# given path), so exercising them on Linux tests the real code, not a
# simulation of it.
#
# CORRECTION OF RECORD (2026-07-26). The paragraph that used to sit here
# said the Windows-specific half "cannot" be covered "without Windows", and
# the residual it fed said this was untestable without adding a PowerShell
# CI job. Both were wrong, and the proof was already in the CI log:
# windows-latest runs `bash tests/run-all.sh`, tests/test-ps1-wrappers.sh
# probes for pwsh, and on run 30177841369 that probe printed
# "[capability probe] pwsh: AVAILABLE (7.6.3)" followed by "All ps1-wrapper
# tests passed" on BOTH windows-latest cells. So this file has been running
# on Windows all along. GitHub documents pwsh as the DEFAULT shell on
# Windows runners, so a dedicated `shell: pwsh` job would add a seventh CI
# cell that duplicates coverage that already exists.
#
# What was genuinely missing is what this file ASSERTED on Windows: nothing
# platform-specific. The WINDOWS-ONLY block at the bottom closes that. It
# classifies every bash on PATH functionally (`uname -s`: MINGW*/MSYS*/
# CYGWIN* is Git Bash, plain "Linux" on a Windows host is WSL) rather than
# by filename or a System32 match, and asserts the resolver never hands back
# a WSL bash for a Windows-style repo path.
#
# Exit code: number of failed checks (0 = all passed).

param(
    [Parameter(Mandatory = $true)]
    [string] $RepoRoot
)

$script:failures = 0

function Check {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][bool] $Ok
    )
    if ($Ok) {
        Write-Output ('PASS: ' + $Name)
    }
    else {
        Write-Output ('FAIL: ' + $Name)
        $script:failures = $script:failures + 1
    }
}

. (Join-Path $RepoRoot 'scripts/lib/find-bash.ps1')

$resolverCommand = Get-Command Resolve-DelegableBash -ErrorAction SilentlyContinue
Check 'find-bash.ps1 defines Resolve-DelegableBash' ($null -ne $resolverCommand)

# 1) A script this bash CAN see must resolve to a usable interpreter.
$visible = Join-Path $RepoRoot 'install.sh'
$resolved = $null
$acceptError = ''
try {
    $resolved = Resolve-DelegableBash -ScriptPath $visible
}
catch {
    $acceptError = $_.Exception.Message
}
Check 'resolver accepts a bash that can see the script' ($null -ne $resolved)
if ($null -eq $resolved -and $acceptError -ne '') {
    Write-Output ('  (refusal was: ' + $acceptError.Split([Environment]::NewLine)[0] + ')')
}
if ($null -ne $resolved) {
    Check 'resolver returns a path that exists' (Test-Path -LiteralPath $resolved)
}

# 2) A script NO bash can see must throw -- never return a bash that would
#    then be handed a path it cannot open. This is the WSL case's shape.
$threw = $false
$message = ''
try {
    Resolve-DelegableBash -ScriptPath '/hnp-definitely-not-here/install.sh' | Out-Null
}
catch {
    $threw = $true
    $message = $_.Exception.Message
}
Check 'resolver refuses a script the found bash cannot see' $threw

# 3) The refusal has to be diagnosable: it must name the bash it found and
#    the path it could not see, and explain the WSL cause.
Check 'refusal names the script path it could not see' ($message -like '*hnp-definitely-not-here*')
Check 'refusal names WSL as the usual cause' ($message -like '*WSL*')

# The first version of find-bash.ps1 wrote "\$HOME" with a backslash inside a
# double-quoted here-string. Backslash is not PowerShell's escape character,
# so that expanded the caller's real home directory into the middle of an
# error message. Guarded against here rather than only fixed once.
if ($HOME -and $HOME.Length -gt 3) {
    $leaked = $message -like ('*' + $HOME + '*')
    Check 'refusal does not leak an expanded HOME into the message' (-not $leaked)
}
else {
    Write-Output 'SKIP: HOME too short to test for leakage (reported, not silently passed)'
}

# --------------------------------------------------------------------------
# WINDOWS-ONLY: the ambiguity this resolver exists for
# --------------------------------------------------------------------------
# On Windows, PATH can contain more than one bash, and they are not
# interchangeable:
#
#   Git for Windows bash  -- MSYS2. `uname -s` reports MINGW64_NT-* or
#                            MSYS_NT-*. Sees C:\repo as C:/repo. Correct.
#   C:\Windows\System32\bash.exe -- WSL's launcher. `uname -s` reports
#                            "Linux" because it IS Linux. The same directory
#                            is /mnt/c/repo there, and $HOME belongs to the
#                            WSL user.
#
# `uname -s` is the reliable discriminator; the System32 LOCATION is not,
# because it both misses WSL shims installed elsewhere and would wrongly
# reject an unusual-but-working bash. Nor is $WSL_DISTRO_NAME, which is set
# inside a WSL shell and says nothing about a bash we are only invoking.
#
# On non-Windows this whole block is skipped and says so.
if ($IsWindows) {
    $candidates = @(Get-Command bash -All -ErrorAction SilentlyContinue)
    Write-Output ('[windows] bash candidates on PATH: ' + $candidates.Count)

    $wslPaths = @()
    foreach ($candidate in $candidates) {
        $kernel = ''
        try {
            $kernel = (& $candidate.Source -c 'uname -s' 2>$null | Select-Object -First 1)
        }
        catch {
            $kernel = 'unavailable'
        }
        if ($null -eq $kernel) { $kernel = 'unavailable' }
        $kernel = ([string]$kernel).Trim()
        $flavour = 'unknown'
        if ($kernel -like 'MINGW*' -or $kernel -like 'MSYS*' -or $kernel -like 'CYGWIN*') {
            $flavour = 'git-bash'
        }
        elseif ($kernel -eq 'Linux') {
            $flavour = 'wsl'
            $wslPaths += $candidate.Source
        }
        Write-Output ('[windows]   ' + $candidate.Source + '  uname -s=' + $kernel + '  -> ' + $flavour)
    }

    $system32Bash = Join-Path $env:SystemRoot 'System32\bash.exe'
    Write-Output ('[windows] System32 bash present: ' + (Test-Path -LiteralPath $system32Bash))

    # THE assertion. Whatever the resolver returned for a real repo path on
    # this machine, it must not be a bash whose filesystem is WSL's -- that
    # is the silent-wrong-location failure the whole guard exists to stop.
    if ($null -ne $resolved) {
        $resolvedIsWsl = $false
        foreach ($wslPath in $wslPaths) {
            if ($resolved -eq $wslPath) { $resolvedIsWsl = $true }
        }
        Check 'resolver did not return a WSL bash for a Windows repo path' (-not $resolvedIsWsl)
    }

    # And the resolver must have picked SOMETHING, because Git for Windows
    # ships with every GitHub windows-latest runner. A refusal here means
    # the probe itself is broken on Windows -- the case that would otherwise
    # only surface as a user's failed install.
    Check 'resolver found a usable bash on Windows' ($null -ne $resolved)
}
else {
    Write-Output ('SKIP: Windows-only bash-flavour checks (this host is not Windows; ' +
        'they DO run on CI''s windows-latest cells, where pwsh is present)')
}

exit $script:failures

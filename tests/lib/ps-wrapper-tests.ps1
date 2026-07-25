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
# What this still does NOT cover, and cannot without Windows: that the bash
# found FIRST on a Windows PATH is the WSL stub, and that the stub's
# filesystem view is what makes the probe fail there. The probe mechanism is
# tested; the Windows-specific PATH ordering that makes it necessary is not.
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

exit $script:failures

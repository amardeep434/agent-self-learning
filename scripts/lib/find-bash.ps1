# find-bash.ps1 — locate a bash that can actually run this repo's scripts.
#
# WHY THIS EXISTS
# ---------------
# install.ps1/uninstall.ps1 do nothing themselves; they hand a Windows-style
# repo path to whatever `bash` is first on PATH. On Windows there are at
# least two very different things that can be:
#
#   * Git for Windows' bash (MSYS2)  — sees C:\repo as C:/repo. Correct.
#   * C:\Windows\System32\bash.exe   — WSL's launcher stub. It runs a Linux
#     bash inside a Linux filesystem where C:\repo does not exist (the same
#     directory is /mnt/c/repo) and where $HOME, $XDG_DATA_HOME and the
#     detected harnesses are the WSL user's, not the Windows user's.
#
# Handing the second one a Windows path is the silent-wrong-location class
# this project exists to eliminate: at best the script is "not found"; at
# worst a path that happens to resolve installs the framework into the WSL
# home while the user is looking at their Windows one.
#
# THE CHECK IS FUNCTIONAL, NOT NAME-BASED
# ---------------------------------------
# We do not decide by the interpreter's filename or its directory. This
# project has been wrong about what a platform/name implies before (Windows
# *can* create symlinks; `os.supports_dir_fd` misreports `os.replace`), and
# a name check here would both miss non-System32 WSL shims and wrongly
# reject a perfectly good bash installed somewhere unusual. Instead we ask
# the bash we found the only question that matters — "can you see the script
# I am about to hand you?" — by running `test -f` on the exact argument
# install.ps1 would pass. A bash whose filesystem view does not include the
# repo path fails that, whoever it is.
#
# NOT EXECUTED ON WINDOWS BY THE AUTHOR: this repository's CI has no
# PowerShell job, and this was written on Linux. The logic is deliberately
# small enough to audit by reading: one Get-Command, one `bash -c 'test -f'`
# probe, and a message. It cannot make the previous behaviour worse — the
# only new failure mode it introduces is refusing to run under a bash that
# demonstrably cannot open the installer.

function Resolve-DelegableBash {
    param(
        [Parameter(Mandatory = $true)][string] $ScriptPath
    )

    $bash = Get-Command bash -ErrorAction SilentlyContinue
    if (-not $bash) {
        throw @"
bash was not found on PATH. Install one of:
  - Git for Windows (https://git-scm.com/download/win) - provides Git Bash
  - WSL (wsl --install) - then run 'bash $([System.IO.Path]::GetFileName($ScriptPath))' inside WSL instead
"@
    }

    # Functional probe: can THIS bash open the script we are about to run?
    # stdout/stderr are discarded; only the exit status is meaningful.
    & $bash.Source -c 'test -f "$1"' -- $ScriptPath 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw @"
The 'bash' found on PATH cannot see this repository's files, so running the
installer through it would either fail or install into the wrong place.

  bash found at : $($bash.Source)
  script path   : $ScriptPath

The usual cause is that 'bash' is WSL's launcher (typically
$env:SystemRoot\System32\bash.exe), which runs inside the WSL filesystem
where this path does not exist - the same directory is reached as
/mnt/<drive>/... there, and \$HOME is the WSL user's home, not your Windows one.

Fix by either:
  - Installing Git for Windows and re-running from a shell whose PATH finds
    its bash first (e.g. "C:\Program Files\Git\bin\bash.exe"), or
  - Running the installer inside WSL directly:
        wsl bash /mnt/c/path/to/repo/$([System.IO.Path]::GetFileName($ScriptPath))
    which installs for the WSL user, deliberately rather than by accident.
"@
    }

    return $bash.Source
}

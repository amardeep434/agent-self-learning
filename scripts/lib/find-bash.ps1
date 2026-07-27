# find-bash.ps1 -- locate a bash that can actually run this repo's scripts.
#
# WHY THIS EXISTS
# ---------------
# install.ps1/uninstall.ps1 do nothing themselves; they hand a Windows-style
# repo path to whatever `bash` is first on PATH. On Windows there are at
# least two very different things that can be:
#
#   * Git for Windows' bash (MSYS2)  -- sees C:\repo as C:/repo. Correct.
#   * C:\Windows\System32\bash.exe   -- WSL's launcher stub. It runs a Linux
#     bash inside a Linux filesystem where C:\repo does not exist (the same
#     directory is /mnt/c/repo) and where HOME, XDG_DATA_HOME and the
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
# *can* create symlinks; os.supports_dir_fd misreports os.replace), and a
# name check here would both miss non-System32 WSL shims and wrongly reject
# a perfectly good bash installed somewhere unusual. Instead we ask the bash
# we found the only question that matters -- "can you see the script I am
# about to hand you?" -- by running `test -f` on the exact argument
# install.ps1 would pass. A bash whose filesystem view does not include the
# repo path fails that, whoever it is.
#
# STYLE NOTE (fix-p9): deliberately plain. No here-strings, no interpolation
# inside messages, no escapes -- every message is built from single-quoted
# literals joined with a newline. The first version used double-quoted
# here-strings; when CI reported a parse error the real cause turned out to
# be the CHECK rather than this file, but the here-strings did carry a
# genuine defect: a "\$HOME" written with a backslash, which is not
# PowerShell's escape character (that is a backtick), so it expanded the
# caller's real $HOME into the middle of an error message. Plain literals
# cannot do either thing. This file is parse-checked in CI on every push --
# see tests/test-ps1-wrappers.sh and tests/lib/ps-parse-check.ps1.

function Resolve-DelegableBash {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ScriptPath
    )

    $scriptName = [System.IO.Path]::GetFileName($ScriptPath)

    $bash = Get-Command bash -ErrorAction SilentlyContinue
    if (-not $bash) {
        $missing = @(
            'bash was not found on PATH. Install one of:',
            '  - Git for Windows (https://git-scm.com/download/win), which provides Git Bash',
            '  - WSL (wsl --install), and then run this inside WSL instead:',
            ('        bash ' + $scriptName)
        )
        throw ($missing -join [Environment]::NewLine)
    }

    # Functional probe: can THIS bash open the script we are about to run?
    # Output is discarded; only the exit status is meaningful.
    & $bash.Source -c 'test -f "$1"' -- $ScriptPath 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $blind = @(
            'The bash found on PATH cannot see this repository, so running the installer',
            'through it would either fail outright or install into the wrong place.',
            '',
            ('  bash found at : ' + $bash.Source),
            ('  script path   : ' + $ScriptPath),
            '',
            'The usual cause is that bash is the WSL launcher stub, normally at',
            'C:\Windows\System32\bash.exe. It runs inside the WSL filesystem, where this',
            'path does not exist (the same directory is reached as /mnt/<drive>/... there)',
            'and where HOME belongs to the WSL user, not to your Windows user.',
            '',
            'Fix by either:',
            '  - Installing Git for Windows and re-running from a shell whose PATH finds',
            '    its bash first, normally C:\Program Files\Git\bin\bash.exe, or',
            '  - Running the installer inside WSL on purpose:',
            ('        wsl bash /mnt/c/path/to/repo/' + $scriptName)
        )
        throw ($blind -join [Environment]::NewLine)
    }

    return $bash.Source
}

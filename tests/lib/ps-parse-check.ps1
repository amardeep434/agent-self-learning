# tests/lib/ps-parse-check.ps1
#
# Parse-checks each PowerShell file given as an argument and PRINTS the
# diagnostics. Invoked via `pwsh -NoProfile -File`, never `-Command`: the
# previous version of this check was an inline -Command string assembled in
# bash, and it reported all three wrappers as broken when the fault was in
# the check itself ([ref]$errs on a variable that was never initialised,
# under $ErrorActionPreference='Stop', is a terminating error for every
# input file alike). -File removes the whole bash/PowerShell quoting layer,
# and printing the parser's own message means a real failure says WHERE.
#
# Exit code: 0 if every file parsed, 1 otherwise.

param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Paths
)

$failed = 0

foreach ($path in $Paths) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        $failed = 1
        foreach ($e in $errors) {
            $line = $e.Extent.StartLineNumber
            $col = $e.Extent.StartColumnNumber
            Write-Output ('PARSE-ERROR ' + $path + ':' + $line + ':' + $col + ': ' + $e.Message)
        }
    }
    else {
        Write-Output ('PARSE-OK ' + $path)
    }
}

exit $failed

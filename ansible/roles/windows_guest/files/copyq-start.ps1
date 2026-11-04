# Runs at sign-in: loads the CopyQ history Ubuntu publishes to the share, then starts CopyQ with
# Ctrl+` (Ditto's shortcut) showing its window. Copies made here reach Ubuntu's CopyQ through the
# SPICE clipboard, so Ubuntu's history stays the one both machines load.
param([Parameter(Mandatory)][string]$Share)
$ErrorActionPreference = 'Stop'
$exe = "$env:ProgramFiles\CopyQ\copyq.exe"
$config = "$env:APPDATA\copyq"

# The share mounts in the background after boot.
for ($i = 0; $i -lt 60 -and -not (Test-Path "$Share\options.ini"); $i++) { Start-Sleep 1 }
if (Test-Path "$Share\options.ini") {
    if (Get-Process copyq -ErrorAction SilentlyContinue) { & $exe exit; Wait-Process copyq -Timeout 30 }
    New-Item -ItemType Directory -Force $config | Out-Null
    Copy-Item "$Share\copyq_tab_*.dat" $config -Force
    # Take Ubuntu's tab list and history size; keep Windows' other settings.
    $options = Get-Content "$Share\options.ini"
    $keys = $options | ForEach-Object { ($_ -split '=', 2)[0] }
    $conf = "$config\copyq.ini"
    $lines = @(if (Test-Path $conf) { Get-Content $conf | Where-Object { $keys -notcontains ($_ -split '=', 2)[0] } })
    $at = [array]::IndexOf($lines, '[Options]')
    $lines = if ($at -lt 0) { @('[Options]') + $options + $lines } else { $lines[0..$at] + $options + $lines[($at + 1)..$lines.Count] }
    [IO.File]::WriteAllLines($conf, [string[]]($lines | Where-Object { $_ -ne $null }))
}

Start-Process $exe
for ($i = 0; $i -lt 30; $i++) {
    & $exe eval 1 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { break }
    Start-Sleep 1
}
& $exe eval "if (!commands().some(function(c) { return c.name == 'Show/hide main window' })) setCommands(commands().concat([{name: 'Show/hide main window', cmd: 'copyq: toggle()', isGlobalShortcut: true, globalShortcuts: ['Ctrl+``']}]))"

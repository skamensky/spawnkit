# First access for Spawnkit, idempotent: OpenSSH server with PowerShell, the Linux key for
# administrators and a firewall rule admitting only the VM network. Everything else is Ansible.
# Runs elevated from the unattended installation medium (settings from bootstrap.json beside
# it) or as SYSTEM through `host-config guest-bootstrap` (settings as parameters).
param([string]$AuthorizedKey, [string]$Network)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (-not $AuthorizedKey) {
    $settings = Get-Content -Raw (Join-Path $PSScriptRoot 'bootstrap.json') | ConvertFrom-Json
    $AuthorizedKey, $Network = $settings.authorized_key, $settings.network
}
New-Item -ItemType Directory "$env:ProgramData\spawnkit" -Force | Out-Null
Start-Transcript -Append "$env:ProgramData\spawnkit\bootstrap.log" | Out-Null
try {
    if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
        Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Where-Object State -ne Installed | Add-WindowsCapability -Online | Out-Null
    }
    New-ItemProperty HKLM:\SOFTWARE\OpenSSH DefaultShell -PropertyType String -Force `
        -Value "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" | Out-Null
    Set-Service sshd -StartupType Automatic
    # The first start generates the host keys and creates the configuration directory.
    Start-Service sshd
    $keys = "$env:ProgramData\ssh\administrators_authorized_keys"
    $key = $AuthorizedKey.Trim()
    if (-not ((Test-Path $keys) -and (Get-Content $keys) -contains $key)) { Add-Content $keys $key -Encoding ascii }
    # sshd ignores this file unless only Administrators and SYSTEM can access it.
    icacls $keys /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
    $rule = @{ Direction = 'Inbound'; Protocol = 'TCP'; LocalPort = 22; RemoteAddress = $Network; Action = 'Allow'; Profile = 'Any' }
    if (Get-NetFirewallRule -Name Spawnkit-SSH -ErrorAction SilentlyContinue) {
        Set-NetFirewallRule -Name Spawnkit-SSH @rule
    } else {
        New-NetFirewallRule -Name Spawnkit-SSH -DisplayName 'OpenSSH from the Spawnkit host' @rule | Out-Null
    }
    Get-Content "$env:ProgramData\ssh\ssh_host_ed25519_key.pub"
} finally {
    Stop-Transcript | Out-Null
}

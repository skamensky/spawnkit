# Runs at boot. Looking Glass shows the virtual monitor and needs the RTX to capture it, so the
# virtual monitor is enabled only while the RTX is attached; without it (host-config --without-rtx)
# Windows shows the desktop on the virtio display.
$ErrorActionPreference = 'Stop'
$monitor = Get-PnpDevice -PresentOnly | Where-Object { $_.HardwareID -contains 'Root\MttVDD' }
$rtx = Get-PnpDevice -PresentOnly -Class Display | Where-Object { $_.InstanceId -like 'PCI\VEN_10DE&*' }
# Configuration Manager problem 22: the device is disabled.
$disabled = $monitor.ConfigManagerErrorCode -eq 22
if ($rtx -and $disabled) {
    Enable-PnpDevice -InstanceId $monitor.InstanceId -Confirm:$false
    Restart-Service 'Looking Glass (host)'
} elseif (-not $rtx -and -not $disabled) {
    Disable-PnpDevice -InstanceId $monitor.InstanceId -Confirm:$false
}

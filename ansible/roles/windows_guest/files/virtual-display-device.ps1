# Create the root-enumerated Virtual Display Driver device once and bind its driver.
[CmdletBinding(SupportsShouldProcess)]
param()
$ErrorActionPreference = 'Stop'
$WhatIfPreference = $false
$Ansible.Changed = $false
if (Get-PnpDevice -PresentOnly | Where-Object { $_.HardwareID -contains 'Root\MttVDD' }) { return }
$Ansible.Changed = $true
if ($Ansible.CheckMode) { return }
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class SpawnkitDevice {
  [StructLayout(LayoutKind.Sequential)] public struct SP_DEVINFO_DATA { public int cbSize; public Guid ClassGuid; public int DevInst; public IntPtr Reserved; }
  [DllImport("setupapi.dll", SetLastError=true)] public static extern IntPtr SetupDiCreateDeviceInfoList(ref Guid g, IntPtr h);
  [DllImport("setupapi.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool SetupDiCreateDeviceInfoW(IntPtr s, string name, ref Guid g, string desc, IntPtr h, int flags, ref SP_DEVINFO_DATA d);
  [DllImport("setupapi.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool SetupDiSetDeviceRegistryPropertyW(IntPtr s, ref SP_DEVINFO_DATA d, int prop, byte[] buf, int size);
  [DllImport("setupapi.dll", SetLastError=true)] public static extern bool SetupDiCallClassInstaller(int fn, IntPtr s, ref SP_DEVINFO_DATA d);
  [DllImport("newdev.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool UpdateDriverForPlugAndPlayDevicesW(IntPtr h, string hwid, string inf, int flags, out bool reboot);
}
"@
$display = [Guid]'{4D36E968-E325-11CE-BFC1-08002BE10318}'
$set = [SpawnkitDevice]::SetupDiCreateDeviceInfoList([ref]$display, [IntPtr]::Zero)
$device = New-Object SpawnkitDevice+SP_DEVINFO_DATA
$device.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($device)
# DICD_GENERATE_ID, SPDRP_HARDWAREID and DIF_REGISTERDEVICE.
if (-not [SpawnkitDevice]::SetupDiCreateDeviceInfoW($set, 'Display', [ref]$display, $null, [IntPtr]::Zero, 1, [ref]$device)) { throw "create: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
$hardwareId = [Text.Encoding]::Unicode.GetBytes("Root\MttVDD`0`0")
if (-not [SpawnkitDevice]::SetupDiSetDeviceRegistryPropertyW($set, [ref]$device, 1, $hardwareId, $hardwareId.Length)) { throw "hardware ID: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
if (-not [SpawnkitDevice]::SetupDiCallClassInstaller(0x19, $set, [ref]$device)) { throw "register: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
$reboot = $false
if (-not [SpawnkitDevice]::UpdateDriverForPlugAndPlayDevicesW([IntPtr]::Zero, 'Root\MttVDD', 'C:\VirtualDisplayDriver\MttVDD.inf', 1, [ref]$reboot)) { throw "driver: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }

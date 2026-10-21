[CmdletBinding()]
param(
    [ValidateSet('CurrentUser', 'LocalMachine')]
    [string]$Scope = 'LocalMachine',
    [Parameter(Mandatory=$true)]
    [string]$PolicyPath
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($Scope -eq 'LocalMachine' -and -not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'LocalMachine blocking requires an elevated PowerShell. No changes made.'
}
$policy = Get-Content -LiteralPath $PolicyPath -Raw | ConvertFrom-Json
$expected = @{}
foreach ($item in $policy.certificates) { $expected[$item.sha256.ToUpperInvariant()] = $true }
if ($expected.Count -ne 20) { throw 'Unexpected reviewed policy certificate count' }
$data = @()
foreach ($url in @('https://emudhra.we-have-a-problem.com/roots.json', 'https://emudhra.we-have-a-problem.com/impacted-intermediates.json')) {
    $response = Invoke-RestMethod -Uri $url -TimeoutSec 20
    foreach ($entry in $response) { $data += $entry }
}
if ($data.Count -ne $expected.Count) { throw 'Unexpected downloaded certificate count; no changes made' }
# These downloads are certificate data, never executable code. Check every DER
# fingerprint against the separately reviewed local manifest before changing trust.
$certificates = @{}
$sha = [Security.Cryptography.SHA256]::Create()
foreach ($item in $data) {
    $encoded = $item.pem -replace '-----BEGIN CERTIFICATE-----|-----END CERTIFICATE-----|\s', ''
    $der = [Convert]::FromBase64String($encoded)
    $hash = ([BitConverter]::ToString($sha.ComputeHash($der))).Replace('-', '')
    if (-not $expected.ContainsKey($hash)) { throw 'Downloaded certificate is not in the reviewed manifest' }
    $certificates[$hash] = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(,$der)
}
if ($certificates.Count -ne $expected.Count) { throw 'Incomplete certificate data; no changes made' }
$store = New-Object Security.Cryptography.X509Certificates.X509Store -ArgumentList 'Disallowed', $Scope
$added = 0
try {
    $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    $present = @{}
    foreach ($cert in $store.Certificates) {
        $present[([BitConverter]::ToString($sha.ComputeHash($cert.RawData))).Replace('-', '')] = $true
    }
    foreach ($hash in $certificates.Keys) {
        if (-not $present.ContainsKey($hash)) { $store.Add($certificates[$hash]); $added++ }
    }
} finally { $store.Close() }
$verified = @{}
try {
    $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
    foreach ($cert in $store.Certificates) {
        $hash = ([BitConverter]::ToString($sha.ComputeHash($cert.RawData))).Replace('-', '')
        if ($expected.ContainsKey($hash)) { $verified[$hash] = $true }
    }
} finally { $store.Close(); $sha.Dispose() }
if ($verified.Count -ne $expected.Count) { throw 'Disallowed store verification failed' }
[pscustomobject]@{Scope=$Scope;Added=$added;VerifiedBlocked=$verified.Count;Expected=$expected.Count} | ConvertTo-Json -Compress

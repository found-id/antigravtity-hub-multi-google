<#
.SYNOPSIS
    Antigravity Multi-Account Local User Provisioning Script
    Provision a specific local account or default accounts.
#>
param(
    [string]$TargetAccount = ""
)

# Check Elevation
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($TargetAccount) {
        $argList += " -TargetAccount `"$TargetAccount`""
    }
    Start-Process powershell.exe -ArgumentList $argList -Verb RunAs
    exit
}

$ScriptDir = Split-Path -Parent $PSCommandPath
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " ANTIGRAVITY MULTI-ACCOUNT USER SETUP " -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

# 1. Enable & Start Secondary Logon service
Write-Host "`n[1/3] Mengaktifkan Secondary Logon service (seclogon)..." -ForegroundColor White
Set-Service seclogon -StartupType Automatic
Start-Service seclogon
Write-Host "      Service seclogon running: $((Get-Service seclogon).Status)" -ForegroundColor Green

# 2. Setup Local Accounts
$Password = "AgyPass2026!"
$Accounts = if ($TargetAccount) { @($TargetAccount) } else { @("Google2", "Google3") }

foreach ($acc in $Accounts) {
    Write-Host "`n[2/3] Memeriksa akun Windows lokal $acc..." -ForegroundColor White
    $exists = Get-LocalUser -Name $acc -ErrorAction SilentlyContinue
    if (-not $exists) {
        Write-Host "      Membuat akun $acc..." -ForegroundColor Gray
        net user $acc $Password /add /comment:"Antigravity Multi-Account Profile" /passwordchg:no
        Set-LocalUser -Name $acc -PasswordNeverExpires $true
        Write-Host "      Akun $acc berhasil dibuat." -ForegroundColor Green
    } else {
        Write-Host "      Akun $acc sudah ada. Memperbarui password..." -ForegroundColor Gray
        net user $acc $Password
        Set-LocalUser -Name $acc -PasswordNeverExpires $true
        Write-Host "      Akun $acc siap." -ForegroundColor Green
    }
}

# 3. Ensure Permissions on App directories
Write-Host "`n[3/3] Mengatur izin akses folder aplikasi..." -ForegroundColor White
$AppDir = "$env:LOCALAPPDATA\Programs\Antigravity IDE"
if (Test-Path $AppDir) {
    icacls "$AppDir" /grant "Users:(OI)(CI)RX" /c /q | Out-Null
}
$MultiAppDir = "D:\Device\Apps\Antigravity Multi-Profile"
if (Test-Path $MultiAppDir) {
    icacls "$MultiAppDir" /grant "Users:(OI)(CI)M" /c /q | Out-Null
}
Write-Host "      Izin akses folder diberikan ke semua user." -ForegroundColor Green

Write-Host "`n=============================================" -ForegroundColor Green
Write-Host " SETUP SELESAI! " -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host "Akun siap digunakan. Menutup jendela..." -ForegroundColor White
Start-Sleep -Seconds 1

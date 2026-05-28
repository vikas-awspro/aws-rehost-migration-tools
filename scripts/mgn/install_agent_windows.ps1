<#
.SYNOPSIS
  MGN agent installation — Windows Server 2016/2019/2022.
  Run as Administrator on each source server (TIG §A.2 step 5). No reboot required.

.DESCRIPTION
  Downloads the MGN installer for the configured AWS region and installs the
  AWS Replication Agent as a Windows service. Reads credentials from environment
  variables — never persists them to disk.

.PARAMETER Region
  AWS region. Defaults to ap-south-1.

.EXAMPLE
  $env:AWS_ACCESS_KEY_ID = "AKIA..."
  $env:AWS_SECRET_ACCESS_KEY = "..."
  powershell -ExecutionPolicy Bypass -File .\install_agent_windows.ps1
#>
[CmdletBinding()]
param(
    [string]$Region = $(if ($env:AWS_REGION) { $env:AWS_REGION } else { "ap-south-1" })
)

$ErrorActionPreference = "Stop"

if (-not $env:AWS_ACCESS_KEY_ID -or -not $env:AWS_SECRET_ACCESS_KEY) {
    Write-Error "AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must be set in the environment. Use a temporary key tied to the 'mgn-agent-install' IAM user."
    exit 1
}

$InstallerUrl = "https://aws-application-migration-service-$Region.s3.$Region.amazonaws.com/latest/windows/AwsReplicationWindowsInstaller.exe"
$InstallerPath = Join-Path $env:TEMP "AwsReplicationWindowsInstaller.exe"

Write-Host "Downloading MGN agent installer from $InstallerUrl ..."
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri $InstallerUrl -OutFile $InstallerPath -UseBasicParsing

Write-Host "Running installer (no reboot)..."
$installerArgs = @(
    "--region", $Region,
    "--aws-access-key-id", $env:AWS_ACCESS_KEY_ID,
    "--aws-secret-access-key", $env:AWS_SECRET_ACCESS_KEY,
    "--no-prompt"
)
& $InstallerPath @installerArgs

if ($LASTEXITCODE -ne 0) {
    Write-Error "Installer exited with code $LASTEXITCODE"
    exit $LASTEXITCODE
}

# Verify service.
$svc = Get-Service -Name "AwsReplicationAgent" -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq "Running") {
    Write-Host "✓ AwsReplicationAgent service is running on $env:COMPUTERNAME."
    Write-Host "  Check AWS console (MGN → Source servers) — this host should appear within 5 minutes."
} else {
    Write-Error "AwsReplicationAgent service is not running."
    Get-EventLog -LogName Application -Source "AwsReplicationAgent" -Newest 10 -ErrorAction SilentlyContinue
    exit 2
}

# Scrub the installer to leave no executable on disk.
Remove-Item $InstallerPath -Force -ErrorAction SilentlyContinue

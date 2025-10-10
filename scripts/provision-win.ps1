<# 
  Minimal Windows provisioning for Dev + Python via Miniconda
  - Installs: Git, (optional) VS Code, CMake, Ninja, VS 2022 Build Tools (MSVC), 7zip,
              (optional) Docker Desktop, (optional) Windows Terminal, (optional) Cmder
  - Installs Miniconda and configures conda-forge (strict). No envs created.
  - Optional CUDA prep: installs NVIDIA driver (optional) and CUDA Toolkit.
  - NEW: Sets ExecutionPolicy (CurrentUser -> RemoteSigned) so PowerShell profile loads (conda init works).

  Re-runnable (idempotent-ish). Keep it simple & clean.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -------------------- CONFIG --------------------
$Cfg = [pscustomobject]@{
  # Tooling toggles
  InstallVSCode            = $true
  InstallDocker            = $true
  InstallWindowsTerminal   = $true
  InstallCmder             = $true          # Cmder (full). Use "cmdermini" in CmderPackageId for lighter.
  CmderPackageId           = "cmder"        # "cmder" or "cmdermini"

  # CUDA prep (PyTorch + CUDA)
  InstallCUDA              = $false         # true => install CUDA toolkit; driver optional below
  InstallNvidiaDriver      = $false         # true => install NVIDIA display driver via Chocolatey
  CudaToolkitVersion       = $null          # e.g. "12.4.1" or $null for latest
  NvidiaDriverVersion      = $null          # e.g. "560.94" or $null for latest

  # Optional pins (leave $null for latest)
  GitVersion               = $null
  VSCodeVersion            = $null
  CMakeVersion             = $null
  NinjaVersion             = $null
  VSBuildToolsVersion      = $null
  MinicondaVersion         = $null
  WindowsTerminalVersion   = $null
  CmderVersion             = $null
}
# ------------------------------------------------

function Ensure-Admin {
  $id=[Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    throw "Run this script in an elevated PowerShell (Admin)."
  }
}; Ensure-Admin

# Install Chocolatey if missing
if (-not (Get-Command choco.exe -ErrorAction SilentlyContinue)) {
  Write-Host "Installing Chocolatey..."
  Set-ExecutionPolicy Bypass -Scope Process -Force
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
}

# Helper: idempotent choco ensure (with --package-parameters support)
function Choco-Ensure {
  param(
    [Parameter(Mandatory=$true)][string]$Pkg,
    [string]$Version = $null,
    [string]$PackageParameters = ""
  )
  $args = @("install", $Pkg, "-y", "--no-progress")
  if ($Version)           { $args += "--version=$Version" }
  if ($PackageParameters) { $args += "--package-parameters=$PackageParameters" }
  choco @args
  if ($LASTEXITCODE -ne 0) { throw "choco install failed: $Pkg" }
}

# Enable long paths (useful for deep Python trees)
function Enable-LongPaths {
  $key="HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem"
  $cur=(Get-ItemProperty -Path $key -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled
  if ($cur -ne 1) { Set-ItemProperty -Path $key -Name LongPathsEnabled -Value 1 -Type DWord; Write-Host "Enabled NTFS long paths." }
}
Enable-LongPaths

Write-Host "Installing core development tools..."
Choco-Ensure -Pkg git -Version $Cfg.GitVersion
Choco-Ensure -Pkg 7zip
Choco-Ensure -Pkg cmake -Version $Cfg.CMakeVersion
Choco-Ensure -Pkg ninja -Version $Cfg.NinjaVersion

# Visual Studio 2022 Build Tools (MSVC + MSBuild + CMake integration + Win11 SDK)
$vsParamList = @(
  "--add Microsoft.VisualStudio.Workload.VCTools",
  "--add Microsoft.VisualStudio.Component.MSBuild",
  "--add Microsoft.VisualStudio.Component.VC.CMake.Project",
  "--add Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
  "--add Microsoft.VisualStudio.Component.Windows11SDK.22000",
  "--quiet", "--norestart", "--nocache"
)
$vsParams = '"' + ($vsParamList -join ' ') + '"'
Choco-Ensure -Pkg visualstudio2022buildtools -Version $Cfg.VSBuildToolsVersion -PackageParameters $vsParams

if ($Cfg.InstallVSCode)          { Choco-Ensure -Pkg vscode -Version $Cfg.VSCodeVersion }
if ($Cfg.InstallWindowsTerminal) { Choco-Ensure -Pkg microsoft-windows-terminal -Version $Cfg.WindowsTerminalVersion }
if ($Cfg.InstallCmder)           { Choco-Ensure -Pkg $Cfg.CmderPackageId -Version $Cfg.CmderVersion }

if ($Cfg.InstallDocker) {
  Choco-Ensure -Pkg docker-desktop
  try {
    $user = "$env:USERDOMAIN\$env:USERNAME"
    if (-not (Get-LocalGroupMember -Group "docker-users" -ErrorAction SilentlyContinue | Where-Object Name -eq $user)) {
      Add-LocalGroupMember -Group "docker-users" -Member $user
      Write-Host "Added $user to docker-users (sign out/in may be required)."
    }
  } catch { Write-Warning $_ }
}

Write-Host "Installing Miniconda..."
Choco-Ensure -Pkg miniconda3 -Version $Cfg.MinicondaVersion

# Locate conda.bat
$condaBatCandidates = @(
  "$env:UserProfile\miniconda3\condabin\conda.bat",
  "$env:ProgramData\miniconda3\condabin\conda.bat",
  "C:\tools\miniconda3\condabin\conda.bat"
)
$condaBat = $condaBatCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $condaBat) { throw "Could not find conda.bat (Miniconda). Checked: $($condaBatCandidates -join ', ')" }

# Configure conda-forge (no env creation)
& $condaBat config --set channel_priority strict
if ($LASTEXITCODE -ne 0) { throw "conda config channel_priority failed." }
& $condaBat config --add channels conda-forge
if ($LASTEXITCODE -ne 0) { throw "conda config add conda-forge failed." }

# Init for PowerShell & cmd
& $condaBat init powershell
& $condaBat init cmd.exe

# --- Ensure PowerShell profile can run (so conda init actually loads) ---
try {
  $cur = Get-ExecutionPolicy -Scope CurrentUser -ErrorAction SilentlyContinue
  if (-not $cur -or $cur -eq 'Restricted' -or $cur -eq 'Undefined') {
    Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
    Write-Host "Set ExecutionPolicy (Windows PowerShell, CurrentUser) -> RemoteSigned."
  } else {
    Write-Host "ExecutionPolicy(CurrentUser for Windows PowerShell) is $cur (keeping)."
  }
} catch {
  Write-Warning "Could not set ExecutionPolicy for Windows PowerShell CurrentUser: $_"
}
# Also set for PowerShell 7 (if installed). Separate policy hive.
try {
  $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
  if ($pwsh) {
    Start-Process -FilePath $pwsh -ArgumentList @('-NoLogo','-NoProfile','-Command','Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force') -Wait -NoNewWindow
    Write-Host "Set ExecutionPolicy (PowerShell 7, CurrentUser) -> RemoteSigned."
  }
} catch {
  Write-Warning "Could not set ExecutionPolicy for PowerShell 7 CurrentUser: $_"
}

# CUDA prep (optional)
if ($Cfg.InstallCUDA) {
  Write-Host "CUDA prep enabled."
  if ($Cfg.InstallNvidiaDriver) {
    Choco-Ensure -Pkg nvidia-display-driver -Version $Cfg.NvidiaDriverVersion
    Write-Host "NVIDIA display driver installed (or already present). A reboot may be required."
  } else {
    Write-Host "Skipping NVIDIA driver install (InstallNvidiaDriver=false). Ensure a compatible driver is already installed."
  }

  # CUDA Toolkit (nvcc/headers; PyTorch wheels bundle CUDA runtime)
  Choco-Ensure -Pkg cuda -Version $Cfg.CudaToolkitVersion

  # Set CUDA_PATH for convenience (Machine scope)
  $cudaRoot = Get-ChildItem "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA" -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
  if ($cudaRoot) {
    [Environment]::SetEnvironmentVariable('CUDA_PATH', $cudaRoot.FullName, 'Machine')
    $machinePath = [Environment]::GetEnvironmentVariable('Path','Machine')
    $append = @("$($cudaRoot.FullName)\bin","$($cudaRoot.FullName)\libnvvp")
    foreach ($p in $append) { if ($machinePath -notlike "*$p*") { $machinePath += ";" + $p } }
    [Environment]::SetEnvironmentVariable('Path', $machinePath, 'Machine')
    Write-Host "Configured CUDA_PATH -> $($cudaRoot.FullName)"
  } else {
    Write-Warning "CUDA toolkit folder not found; PATH/CUDA_PATH not updated."
  }
}

# Git defaults (safe)
& git config --global core.autocrlf input
& git config --global init.defaultBranch main

Write-Host "Provisioning complete."
Write-Host "Miniconda installed. conda-forge enabled with strict priority."
Write-Host "Conda initialized for new PowerShell and cmd sessions."
Write-Host "ExecutionPolicy set to RemoteSigned (CurrentUser) for Windows PowerShell$(Get-Command pwsh -ErrorAction SilentlyContinue ? ', and PowerShell 7' : '')."
if ($Cfg.InstallWindowsTerminal) { Write-Host "Windows Terminal installed (or already present)." }
if ($Cfg.InstallCmder)          { Write-Host "Cmder installed (full or mini as configured). Launch 'Cmder' from Start menu." }
if ($Cfg.InstallCUDA)           { Write-Host "CUDA prep done. If driver was installed, reboot is recommended before using PyTorch CUDA." }
if ($Cfg.InstallDocker)         { Write-Host "Docker Desktop installed. Sign out/in once if 'docker-users' membership is new." }

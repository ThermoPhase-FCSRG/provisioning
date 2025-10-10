<# 
  Minimal Windows provisioning for Dev + Python via Miniconda
  - Installs: Git, (optional) VS Code, CMake, Ninja, VS 2022 Build Tools (MSVC), 7zip,
              (optional) Docker Desktop, (optional) Windows Terminal, (optional) Cmder
  - Installs Miniconda and configures conda-forge (strict). No envs created.
  - Optional CUDA prep: installs NVIDIA driver (optional) and CUDA Toolkit.

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
  InstallCmder             = $true          # NEW: install Cmder (full). Set to $false to skip.
  CmderPackageId           = "cmder"        # "cmder" (full) or "cmdermini" (lighter)

  # CUDA prep (set true if you need PyTorch with CUDA)
  InstallCUDA              = $false         # when true, installs CUDA Toolkit; driver install is optional below
  InstallNvidiaDriver      = $false         # set true to install display driver via Chocolatey
  CudaToolkitVersion       = $null          # e.g., "12.4.1" or $null for latest available
  NvidiaDriverVersion      = $null          # e.g., "560.94" or $null for latest available

  # Optional version pins (leave $null for latest)
  GitVersion               = $null
  VSCodeVersion            = $null
  CMakeVersion             = $null
  NinjaVersion             = $null
  VSBuildToolsVersion      = $null
  MinicondaVersion         = $null
  WindowsTerminalVersion   = $null          # Choco id: microsoft-windows-terminal
  CmderVersion             = $null          # Version for Cmder/CmderMini if you want to pin
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

# Helper: idempotent choco ensure
function Choco-Ensure {
  param([string]$Pkg, [string]$Version = $null, [string]$Params = "")
  $args = @("install",$Pkg,"-y","--no-progress")
  if ($Version) { $args += "--version=$Version" }
  if ($Params)  { $args += "--params=$Params" }
  choco @args
}

# Enable long paths (useful for deep Python trees)
function Enable-LongPaths {
  $key="HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem"
  $cur=(Get-ItemProperty -Path $key -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled
  if ($cur -ne 1) { Set-ItemProperty -Path $key -Name LongPathsEnabled -Value 1 -Type DWord; Write-Host "Enabled NTFS long paths." }
}
Enable-LongPaths

Write-Host "Installing core development tools..."
Choco-Ensure git           $Cfg.GitVersion
Choco-Ensure 7zip
Choco-Ensure cmake         $Cfg.CMakeVersion
Choco-Ensure ninja         $Cfg.NinjaVersion

# Visual Studio 2022 Build Tools (MSVC + MSBuild + CMake integration + Win11 SDK)
$vsParams = ' "--add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.MSBuild --add Microsoft.VisualStudio.Component.VC.CMake.Project --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.Windows11SDK.22000 --quiet --norestart --nocache" '
Choco-Ensure visualstudio2022buildtools $Cfg.VSBuildToolsVersion $vsParams

if ($Cfg.InstallVSCode) {
  Choco-Ensure vscode $Cfg.VSCodeVersion
}

if ($Cfg.InstallWindowsTerminal) {
  # On Win11 it's often present; choco install is idempotent.
  Choco-Ensure microsoft-windows-terminal $Cfg.WindowsTerminalVersion
}

if ($Cfg.InstallCmder) {
  Choco-Ensure $Cfg.CmderPackageId $Cfg.CmderVersion
}

if ($Cfg.InstallDocker) {
  Choco-Ensure docker-desktop
  try {
    $user = "$env:USERDOMAIN\$env:USERNAME"
    if (-not (Get-LocalGroupMember -Group "docker-users" -ErrorAction SilentlyContinue | Where-Object Name -eq $user)) {
      Add-LocalGroupMember -Group "docker-users" -Member $user
      Write-Host "Added $user to docker-users (sign out/in may be required)."
    }
  } catch { Write-Warning $_ }
}

Write-Host "Installing Miniconda..."
Choco-Ensure miniconda3 $Cfg.MinicondaVersion

# Locate conda.bat
$condaBat = "$env:UserProfile\miniconda3\condabin\conda.bat"
if (-not (Test-Path $condaBat)) {
  $condaBat = "$env:ProgramData\miniconda3\condabin\conda.bat"
}
if (-not (Test-Path $condaBat)) { throw "Could not find conda.bat (Miniconda). Check installation path." }

# Configure conda-forge (no env creation)
& $condaBat "config --set channel_priority strict"
& $condaBat "config --add channels conda-forge"

# Make 'conda' available in new terminals (PowerShell & cmd)
& $condaBat "init powershell"
& $condaBat "init cmd.exe"
# (Open a new Windows Terminal/PowerShell/Cmder tab to pick this up.)

# CUDA prep (optional)
if ($Cfg.InstallCUDA) {
  Write-Host "CUDA prep enabled."
  if ($Cfg.InstallNvidiaDriver) {
    Choco-Ensure nvidia-display-driver $Cfg.NvidiaDriverVersion
    Write-Host "NVIDIA display driver installed (or already present). A reboot may be required."
  } else {
    Write-Host "Skipping NVIDIA driver install (InstallNvidiaDriver=false). Ensure a compatible driver is already installed."
  }

  # CUDA Toolkit (useful for nvcc/headers; PyTorch wheels bundle CUDA runtime)
  Choco-Ensure cuda $Cfg.CudaToolkitVersion

  # Set CUDA_PATH for convenience (Machine scope)
  $cudaRoot = Get-ChildItem "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA" -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
  if ($cudaRoot) {
    [Environment]::SetEnvironmentVariable('CUDA_PATH', $cudaRoot.FullName, 'Machine')
    $newPath = "$($env:Path);$($cudaRoot.FullName)\bin;$($cudaRoot.FullName)\libnvvp"
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'Machine')
    Write-Host "Configured CUDA_PATH -> $($cudaRoot.FullName)"
  } else {
    Write-Warning "CUDA toolkit folder not found; PATH/CUDA_PATH not updated."
  }
}

# Git defaults (safe)
& git config --global core.autocrlf input
& git config --global init.defaultBranch main

Write-Host "`n✅ Provisioning complete."
Write-Host "Miniconda installed. conda-forge enabled with strict priority."
Write-Host "Conda initialized for new PowerShell and cmd sessions."
if ($Cfg.InstallWindowsTerminal) {
  Write-Host "Windows Terminal installed (or already present)."
}
if ($Cfg.InstallCmder) {
  Write-Host "Cmder installed (full or mini as configured). Launch 'Cmder' from Start menu."
}
if ($Cfg.InstallCUDA) {
  Write-Host "CUDA prep done. If driver was installed, reboot is recommended before using PyTorch CUDA."
}
if ($Cfg.InstallDocker) {
  Write-Host "Docker Desktop installed. Sign out/in once if 'docker-users' membership is new."
}

<# 
  Minimal Windows provisioning for Dev + Python via Miniconda (CLI-configurable + profiles)
  - Installs: Git, (optional) VS Code, CMake, Ninja, VS 2022 Build Tools (MSVC), 7zip,
              (optional) Docker Desktop, (optional) Windows Terminal, (optional) Cmder
  - Installs Miniconda and configures conda-forge (strict). No envs created.
  - Optional CUDA prep: NVIDIA driver (optional) and CUDA Toolkit.
  - Ensures ExecutionPolicy (CurrentUser -> RemoteSigned) so PowerShell profile loads (conda init works).

  Examples:
    .\provision-win.ps1                               # default profile
    .\provision-win.ps1 -Profile minimal              # skips Docker
    .\provision-win.ps1 -Profile gpu                  # enables CUDA + NVIDIA driver
    .\provision-win.ps1 -Profile gpu -InstallDocker:$false  # explicit flag overrides profile
#>

[CmdletBinding()]
param(
  # ===== Profiles =====
  [ValidateSet('default','minimal','gpu')]
  [string] $Profile = 'default',

  # ===== Tool toggles ===== (explicit flags override profile defaults)
  [bool] $InstallVSCode            = $true,
  [bool] $InstallWindowsTerminal   = $true,
  [bool] $InstallCmder             = $true,
  [string] $CmderPackageId         = "cmder",   # "cmder" or "cmdermini"
  [bool] $InstallDocker            = $true,

  # ===== CUDA toggles =====
  [bool] $InstallCUDA              = $false,
  [bool] $InstallNvidiaDriver      = $false,

  # ===== Version pins (leave null for latest) =====
  [string] $CudaToolkitVersion     = $null,
  [string] $NvidiaDriverVersion    = $null,
  [string] $GitVersion             = $null,
  [string] $VSCodeVersion          = $null,
  [string] $CMakeVersion           = $null,
  [string] $NinjaVersion           = $null,
  [string] $VSBuildToolsVersion    = $null,
  [string] $MinicondaVersion       = $null,
  [string] $WindowsTerminalVersion = $null,
  [string] $CmderVersion           = $null
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ----- Apply profile defaults (only if the user did NOT set the flag) -----
switch ($Profile) {
  'minimal' {
    if (-not $PSBoundParameters.ContainsKey('InstallDocker'))      { $InstallDocker = $false }
    # Everything else same as default
  }
  'gpu' {
    if (-not $PSBoundParameters.ContainsKey('InstallCUDA'))        { $InstallCUDA = $true }
    if (-not $PSBoundParameters.ContainsKey('InstallNvidiaDriver')){ $InstallNvidiaDriver = $true }
  }
  default { } # keep declared defaults
}

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
Choco-Ensure -Pkg git   -Version $GitVersion
Choco-Ensure -Pkg 7zip
Choco-Ensure -Pkg cmake -Version $CMakeVersion
Choco-Ensure -Pkg ninja -Version $NinjaVersion

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
Choco-Ensure -Pkg visualstudio2022buildtools -Version $VSBuildToolsVersion -PackageParameters $vsParams

if ($InstallVSCode)          { Choco-Ensure -Pkg microsoft-edge-webview2-runtime }  # sometimes needed by extensions
if ($InstallVSCode)          { Choco-Ensure -Pkg vscode -Version $VSCodeVersion }
if ($InstallWindowsTerminal) { Choco-Ensure -Pkg microsoft-windows-terminal -Version $WindowsTerminalVersion }
if ($InstallCmder)           { Choco-Ensure -Pkg $CmderPackageId -Version $CmderVersion }

if ($InstallDocker) {
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
Choco-Ensure -Pkg miniconda3 -Version $MinicondaVersion

# Locate conda.bat (Chocolatey or user installs)
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

# Ensure PowerShell profile can run (so conda init actually loads)
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

# Also set for PowerShell 7 (if installed) — PS 5.1 compatible
try {
  $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
  if ($pwshCmd) {
    $pwsh = $pwshCmd.Source
    Start-Process -FilePath $pwsh -ArgumentList @(
      '-NoLogo','-NoProfile','-Command',
      'Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force'
    ) -Wait -NoNewWindow
    Write-Host "Set ExecutionPolicy (PowerShell 7, CurrentUser) -> RemoteSigned."
  }
} catch {
  Write-Warning "Could not set ExecutionPolicy for PowerShell 7 CurrentUser: $_"
}

# CUDA prep (optional)
if ($InstallCUDA) {
  Write-Host "CUDA prep enabled."
  if ($InstallNvidiaDriver) {
    Choco-Ensure -Pkg nvidia-display-driver -Version $NvidiaDriverVersion
    Write-Host "NVIDIA display driver installed (or already present). A reboot may be required."
  } else {
    Write-Host "Skipping NVIDIA driver install (InstallNvidiaDriver=false). Ensure a compatible driver is already installed."
  }

  # CUDA Toolkit (nvcc/headers; PyTorch wheels bundle CUDA runtime)
  Choco-Ensure -Pkg cuda -Version $CudaToolkitVersion

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

Write-Host "Provisioning complete (profile: $Profile)."
Write-Host "Miniconda installed. conda-forge enabled with strict priority."
Write-Host "Conda initialized for new PowerShell and cmd sessions."
Write-Host "ExecutionPolicy set to RemoteSigned (CurrentUser) for Windows PowerShell$(if (Get-Command pwsh -ErrorAction SilentlyContinue) { ', and PowerShell 7' } else { '' })."
if ($InstallWindowsTerminal) { Write-Host "Windows Terminal installed (or already present)." }
if ($InstallCmder)          { Write-Host "Cmder installed (full or mini as configured). Launch 'Cmder' from Start menu." }
if ($InstallCUDA)           { Write-Host "CUDA prep done. If driver was installed, reboot is recommended before using PyTorch CUDA." }
if ($InstallDocker)         { Write-Host "Docker Desktop installed. Sign out/in once if 'docker-users' membership is new." }

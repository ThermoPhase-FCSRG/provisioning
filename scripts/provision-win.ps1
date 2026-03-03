<# 
  Windows provisioning for Dev + Python via Miniconda (CLI-configurable + profiles)
  - Installs: Git, (optional) VS Code, CMake, Ninja, VS 2022 Build Tools (MSVC), 7zip,
              (optional) Docker Desktop, (optional) Windows Terminal, (optional) Cmder
  - Installs **system Python** first (via Chocolatey) with venv/pip (toggle with -InstallPython).
  - Installs Miniconda using the **official latest installer by default** (toggle with -MinicondaUseDirectInstaller).
    * Falls back to Chocolatey if you set -MinicondaUseDirectInstaller:$false.
  - Configures conda-forge (strict). No envs created.
  - Optional CUDA prep: NVIDIA driver (optional) and CUDA Toolkit.
  - Ensures ExecutionPolicy (CurrentUser -> RemoteSigned) so PowerShell profile loads (conda init works).

  Examples:
    .\provision-win.ps1                               # default profile
    .\provision-win.ps1 -Profile minimal              # skips Docker by default
    .\provision-win.ps1 -Profile gpu                  # enables CUDA + NVIDIA driver by default
    .\provision-win.ps1 -InstallPython:$false         # skip system Python
    .\provision-win.ps1 -MinicondaUseDirectInstaller:$false -MinicondaVersion 24.9.2  # choco pin

    # Version pins example:
    .\provision-win.ps1 -CudaToolkitVersion 12.4.1 -GitVersion 2.47.0 -CMakeVersion 3.29.6 -PythonVersion 3.12.6
#>

[CmdletBinding()]
param(
  # ===== Profiles =====
  [ValidateSet('default','minimal','gpu')]
  [string] $Profile = 'default',

  # ===== Tool toggles =====
  [bool] $InstallVSCode            = $true,
  [bool] $InstallWindowsTerminal   = $true,
  [bool] $InstallCmder             = $true,
  [string] $CmderPackageId         = "cmder",   # "cmder" or "cmdermini"
  [bool] $InstallDocker            = $true,

  # ===== System Python toggle =====
  [bool] $InstallPython            = $true,     # Chocolatey "python" (includes venv/pip)
  [string] $PythonVersion          = $null,     # e.g. "3.12.6"

  # ===== Miniconda controls =====
  [bool]   $MinicondaUseDirectInstaller = $true,   # use official "latest" URL by default
  [string] $MinicondaInstallDir         = "C:\tools\miniconda3", # no spaces (NSIS /D=path)
  [bool]   $ForceReinstallMiniconda     = $false,  # silently uninstall/reinstall
  [bool]   $CondaSelfUpdate             = $true,   # conda update -n base -y conda

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
  [string] $MinicondaVersion       = $null,    # only used when MinicondaUseDirectInstaller:$false
  [string] $WindowsTerminalVersion = $null,
  [string] $CmderVersion           = $null
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ----- Apply profile defaults -----
switch ($Profile) {
  'minimal' {
    if (-not $PSBoundParameters.ContainsKey('InstallDocker'))      { $InstallDocker = $false }
  }
  'gpu' {
    if (-not $PSBoundParameters.ContainsKey('InstallCUDA'))        { $InstallCUDA = $true }
    if (-not $PSBoundParameters.ContainsKey('InstallNvidiaDriver')){ $InstallNvidiaDriver = $true }
  }
  default { }
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

# Helper: idempotent choco ensure
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

# Enable long paths
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
Choco-Ensure -Pkg winflexbison   # flex + bison

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

# ---- System Python (with venv/pip) BEFORE Miniconda ----
if ($InstallPython) {
  Write-Host "Installing system Python (with venv/pip)..."
  Choco-Ensure -Pkg python -Version $PythonVersion

  # Refresh PATH for this session
  $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
              [System.Environment]::GetEnvironmentVariable('Path','User')
  try {
    $pyver = & python --version 2>$null
    if ($pyver) { Write-Host "Python installed: $pyver" }
  } catch { Write-Warning "Python not yet on PATH in this session; it will be available in new terminals." }
}

# ---- Miniconda (latest by default via official installer) ----
function Install-Miniconda-Direct {
  param(
    [string]$InstallDir,
    [bool]$ForceReinstall = $false
  )
  if (Test-Path $InstallDir) {
    if ($ForceReinstall) {
      Write-Host "ForceReinstallMiniconda is ON. Attempting silent uninstall..."
      $uninstaller = Join-Path $InstallDir 'Uninstall-Miniconda3.exe'
      if (Test-Path $uninstaller) {
        Start-Process -FilePath $uninstaller -ArgumentList '/S' -Wait -NoNewWindow
      } else {
        Write-Warning "Uninstaller not found; removing directory."
        Remove-Item -Recurse -Force $InstallDir
      }
    } else {
      Write-Host "Miniconda already present at $InstallDir (skipping install)."
      return
    }
  }

  $latestUrl = 'https://repo.anaconda.com/miniconda/Miniconda3-latest-Windows-x86_64.exe'
  $tmp = Join-Path $env:TEMP "Miniconda3-latest.exe"
  Write-Host "Downloading Miniconda latest from $latestUrl ..."
  Invoke-WebRequest -Uri $latestUrl -OutFile $tmp -UseBasicParsing

  # NSIS flags: /S for silent, /InstallationType=AllUsers, /AddToPath=0, /RegisterPython=0, /D=<path> (must be LAST, no quotes)
  $args = @(
    "/S",
    "/InstallationType=AllUsers",
    "/AddToPath=0",
    "/RegisterPython=0",
    "/D=$InstallDir"
  )
  Write-Host "Running Miniconda installer (silent) to $InstallDir ..."
  Start-Process -FilePath $tmp -ArgumentList $args -Wait -NoNewWindow
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

Write-Host "Installing Miniconda..."
# Detect an existing conda installation before downloading
$existingConda = $null
$condaCandidates = @(
  (Join-Path $MinicondaInstallDir 'condabin\conda.bat'),
  "$env:UserProfile\miniforge3\condabin\conda.bat",
  "$env:UserProfile\miniconda3\condabin\conda.bat",
  "$env:UserProfile\anaconda3\condabin\conda.bat",
  "$env:ProgramData\miniforge3\condabin\conda.bat",
  "$env:ProgramData\miniconda3\condabin\conda.bat",
  "C:\tools\miniconda3\condabin\conda.bat",
  "C:\tools\miniforge3\condabin\conda.bat"
)
foreach ($c in $condaCandidates) { if (Test-Path $c) { $existingConda = $c; break } }
if (-not $existingConda) {
  $onPath = Get-Command conda -ErrorAction SilentlyContinue
  if ($onPath) { $existingConda = $onPath.Source }
}

if ($existingConda) {
  Write-Host "Conda already found at $existingConda — skipping Miniconda download/install."
} elseif ($MinicondaUseDirectInstaller) {
  if ($MinicondaInstallDir -match '\s') {
    throw "MinicondaInstallDir contains spaces. NSIS '/D=' cannot be quoted reliably. Use a path without spaces (e.g., C:\tools\miniconda3)."
  }
  Install-Miniconda-Direct -InstallDir $MinicondaInstallDir -ForceReinstall:$ForceReinstallMiniconda
} else {
  Choco-Ensure -Pkg miniconda3 -Version $MinicondaVersion
}

# Locate conda.bat (use already-found path, then fall back to candidate list)
$condaBatCandidates = @(
  (Join-Path $MinicondaInstallDir 'condabin\conda.bat'),
  "$env:UserProfile\miniconda3\condabin\conda.bat",
  "$env:ProgramData\miniconda3\condabin\conda.bat",
  "C:\tools\miniconda3\condabin\conda.bat"
)
$condaBat = if ($existingConda -and (Test-Path $existingConda)) {
  $existingConda
} else {
  $condaBatCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $condaBat) { throw "Could not find conda.bat (Miniconda). Checked: $($condaBatCandidates -join ', ')" }

# Optional: keep base conda itself fresh
if ($CondaSelfUpdate) {
  & $condaBat update -n base -y conda
  if ($LASTEXITCODE -ne 0) { Write-Warning "conda self-update failed (non-fatal)." }
}

# Configure conda-forge (no env creation)
& $condaBat config --set channel_priority strict
if ($LASTEXITCODE -ne 0) { throw "conda config channel_priority failed." }
& $condaBat config --add channels conda-forge
if ($LASTEXITCODE -ne 0) { throw "conda config add conda-forge failed." }

# Init for PowerShell & cmd
& $condaBat init powershell
& $condaBat init cmd.exe

# Ensure PowerShell profile can run
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

# Also set for PowerShell 7 (if installed)
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

  Choco-Ensure -Pkg cuda -Version $CudaToolkitVersion

  # Set CUDA_PATH
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

# Git defaults
& git config --global core.autocrlf input
& git config --global init.defaultBranch main
& git lfs install | Out-Null

# ---- pixi ----
Write-Host "Installing pixi..."
Invoke-Expression (Invoke-RestMethod 'https://pixi.sh/install.ps1')

# ----- Note on scientific/HPC libraries -----
# The following libraries (available as apt packages on Ubuntu) are not reliably available
# via Chocolatey on Windows. Install them through conda (already configured above) or vcpkg:
#   openblas, openmpi, fftw, hwloc, hdf5 (MPI), mumps, metis, netcdf, pnetcdf,
#   scotch/ptscotch, scalapack, suitesparse, superlu, superlu_dist
# Example (conda):
#   conda install -n base -y openblas openmpi fftw hwloc hdf5 mumps metis netcdf4
Write-Host "Note: Scientific/HPC libraries (OpenBLAS, OpenMPI, FFTW, HDF5, MUMPS, etc.) are not available via Chocolatey. Install them via conda (already configured) or vcpkg."

# ----- Final status -----
$minicondaMethod = if ($MinicondaUseDirectInstaller) { 'direct' } else { 'Chocolatey' }

Write-Host "Provisioning complete (profile: $Profile)."
if ($InstallPython)        { Write-Host "System Python installed (with venv & pip). Use 'py -3 -m venv .venv' or 'python -m venv .venv'." }
Write-Host "Miniconda installed (via $minicondaMethod). conda-forge enabled with strict priority."
if ($CondaSelfUpdate)      { Write-Host "Base 'conda' self-update attempted." }
Write-Host "Conda initialized for new PowerShell and cmd sessions."
Write-Host "ExecutionPolicy set to RemoteSigned (CurrentUser) for Windows PowerShell$(if (Get-Command pwsh -ErrorAction SilentlyContinue) { ', and PowerShell 7' } else { '' })."
if ($InstallWindowsTerminal) { Write-Host "Windows Terminal installed (or already present)." }
if ($InstallCmder)          { Write-Host "Cmder installed (full or mini as configured). Launch 'Cmder' from Start menu." }
if ($InstallCUDA)           { Write-Host "CUDA prep done. If driver was installed, reboot is recommended before using PyTorch CUDA." }
if ($InstallDocker)         { Write-Host "Docker Desktop installed. Sign out/in once if 'docker-users' membership is new." }
Write-Host "pixi installed. Open a NEW terminal to get pixi on PATH (installs to $env:USERPROFILE\.pixi\bin)."

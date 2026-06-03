<#
.SYNOPSIS
    End-to-end build driver for the Qpic Flutter desktop app on Windows
    (Req 21.5, 22.1).

.DESCRIPTION
    Replaces the legacy pywebview/PySide6 build scripts (`build_desktop.sh`,
    `build_desktop.bat`, `build_desktop_qt.sh`): instead of packaging a Python
    window app, it builds the headless PyInstaller **sidecar** and the native
    **Flutter** desktop app, then embeds the sidecar inside the Flutter runner
    and packages a Windows installer (MSIX by default, or NSIS).

    Pipeline (design "Build Scripts & Dev Workflow", Req 22):
      1. pip install runtime sidecar deps (+ optional Local ML runtime)
      2. python scripts/vendor_tesseract.py --langs eng,hin,osd       (offline OCR)
      3. pyinstaller packaging/sidecar.spec --noconfirm               (sidecar onedir)
      4. flutter build windows                                       ┐ delegated to
      5. embed the sidecar + package MSIX|NSIS                       │ packaging/windows/
      6. optional Authenticode signing (when cert env vars are set)  ┘ build_windows.ps1

    Steps 4-6 are delegated to packaging/windows/build_windows.ps1 (Task 21.2),
    which runs `flutter build windows --release`, copies dist\qpic-sidecar\ into
    the runner's sidecar\ subfolder, builds the installer, and Authenticode-signs
    the app/sidecar/installer only when WIN_CERT_PATH / WIN_CERT_PASSWORD (or
    WIN_SIGN_THUMBPRINT) are present. With no cert env vars the build still
    completes with unsigned artifacts.

.PARAMETER Installer
    Installer kind to produce: 'msix' (default) or 'nsis'. Passed through to
    packaging/windows/build_windows.ps1.

.PARAMETER Langs
    Comma-separated Tesseract traineddata languages to vendor. Default eng,hin,osd.

.PARAMETER Python
    Python interpreter/launcher to use. Default 'python'.

.PARAMETER SkipDeps
    Reuse already-installed Python dependencies (skip pip install).

.PARAMETER SkipVendor
    Skip the Tesseract vendoring step (reuse vendor\tesseract).

.PARAMETER SkipSidecar
    Reuse an existing dist\qpic-sidecar onedir (skip PyInstaller).

.PARAMETER SkipFlutterBuild
    Reuse an existing `flutter build windows` output (forwarded to the packager).

.ENVIRONMENT
    WIN_CERT_PATH / WIN_CERT_PASSWORD   Enable Authenticode signing via .pfx.
    WIN_SIGN_THUMBPRINT                 Sign via a cert in the store (alt to .pfx).
    WIN_TIMESTAMP_URL                   RFC-3161 timestamp server.
    These are read by packaging/windows/build_windows.ps1 (inherited by the child).

.EXAMPLE
    pwsh build_desktop_flutter.ps1
    # Full build, unsigned MSIX.

.EXAMPLE
    $env:WIN_CERT_PATH = 'C:\certs\qpic.pfx'; $env:WIN_CERT_PASSWORD = 's3cret'
    pwsh build_desktop_flutter.ps1 -Installer nsis
    # Signed NSIS installer.
#>
[CmdletBinding()]
param(
    [ValidateSet('msix', 'nsis')]
    [string]$Installer = 'msix',

    [string[]]$Langs = @('eng', 'hin', 'osd'),

    [string]$Python = 'python',

    [switch]$SkipDeps,

    [switch]$SkipVendor,

    [switch]$SkipSidecar,

    [switch]$SkipFlutterBuild
)

# Fail fast: surface any non-terminating error so a half-built installer never
# ships silently.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$SidecarDist = Join-Path (Join-Path $RepoRoot 'dist') 'qpic-sidecar'
$PackageScript = Join-Path (Join-Path (Join-Path $RepoRoot 'packaging') 'windows') 'build_windows.ps1'

function Write-Step([string]$Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}
function Write-Warn([string]$Message) {
    Write-Warning $Message
}

Push-Location $RepoRoot
try {
    # Resolve the Python interpreter early so a typo fails before any work.
    if (-not (Get-Command $Python -ErrorAction SilentlyContinue)) {
        throw "Python interpreter not found: '$Python'. Pass -Python <path> or install Python."
    }

    # -----------------------------------------------------------------------
    # 1. Install sidecar build dependencies
    # -----------------------------------------------------------------------
    if ($SkipDeps) {
        Write-Step "Skipping dependency install (-SkipDeps)"
    }
    else {
        Write-Step "Installing build dependencies (runtime + desktop + optional Local ML)"
        & $Python -m pip install -r requirements.txt -r requirements-desktop.txt
        if ($LASTEXITCODE -ne 0) { throw "pip install failed ($LASTEXITCODE)" }
        if (Test-Path 'requirements-local-ml.txt') {
            & $Python -m pip install -r requirements-local-ml.txt
            if ($LASTEXITCODE -ne 0) { throw "pip install local ML runtime failed ($LASTEXITCODE)" }
        }
    }

    # -----------------------------------------------------------------------
    # 2. Vendor a self-contained Tesseract for offline OCR
    # -----------------------------------------------------------------------
    if ($SkipVendor) {
        Write-Step "Skipping Tesseract vendoring (-SkipVendor)"
    }
    else {
        $LangsStr = $Langs -join ','
        Write-Step "Vendoring Tesseract (langs: $LangsStr)"
        & $Python scripts/vendor_tesseract.py --langs $LangsStr
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Could not vendor Tesseract. The app will still build, but OCR for"
            Write-Warn "scanned PDFs will need a system Tesseract install."
            Write-Warn "Install it from: https://github.com/UB-Mannheim/tesseract/wiki"
        }
    }

    # -----------------------------------------------------------------------
    # 3. Build the headless PyInstaller sidecar (onedir)
    # -----------------------------------------------------------------------
    if ($SkipSidecar) {
        Write-Step "Skipping sidecar build (-SkipSidecar); reusing dist\qpic-sidecar"
        if (-not (Test-Path $SidecarDist)) {
            throw "dist\qpic-sidecar not found; cannot -SkipSidecar."
        }
    }
    else {
        Write-Step "Building sidecar: pyinstaller packaging/sidecar.spec --noconfirm"
        & $Python -m PyInstaller packaging/sidecar.spec --noconfirm
        if ($LASTEXITCODE -ne 0) { throw "pyinstaller failed ($LASTEXITCODE)" }
        if (-not (Test-Path $SidecarDist)) {
            throw "Sidecar onedir not produced at dist\qpic-sidecar."
        }
    }

    # -----------------------------------------------------------------------
    # 4-6. Flutter build + embed sidecar + package + Authenticode sign
    # -----------------------------------------------------------------------
    if (-not (Test-Path $PackageScript)) {
        throw "Missing Windows packaging script: $PackageScript"
    }

    Write-Step "Delegating Flutter build + embed + installer packaging to build_windows.ps1"
    # build_windows.ps1 runs `flutter build windows --release`, embeds the
    # sidecar onedir into the runner's sidecar\ folder, builds the MSIX/NSIS
    # installer, and Authenticode-signs only when the WIN_CERT_* env vars are
    # set (those are inherited by the child invocation automatically).
    $packageArgs = @{ Installer = $Installer }
    if ($SkipFlutterBuild) { $packageArgs['SkipFlutterBuild'] = $true }

    & $PackageScript @packageArgs
    if ($LASTEXITCODE -ne 0) { throw "build_windows.ps1 failed ($LASTEXITCODE)" }

    Write-Step "Done. Installer is in dist\ (see build_windows.ps1 output above)."
}
finally {
    Pop-Location
}

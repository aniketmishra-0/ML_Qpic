<#
.SYNOPSIS
    Windows packaging driver for the Qpic Flutter desktop app (Req 21.2, 21.3,
    21.5, 21.6, 21.7).

.DESCRIPTION
    Produces a Windows installer that embeds the headless PyInstaller sidecar
    (with its bundled Tesseract) so the Flutter app resolves and launches it at
    runtime via `lib/core/paths.dart`.

    Pipeline:
      1. `flutter build windows --release` (skippable with -SkipFlutterBuild).
      2. Copy the sidecar onedir (`dist/qpic-sidecar/`) into the runner's
         `sidecar/` subfolder. The onedir already contains `tesseract/`
         (see packaging/sidecar.spec), so this single copy embeds both the
         engine and the bundled Tesseract (Req 21.3).
      3. Authenticode-sign the app exe and the sidecar exe IF a certificate is
         supplied via WIN_CERT_PATH / WIN_CERT_PASSWORD; otherwise leave them
         unsigned (Req 21.7).
      4. Build the installer:
           * MSIX (default) via the `msix` pub package, or
           * NSIS via packaging/windows/installer.nsi.
         Both embed the runner folder including `sidecar/` (Req 21.2).
      5. Authenticode-sign the installer when a certificate is supplied;
         otherwise leave it unsigned (Req 21.7).

    Signing is fully gated on the cert env vars: when WIN_CERT_PATH or
    WIN_CERT_PASSWORD are absent, every signing step is skipped and the build
    still completes successfully with unsigned artifacts.

    NOTE: This script can only run on Windows (it shells out to `flutter build
    windows`, `signtool`, `makensis`, and the `msix` package). It is authored
    and statically reviewed on the CI/macOS side but executes on windows-latest.

.PARAMETER Installer
    Installer kind to produce: 'msix' (default) or 'nsis'.

.PARAMETER Configuration
    Flutter build configuration: 'Release' (default), 'Profile', or 'Debug'.

.PARAMETER SkipFlutterBuild
    Reuse an existing `flutter build windows` output instead of rebuilding.

.PARAMETER RepoRoot
    Repository root. Defaults to two levels above this script (packaging/windows).

.PARAMETER OutputDir
    Where the final installer is written. Defaults to <RepoRoot>/dist.

.ENVIRONMENT
    WIN_CERT_PATH       Path to a .pfx code-signing certificate. Enables signing.
    WIN_CERT_PASSWORD   Password for the .pfx. Required alongside WIN_CERT_PATH.
    WIN_TIMESTAMP_URL   RFC-3161 timestamp server. Defaults to DigiCert.
    WIN_SIGN_THUMBPRINT (optional) Use a cert from the store by thumbprint
                        instead of a .pfx file. Mutually exclusive with
                        WIN_CERT_PATH.

.EXAMPLE
    pwsh packaging/windows/build_windows.ps1
    # Unsigned MSIX (no cert env vars set).

.EXAMPLE
    $env:WIN_CERT_PATH = 'C:\certs\qpic.pfx'; $env:WIN_CERT_PASSWORD = 's3cret'
    pwsh packaging/windows/build_windows.ps1 -Installer nsis
    # Signed NSIS installer.
#>
[CmdletBinding()]
param(
    [ValidateSet('msix', 'nsis')]
    [string]$Installer = 'msix',

    [ValidateSet('Release', 'Profile', 'Debug')]
    [string]$Configuration = 'Release',

    [switch]$SkipFlutterBuild,

    [string]$RepoRoot,

    [string]$OutputDir
)

# Fail fast and treat non-terminating errors as terminating so a half-built
# installer never ships silently.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $RepoRoot) {
    # packaging/windows/ -> packaging/ -> <repo root>
    $RepoRoot = (Resolve-Path (Join-Path (Join-Path $ScriptDir '..') '..')).Path
}
$DesktopDir = Join-Path $RepoRoot 'desktop'
$SidecarDist = Join-Path (Join-Path $RepoRoot 'dist') 'qpic-sidecar'
if (-not $OutputDir) {
    $OutputDir = Join-Path $RepoRoot 'dist'
}

function Write-Step([string]$Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Signing helpers (no-ops when no certificate is configured)
# ---------------------------------------------------------------------------

$script:CertPath = $env:WIN_CERT_PATH
$script:CertPassword = $env:WIN_CERT_PASSWORD
$script:CertThumbprint = $env:WIN_SIGN_THUMBPRINT
$script:TimestampUrl = if ($env:WIN_TIMESTAMP_URL) { $env:WIN_TIMESTAMP_URL } else { 'http://timestamp.digicert.com' }

function Test-SigningEnabled {
    # Signing is enabled when EITHER a .pfx (path + password) OR a store
    # thumbprint is provided. Absent => unsigned build (Req 21.7).
    if ($script:CertThumbprint) { return $true }
    return [bool]($script:CertPath -and $script:CertPassword)
}

function Find-SignTool {
    # Prefer signtool on PATH; otherwise probe the Windows 10/11 SDK locations.
    $onPath = Get-Command 'signtool.exe' -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    $roots = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\bin",
        "$env:ProgramFiles\Windows Kits\10\bin"
    ) | Where-Object { $_ -and (Test-Path $_) }

    foreach ($root in $roots) {
        $candidate = Get-ChildItem -Path $root -Recurse -Filter 'signtool.exe' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\x64\\' } |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($candidate) { return $candidate.FullName }
    }
    throw "signtool.exe not found. Install the Windows SDK or add signtool to PATH."
}

function Invoke-Sign {
    param([Parameter(Mandatory)][string[]]$Files)

    if (-not (Test-SigningEnabled)) {
        Write-Host "    (signing skipped — WIN_CERT_PATH/WIN_CERT_PASSWORD not set)" -ForegroundColor DarkGray
        return
    }

    $existing = @($Files | Where-Object { $_ -and (Test-Path $_) })
    if ($existing.Count -eq 0) {
        Write-Host "    (no files to sign)" -ForegroundColor DarkGray
        return
    }

    $signtool = Find-SignTool
    $common = @('sign', '/fd', 'SHA256', '/tr', $script:TimestampUrl, '/td', 'SHA256')

    if ($script:CertThumbprint) {
        $signArgs = $common + @('/sha1', $script:CertThumbprint) + $existing
    }
    else {
        $signArgs = $common + @('/f', $script:CertPath, '/p', $script:CertPassword) + $existing
    }

    Write-Step "Authenticode signing $($existing.Count) file(s)"
    & $signtool @signArgs
    if ($LASTEXITCODE -ne 0) {
        throw "signtool failed with exit code $LASTEXITCODE"
    }
}

# ---------------------------------------------------------------------------
# 1. Flutter build
# ---------------------------------------------------------------------------

if (-not $SkipFlutterBuild) {
    Write-Step "flutter build windows --$($Configuration.ToLower())"
    Push-Location $DesktopDir
    try {
        & flutter config --enable-windows-desktop | Out-Null
        & flutter pub get
        if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed ($LASTEXITCODE)" }
        & flutter build windows "--$($Configuration.ToLower())"
        if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed ($LASTEXITCODE)" }
    }
    finally {
        Pop-Location
    }
}
else {
    Write-Step "Skipping flutter build (reusing existing output)"
}

# Locate the runner output. Modern Flutter emits build/windows/x64/runner/<Cfg>;
# older toolchains used build/windows/runner/<Cfg>. Support both.
$candidates = @(
    (Join-Path $DesktopDir "build\windows\x64\runner\$Configuration"),
    (Join-Path $DesktopDir "build\windows\runner\$Configuration")
)
$RunnerDir = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $RunnerDir) {
    throw "Flutter runner output not found. Looked in:`n  $($candidates -join "`n  ")"
}
Write-Host "    runner: $RunnerDir"

# ---------------------------------------------------------------------------
# 2. Embed the sidecar onedir (engine + bundled Tesseract) into sidecar/
# ---------------------------------------------------------------------------

if (-not (Test-Path $SidecarDist)) {
    throw @"
Sidecar onedir not found at:
  $SidecarDist
Build it first from the repo root:
  pyinstaller packaging/sidecar.spec --noconfirm
"@
}

$EmbeddedSidecar = Join-Path $RunnerDir 'sidecar'
Write-Step "Embedding sidecar -> $EmbeddedSidecar"
if (Test-Path $EmbeddedSidecar) {
    Remove-Item -Recurse -Force $EmbeddedSidecar
}
New-Item -ItemType Directory -Force -Path $EmbeddedSidecar | Out-Null
# Copy the contents of dist/qpic-sidecar/ INTO <runner>/sidecar/ so the exe lands
# at <runner>/sidecar/qpic-sidecar.exe, matching resolveSidecarExecutablePath().
Copy-Item -Path (Join-Path $SidecarDist '*') -Destination $EmbeddedSidecar -Recurse -Force

$SidecarExe = Join-Path $EmbeddedSidecar 'qpic-sidecar.exe'
if (-not (Test-Path $SidecarExe)) {
    throw "Expected embedded sidecar exe not found at: $SidecarExe"
}
# Sanity-check that the bundled Tesseract rode along (Req 21.3 / Req 20).
$BundledTesseract = Join-Path $EmbeddedSidecar 'tesseract\tesseract.exe'
if (Test-Path $BundledTesseract) {
    Write-Host "    bundled Tesseract: present"
}
else {
    Write-Warning "Bundled Tesseract not found at sidecar\tesseract\tesseract.exe. OCR will require a system Tesseract install."
}

# ---------------------------------------------------------------------------
# 3. Sign app exe + sidecar exe (before packaging so package contents are signed)
# ---------------------------------------------------------------------------

# The Flutter app exe is the top-level .exe in the runner dir (its name comes
# from the runner CMake BINARY_NAME; resolve dynamically rather than hardcode).
$AppExe = Get-ChildItem -Path $RunnerDir -Filter '*.exe' -File |
    Sort-Object Length -Descending |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $AppExe) {
    throw "No Flutter app .exe found in runner dir: $RunnerDir"
}
Invoke-Sign -Files (@($AppExe) + @($SidecarExe))

# ---------------------------------------------------------------------------
# 4. Build the installer
# ---------------------------------------------------------------------------

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

switch ($Installer) {
    'msix' {
        Write-Step "Building MSIX via the msix pub package"
        Push-Location $DesktopDir
        try {
            # Write the package straight to OutputDir with a stable name.
            $msixArgs = @('run', 'msix:create',
                          '--output-path', $OutputDir,
                          '--output-name', 'Qpic-Windows')

            # Pass certificate options through to the package signer so the .msix
            # is signed. msix --signtool-options overrides certificate_path.
            if (Test-SigningEnabled) {
                if ($script:CertThumbprint) {
                    $msixArgs += @('--signtool-options', "/sha1 $($script:CertThumbprint) /fd SHA256 /tr $($script:TimestampUrl) /td SHA256")
                }
                else {
                    $msixArgs += @('--certificate-path', $script:CertPath,
                                   '--certificate-password', $script:CertPassword)
                }
                # Do not auto-install the dev cert into the trust store in CI.
                $msixArgs += @('--install-certificate', 'false')
            }
            else {
                # Sign tool not enabled; build an unsigned MSIX package.
                # When sign-msix is false, msix requires a publisher name.
                $msixArgs += @('--sign-msix', 'false', '--publisher', 'CN=Qpic')
            }

            # NOTE: we intentionally do NOT pass --build-windows; the runner is
            # already built and the sidecar copied in, so msix packages the
            # existing Release folder (including sidecar/) verbatim.
            & dart @msixArgs
            if ($LASTEXITCODE -ne 0) { throw "msix:create failed ($LASTEXITCODE)" }
        }
        finally {
            Pop-Location
        }

        $dest = Join-Path $OutputDir 'Qpic-Windows.msix'
        if (-not (Test-Path $dest)) {
            throw "msix:create reported success but no .msix was found at $dest"
        }
        Write-Host "    installer: $dest"
        # The MSIX package signature (applied by msix:create above) IS the
        # installer signature; no extra signtool pass is needed for .msix.
    }

    'nsis' {
        Write-Step "Building NSIS installer"
        $makensis = Get-Command 'makensis.exe' -ErrorAction SilentlyContinue
        if (-not $makensis) {
            $defaultPaths = @(
                "C:\Program Files (x86)\NSIS\makensis.exe",
                "C:\Program Files\NSIS\makensis.exe"
            )
            foreach ($p in $defaultPaths) {
                if (Test-Path $p) {
                    $makensis = Get-Command $p -ErrorAction SilentlyContinue
                    if ($makensis) { break }
                }
            }
        }
        if (-not $makensis) {
            throw "makensis.exe not found. Install NSIS (choco install nsis) or add it to PATH."
        }
        $nsi = Join-Path $ScriptDir 'installer.nsi'
        $installerExe = Join-Path $OutputDir 'Qpic-Windows-Setup.exe'

        & $makensis.Source `
            "/DSRC_DIR=$RunnerDir" `
            "/DOUT_FILE=$installerExe" `
            "/DAPP_EXE=$(Split-Path -Leaf $AppExe)" `
            $nsi
        if ($LASTEXITCODE -ne 0) { throw "makensis failed ($LASTEXITCODE)" }

        if (-not (Test-Path $installerExe)) {
            throw "NSIS reported success but installer not found at: $installerExe"
        }
        Write-Host "    installer: $installerExe"

        # 5. Sign the NSIS installer itself when a cert is configured.
        Invoke-Sign -Files @($installerExe)
    }
}

Write-Step "Done."
if (-not (Test-SigningEnabled)) {
    Write-Host "Artifacts are UNSIGNED (no WIN_CERT_PATH/WIN_CERT_PASSWORD)." -ForegroundColor Yellow
}

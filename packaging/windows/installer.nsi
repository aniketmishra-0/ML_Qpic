; ===========================================================================
; Qpic Windows installer (NSIS) — Req 21.2, 21.3, 21.6
;
; Packages the Flutter `flutter build windows` runner output (passed in as
; SRC_DIR) into a single-file .exe installer. The runner folder already
; contains the embedded `sidecar\` subfolder (engine + bundled Tesseract) that
; build_windows.ps1 copies in before invoking makensis, so a recursive copy of
; SRC_DIR ships both the app and the sidecar, exactly where
; lib/core/paths.dart resolves them at runtime
; (<install dir>\sidecar\qpic-sidecar.exe).
;
; This .nsi takes three /D defines from build_windows.ps1:
;   SRC_DIR   absolute path to the runner Release folder (its full contents
;             are installed recursively, including sidecar\)
;   OUT_FILE  absolute path of the installer .exe to produce
;   APP_EXE   file name of the Flutter app exe inside SRC_DIR (e.g. qpic_desktop.exe)
;
; Authenticode signing of the produced installer is handled by the PowerShell
; driver via signtool AFTER makensis runs (gated on WIN_CERT_PATH /
; WIN_CERT_PASSWORD), so this script contains no signing logic itself.
; ===========================================================================

Unicode true
SetCompressor /SOLID lzma

; ---- Defaults so the script still compiles for a quick standalone check -----
!ifndef SRC_DIR
  !define SRC_DIR "..\..\desktop\build\windows\x64\runner\Release"
!endif
!ifndef OUT_FILE
  !define OUT_FILE "..\..\dist\Qpic-Windows-Setup.exe"
!endif
!ifndef APP_EXE
  !define APP_EXE "qpic_desktop.exe"
!endif

!define APP_NAME       "Qpic"
!define APP_PUBLISHER  "Qpic"
!define APP_VERSION    "1.0.0"
!define APP_REGKEY     "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}"

!include "MUI2.nsh"

Name "${APP_NAME}"
OutFile "${OUT_FILE}"
Unicode true

; Per-user-capable but default to Program Files; request admin for a machine
; install with a Start Menu + uninstall entry.
InstallDir "$PROGRAMFILES64\${APP_NAME}"
InstallDirRegKey HKLM "Software\${APP_NAME}" "InstallDir"
RequestExecutionLevel admin

; ---- UI ------------------------------------------------------------------
!define MUI_ICON "app_icon.ico"
!define MUI_UNICON "app_icon.ico"
!define MUI_ABORTWARNING

; Welcome page configuration
!define MUI_WELCOMEPAGE_TITLE "Welcome to the Qpic Setup Wizard"
!define MUI_WELCOMEPAGE_TEXT "This wizard will guide you through the installation of Qpic, a powerful PDF utility client for auto crop, manual crop, rename batch, and other tools.\r\n\r\nClick Next to continue."
!insertmacro MUI_PAGE_WELCOME

; License page configuration
!insertmacro MUI_PAGE_LICENSE "..\..\LICENSE"

!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

; ---- Install -------------------------------------------------------------
Section "Install"
    SetOutPath "$INSTDIR"

    ; Recursively install the entire runner output. This includes the app exe,
    ; Flutter DLLs, data\ assets, AND the embedded sidecar\ folder (engine +
    ; bundled Tesseract) that the build driver copied in beforehand (Req 21.3).
    File /r "${SRC_DIR}\*.*"

    ; Start Menu shortcut to the Flutter app exe.
    CreateDirectory "$SMPROGRAMS\${APP_NAME}"
    CreateShortcut "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}"

    ; Uninstaller + Add/Remove Programs registration.
    WriteUninstaller "$INSTDIR\Uninstall.exe"
    WriteRegStr HKLM "Software\${APP_NAME}" "InstallDir" "$INSTDIR"
    WriteRegStr HKLM "${APP_REGKEY}" "DisplayName"     "${APP_NAME}"
    WriteRegStr HKLM "${APP_REGKEY}" "DisplayVersion"  "${APP_VERSION}"
    WriteRegStr HKLM "${APP_REGKEY}" "Publisher"       "${APP_PUBLISHER}"
    WriteRegStr HKLM "${APP_REGKEY}" "DisplayIcon"     "$INSTDIR\${APP_EXE}"
    WriteRegStr HKLM "${APP_REGKEY}" "UninstallString" "$INSTDIR\Uninstall.exe"
    WriteRegDWORD HKLM "${APP_REGKEY}" "NoModify" 1
    WriteRegDWORD HKLM "${APP_REGKEY}" "NoRepair" 1
SectionEnd

; ---- Uninstall -----------------------------------------------------------
Section "Uninstall"
    Delete "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk"
    RMDir  "$SMPROGRAMS\${APP_NAME}"

    ; Remove the whole install tree (app + embedded sidecar\).
    RMDir /r "$INSTDIR"

    DeleteRegKey HKLM "${APP_REGKEY}"
    DeleteRegKey HKLM "Software\${APP_NAME}"
SectionEnd

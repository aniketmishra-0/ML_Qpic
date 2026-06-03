/// Per-OS filesystem path resolution for the Qpic desktop app.
///
/// This module owns two concerns (Requirements 3.11, 24.4):
///
///  1. The **Writable_Data_Dir** — a per-user, writable folder for the engine's
///     temp crop jobs. The PyInstaller bundle is read-only (and wiped on exit),
///     so cropped images and zips must live somewhere persistent and writable.
///     The Flutter [SidecarManager] passes the resolved temp dir to the sidecar
///     through the `QPIC_TEMP_DIR` environment variable.
///
///  2. The **embedded sidecar executable** path, resolved relative to the app
///     bundle for packaged builds, with a developer fallback that runs the
///     engine from source via `python -m packaging.sidecar` so contributors do
///     not need to rebuild the PyInstaller bundle every iteration.
///
/// The locations are kept byte-for-byte identical to the Python reference in
/// `desktop._writable_data_dir()`:
///   * macOS   `~/Library/Application Support/Qpic` (temp → `…/Qpic/temp`)
///   * Windows `%LOCALAPPDATA%\Qpic`                (temp → `…\Qpic\temp`)
///   * Linux   `~/.local/share/qpic`               (temp → `…/qpic/temp`)
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Folder name shared with the engine for the per-user data directory.
const String kAppDataFolderName = 'Qpic';

/// Lower-cased data-folder name used on Linux (`~/.local/share/qpic`), matching
/// `desktop._writable_data_dir()`.
const String kAppDataFolderNameLinux = 'qpic';

/// Sub-folder under the data dir that holds the engine's temp crop jobs.
const String kTempDirName = 'temp';

/// Base name of the embedded PyInstaller sidecar executable.
///
/// This MUST match the `name` produced by `packaging/sidecar.spec`. On Windows
/// the `.exe` suffix is appended by [resolveSidecarExecutablePath].
const String kSidecarExecutableName = 'qpic-sidecar';

/// Folder (next to the runner / inside `Contents/Resources`) that holds the
/// embedded sidecar onedir bundle.
const String kSidecarDirName = 'sidecar';

// ---------------------------------------------------------------------------
// Writable data directory
// ---------------------------------------------------------------------------

/// Returns the per-user Writable_Data_Dir base (e.g. macOS
/// `~/Library/Application Support/Qpic`), creating it if missing.
///
/// Prefer [writableTempDir] for the value handed to the engine as
/// `QPIC_TEMP_DIR`.
Future<Directory> writableDataDir() async {
  final dir = Directory(await _baseDataDirPath());
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  return dir;
}

/// Returns the engine temp directory (`<data-dir>/temp`), creating it (and any
/// missing parents) if needed.
///
/// This is the value the [SidecarManager] passes to the sidecar through the
/// `QPIC_TEMP_DIR` environment variable (Requirement 3.11).
Future<Directory> writableTempDir() async {
  final base = await writableDataDir();
  final temp = Directory(resolveTempDirPath(base.path));
  if (!await temp.exists()) {
    await temp.create(recursive: true);
  }
  return temp;
}

/// Resolves the Writable_Data_Dir base path, falling back to `path_provider`
/// when the expected environment variables are unavailable.
Future<String> _baseDataDirPath() async {
  final env = Platform.environment;
  final fromEnv = resolveBaseDataDirPath(
    isMacOS: Platform.isMacOS,
    isWindows: Platform.isWindows,
    home: Platform.isWindows ? env['USERPROFILE'] : env['HOME'],
    localAppData: env['LOCALAPPDATA'],
  );
  if (fromEnv != null && fromEnv.isNotEmpty) {
    return fromEnv;
  }

  // Robust fallback when HOME/USERPROFILE/LOCALAPPDATA are absent: place a
  // `Qpic` folder beside path_provider's application-support directory.
  final support = await getApplicationSupportDirectory();
  return p.join(support.parent.path, kAppDataFolderName);
}

/// Pure computation of the Writable_Data_Dir base path from OS + environment
/// inputs. Returns `null` when the required inputs are missing so callers can
/// fall back to `path_provider`.
///
/// Exposed for unit testing; production code uses [writableDataDir].
String? resolveBaseDataDirPath({
  required bool isMacOS,
  required bool isWindows,
  String? home,
  String? localAppData,
}) {
  if (isMacOS) {
    if (home == null || home.isEmpty) return null;
    return p.join(home, 'Library', 'Application Support', kAppDataFolderName);
  }
  if (isWindows) {
    // `_writable_data_dir()` uses LOCALAPPDATA, falling back to the home dir.
    final base = (localAppData != null && localAppData.isNotEmpty)
        ? localAppData
        : home;
    if (base == null || base.isEmpty) return null;
    return p.join(base, kAppDataFolderName);
  }
  // Linux and other POSIX platforms.
  if (home == null || home.isEmpty) return null;
  return p.join(home, '.local', 'share', kAppDataFolderNameLinux);
}

/// Pure computation of the temp dir path from a data-dir base path.
///
/// Exposed for unit testing; production code uses [writableTempDir].
String resolveTempDirPath(String baseDataDirPath) =>
    p.join(baseDataDirPath, kTempDirName);

// ---------------------------------------------------------------------------
// Sidecar executable resolution
// ---------------------------------------------------------------------------

/// Returns the expected path to the embedded sidecar executable relative to the
/// running app bundle.
///
///  * macOS:   `…/Qpic.app/Contents/Resources/sidecar/qpic-sidecar`
///  * Windows: `…/<runner-dir>/sidecar/qpic-sidecar.exe`
///  * Linux:   `…/<runner-dir>/sidecar/qpic-sidecar`
///
/// This returns the *expected* path whether or not the file exists; use
/// [resolveSidecarCommand] to get a runnable command that automatically falls
/// back to running the engine from source in development.
String sidecarExecutablePath() => resolveSidecarExecutablePath(
      isMacOS: Platform.isMacOS,
      isWindows: Platform.isWindows,
      executablePath: Platform.resolvedExecutable,
    );

/// Pure computation of the embedded sidecar executable path given the OS and
/// the host application's executable path.
///
/// Exposed for unit testing; production code uses [sidecarExecutablePath].
String resolveSidecarExecutablePath({
  required bool isMacOS,
  required bool isWindows,
  required String executablePath,
}) {
  final exeDir = p.dirname(executablePath);
  if (isMacOS) {
    // .../Qpic.app/Contents/MacOS/Qpic  ->  .../Contents/Resources/sidecar/...
    final resourcesDir = p.normalize(p.join(exeDir, '..', 'Resources'));
    return p.join(resourcesDir, kSidecarDirName, kSidecarExecutableName);
  }
  if (isWindows) {
    return p.join(exeDir, kSidecarDirName, '$kSidecarExecutableName.exe');
  }
  // Linux / other: the onedir bundle sits next to the runner executable.
  return p.join(exeDir, kSidecarDirName, kSidecarExecutableName);
}

/// A runnable sidecar invocation: an [executable] plus [args], optionally run
/// from [workingDirectory]. Consumed by the [SidecarManager], which calls
/// `Process.start(command.executable, command.args, …)`.
class SidecarCommand {
  const SidecarCommand({
    required this.executable,
    this.args = const <String>[],
    this.workingDirectory,
    this.isDevFallback = false,
  });

  /// The program to run — either the embedded sidecar binary or a Python
  /// interpreter when running from source.
  final String executable;

  /// Arguments passed to [executable]. Empty for the embedded binary; for the
  /// dev fallback this is `['-m', 'packaging.sidecar']`.
  final List<String> args;

  /// Working directory for the process. Set to the repo root for the dev
  /// fallback so `python -m packaging.sidecar` can import the engine packages.
  final String? workingDirectory;

  /// True when this command runs the engine from source instead of the embedded
  /// PyInstaller bundle.
  final bool isDevFallback;

  @override
  String toString() => isDevFallback
      ? 'SidecarCommand(dev: $executable ${args.join(' ')} @ $workingDirectory)'
      : 'SidecarCommand($executable)';
}

/// Resolves a runnable [SidecarCommand].
///
/// Resolution order:
///   1. `QPIC_SIDECAR_PATH` env override pointing at an executable (dev/CI).
///   2. The embedded sidecar binary from [sidecarExecutablePath] when present.
///   3. A development fallback that runs `python -m packaging.sidecar` from the
///      repo root so contributors can run from source (Requirement 24.4).
SidecarCommand resolveSidecarCommand() {
  final env = Platform.environment;

  final override = env['QPIC_SIDECAR_PATH'];
  if (override != null && override.isNotEmpty && File(override).existsSync()) {
    return SidecarCommand(executable: override);
  }

  final embedded = sidecarExecutablePath();
  if (File(embedded).existsSync()) {
    return SidecarCommand(executable: embedded);
  }

  // Development fallback: run the unchanged engine from source.
  // Prefer the project's .venv Python so all deps are available.
  final repoRoot = devRepoRoot();
  final venvPython = Platform.isWindows
      ? p.join(repoRoot, '.venv', 'Scripts', 'python.exe')
      : p.join(repoRoot, '.venv', 'bin', 'python');
  // Use the script path directly instead of `-m packaging.sidecar` because
  // the PyPI `packaging` package shadows the local `packaging/` directory
  // (which has no __init__.py).
  final sidecarScript = p.join(repoRoot, 'packaging', 'sidecar.py');

  // Resolve the Python interpreter: env override > venv > system python3.
  String python;
  if (env['QPIC_PYTHON'] != null && env['QPIC_PYTHON']!.isNotEmpty) {
    python = env['QPIC_PYTHON']!;
  } else {
    final venvFile = File(venvPython);
    if (venvFile.existsSync()) {
      // Use the venv path as-is (not resolved) so the venv is properly
      // activated. resolveSymbolicLinksSync() would follow through to the
      // system Python which loses the venv's site-packages.
      python = venvPython;
    } else {
      python = Platform.isWindows ? 'python' : 'python3';
    }
  }

  return SidecarCommand(
    executable: python,
    args: <String>[sidecarScript],
    workingDirectory: repoRoot,
    isDevFallback: true,
  );
}

/// Best-effort resolution of the repository root for the dev fallback so
/// `python -m packaging.sidecar` can import `packaging`, `app`, and `static`.
///
/// Honors a `QPIC_REPO_ROOT` override, otherwise walks up from both the
/// resolved executable path (which lives inside `desktop/build/…`) and the
/// current working directory looking for `packaging/sidecar.py`. On macOS the
/// CWD of a `.app` bundle is typically `/`, so the executable-based search is
/// the reliable path in development.
String devRepoRoot() {
  final override = Platform.environment['QPIC_REPO_ROOT'];
  if (override != null && override.isNotEmpty) {
    return override;
  }

  // Walk up from the running executable — in debug builds this lives inside
  // desktop/build/macos/Build/Products/Debug/…, so walking up will hit the
  // repo root reliably.
  final candidates = <Directory>[
    Directory(p.dirname(Platform.resolvedExecutable)).absolute,
    Directory.current.absolute,
  ];

  for (final start in candidates) {
    var dir = start;
    for (var i = 0; i < 12; i++) {
      final marker = File(p.join(dir.path, 'packaging', 'sidecar.py'));
      if (marker.existsSync()) {
        return dir.path;
      }
      final parent = dir.parent;
      if (p.equals(parent.path, dir.path)) {
        break; // reached the filesystem root
      }
      dir = parent;
    }
  }

  // The Flutter app typically runs from `desktop/`; the repo root is its parent.
  return Directory.current.parent.path;
}

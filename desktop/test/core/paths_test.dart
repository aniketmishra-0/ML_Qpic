import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qpic_desktop/core/paths.dart';

void main() {
  group('resolveBaseDataDirPath', () {
    test('macOS uses ~/Library/Application Support/Qpic', () {
      final result = resolveBaseDataDirPath(
        isMacOS: true,
        isWindows: false,
        home: '/Users/alex',
        localAppData: null,
      );
      expect(result, isNotNull);
      final parts = p.split(result!);
      expect(parts.sublist(parts.length - 4), [
        'alex',
        'Library',
        'Application Support',
        kAppDataFolderName,
      ]);
      expect(p.basename(result), kAppDataFolderName);
    });

    test('Windows uses LOCALAPPDATA\\Qpic when set', () {
      final result = resolveBaseDataDirPath(
        isMacOS: false,
        isWindows: true,
        home: r'C:\Users\alex',
        localAppData: r'C:\Users\alex\AppData\Local',
      );
      expect(result, isNotNull);
      expect(p.basename(result!), kAppDataFolderName);
      expect(result, contains('AppData'));
    });

    test('Windows falls back to home when LOCALAPPDATA is empty', () {
      final result = resolveBaseDataDirPath(
        isMacOS: false,
        isWindows: true,
        home: r'C:\Users\alex',
        localAppData: '',
      );
      expect(result, isNotNull);
      expect(p.basename(result!), kAppDataFolderName);
      // Falls back to the home dir component.
      expect(result, contains('alex'));
    });

    test('Linux uses ~/.local/share/qpic', () {
      final result = resolveBaseDataDirPath(
        isMacOS: false,
        isWindows: false,
        home: '/home/alex',
        localAppData: null,
      );
      expect(result, isNotNull);
      expect(p.basename(result!), kAppDataFolderNameLinux);
      expect(result, contains('.local'));
      expect(result, contains('share'));
    });

    test('returns null when required inputs are missing', () {
      expect(
        resolveBaseDataDirPath(isMacOS: true, isWindows: false, home: null),
        isNull,
      );
      expect(
        resolveBaseDataDirPath(isMacOS: true, isWindows: false, home: ''),
        isNull,
      );
      expect(
        resolveBaseDataDirPath(
          isMacOS: false,
          isWindows: true,
          home: null,
          localAppData: null,
        ),
        isNull,
      );
      expect(
        resolveBaseDataDirPath(isMacOS: false, isWindows: false, home: null),
        isNull,
      );
    });
  });

  group('resolveTempDirPath', () {
    test('appends the temp folder to the base data dir', () {
      final base = p.join('any', 'base', kAppDataFolderName);
      final temp = resolveTempDirPath(base);
      expect(p.basename(temp), kTempDirName);
      expect(p.dirname(temp), base);
    });
  });

  group('resolveSidecarExecutablePath', () {
    test('macOS resolves into Contents/Resources/sidecar', () {
      final exe = p.join(
        p.separator,
        'Applications',
        'Qpic.app',
        'Contents',
        'MacOS',
        'Qpic',
      );
      final result = resolveSidecarExecutablePath(
        isMacOS: true,
        isWindows: false,
        executablePath: exe,
      );
      final parts = p.split(result);
      expect(parts[parts.length - 1], kSidecarExecutableName);
      expect(parts[parts.length - 2], kSidecarDirName);
      expect(parts[parts.length - 3], 'Resources');
      expect(parts[parts.length - 4], 'Contents');
      // Must not contain the MacOS runner folder in the resolved path.
      expect(result, isNot(contains('MacOS')));
    });

    test('Windows resolves to sidecar/qpic-sidecar.exe next to the runner', () {
      final exe = p.join('C:', 'Program Files', 'Qpic', 'qpic.exe');
      final result = resolveSidecarExecutablePath(
        isMacOS: false,
        isWindows: true,
        executablePath: exe,
      );
      expect(p.basename(result), '$kSidecarExecutableName.exe');
      final parts = p.split(result);
      expect(parts[parts.length - 2], kSidecarDirName);
      expect(p.dirname(p.dirname(result)), p.dirname(exe));
    });

    test('Linux resolves to sidecar/qpic-sidecar next to the runner', () {
      final exe = p.join(p.separator, 'opt', 'qpic', 'qpic');
      final result = resolveSidecarExecutablePath(
        isMacOS: false,
        isWindows: false,
        executablePath: exe,
      );
      expect(p.basename(result), kSidecarExecutableName);
      final parts = p.split(result);
      expect(parts[parts.length - 2], kSidecarDirName);
      expect(p.dirname(p.dirname(result)), p.dirname(exe));
    });
  });

  group('SidecarCommand', () {
    test('embedded command has no args and is not a dev fallback', () {
      const cmd = SidecarCommand(executable: '/path/to/qpic-sidecar');
      expect(cmd.args, isEmpty);
      expect(cmd.isDevFallback, isFalse);
      expect(cmd.workingDirectory, isNull);
    });

    test('dev fallback command targets packaging.sidecar module', () {
      const cmd = SidecarCommand(
        executable: 'python3',
        args: ['-m', 'packaging.sidecar'],
        workingDirectory: '/repo',
        isDevFallback: true,
      );
      expect(cmd.args, ['-m', 'packaging.sidecar']);
      expect(cmd.isDevFallback, isTrue);
      expect(cmd.workingDirectory, '/repo');
    });
  });
}

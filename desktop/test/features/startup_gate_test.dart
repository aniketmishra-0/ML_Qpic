// Widget tests for the startup-state wiring (task 6.2).
//
// These verify how the StartupGate maps the SidecarManager's SidecarStatus
// lifecycle to UI, per Requirements:
//
//  * 3.4 — the tool UI stays disabled until the engine reports ready; once
//          ready the enabled shell is shown.
//  * 3.5 / 3.9 — a blocking startup-failure screen shows the captured engine
//          stderr and offers a Retry action.
//  * 3.10 — a non-dismissable engine-stopped banner with a Restart action is
//          shown over the disabled shell when the engine stops after ready.
//
// The gate consumes only the manager's public surface (a SidecarStatus stream,
// the current status, and a stderr accessor), so these tests drive it with a
// plain StreamController and a stub shell — no real engine/process is involved.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/core/sidecar_manager.dart';
import 'package:qpic_desktop/core/theme_controller.dart';
import 'package:qpic_desktop/features/shell/startup_gate.dart';

/// A stub shell that records the [enabled] flag it was built with, so tests can
/// assert the tool UI is disabled while the engine is not ready (Req 3.4).
class _StubShell extends StatelessWidget {
  const _StubShell({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Text(
          enabled ? 'SHELL ENABLED' : 'SHELL DISABLED',
          key: const ValueKey<String>('stub-shell'),
        ),
      ),
    );
  }
}

Widget _host({
  required Stream<SidecarStatus> status,
  required SidecarStatus initialStatus,
  required String Function() stderr,
  required Future<void> Function() onRestart,
}) {
  return MaterialApp(
    theme: QpicTheme.light,
    home: StartupGate(
      status: status,
      initialStatus: initialStatus,
      stderr: stderr,
      onRestart: onRestart,
      shellBuilder: (context, enabled) => _StubShell(enabled: enabled),
    ),
  );
}

void main() {
  group('StartupGate', () {
    testWidgets(
        'keeps the tool UI disabled while the engine is not ready '
        '(Requirement 3.4)', (tester) async {
      final controller = StreamController<SidecarStatus>.broadcast();
      addTearDown(controller.close);

      await tester.pumpWidget(
        _host(
          status: controller.stream,
          initialStatus: SidecarStatus.selectingPort,
          stderr: () => '',
          onRestart: () async {},
        ),
      );

      // Starting overlay is shown and the shell is disabled.
      expect(find.byKey(const ValueKey('startup-progress')), findsOneWidget);
      expect(find.text('SHELL DISABLED'), findsOneWidget);
      expect(find.text('SHELL ENABLED'), findsNothing);

      // Progress through the non-ready states — still disabled.
      controller.add(SidecarStatus.starting);
      await tester.pump();
      expect(find.text('SHELL DISABLED'), findsOneWidget);

      controller.add(SidecarStatus.waitingHealth);
      await tester.pump();
      expect(find.text('SHELL DISABLED'), findsOneWidget);
      expect(find.byKey(const ValueKey('startup-progress')), findsOneWidget);
    });

    testWidgets('enables the tool UI once the engine reports ready '
        '(Requirement 3.4)', (tester) async {
      final controller = StreamController<SidecarStatus>.broadcast();
      addTearDown(controller.close);

      await tester.pumpWidget(
        _host(
          status: controller.stream,
          initialStatus: SidecarStatus.waitingHealth,
          stderr: () => '',
          onRestart: () async {},
        ),
      );

      expect(find.text('SHELL DISABLED'), findsOneWidget);

      controller.add(SidecarStatus.ready);
      await tester.pump();

      // Enabled shell, no overlay/scrim, no banner.
      expect(find.text('SHELL ENABLED'), findsOneWidget);
      expect(find.byKey(const ValueKey('startup-progress')), findsNothing);
      expect(
        find.byKey(const ValueKey('engine-stopped-banner')),
        findsNothing,
      );
    });

    testWidgets(
        'shows a blocking failure screen with captured stderr and Retry '
        '(Requirements 3.5, 3.9)', (tester) async {
      final controller = StreamController<SidecarStatus>.broadcast();
      addTearDown(controller.close);
      var retries = 0;

      await tester.pumpWidget(
        _host(
          status: controller.stream,
          initialStatus: SidecarStatus.waitingHealth,
          stderr: () => 'Traceback: ModuleNotFoundError: fitz',
          onRestart: () async => retries++,
        ),
      );

      controller.add(SidecarStatus.failed);
      await tester.pump();

      // Blocking failure screen replaces the shell entirely.
      expect(
        find.byKey(const ValueKey('startup-failure-screen')),
        findsOneWidget,
      );
      expect(find.text('SHELL DISABLED'), findsNothing);
      expect(find.text('SHELL ENABLED'), findsNothing);

      // Captured stderr is shown verbatim.
      final SelectableText stderrText = tester.widget(
        find.byKey(const ValueKey('startup-failure-stderr')),
      );
      expect(stderrText.data, 'Traceback: ModuleNotFoundError: fitz');

      // Retry action invokes the restart hook.
      await tester.tap(find.byKey(const ValueKey('startup-retry-button')));
      await tester.pump();
      await tester.pump();
      expect(retries, 1);
    });

    testWidgets(
        'shows a non-dismissable engine-stopped banner with Restart over the '
        'disabled shell (Requirement 3.10)', (tester) async {
      final controller = StreamController<SidecarStatus>.broadcast();
      addTearDown(controller.close);
      var restarts = 0;

      await tester.pumpWidget(
        _host(
          status: controller.stream,
          initialStatus: SidecarStatus.ready,
          stderr: () => '',
          onRestart: () async => restarts++,
        ),
      );

      // Ready first.
      expect(find.text('SHELL ENABLED'), findsOneWidget);

      // Engine stops unexpectedly.
      controller.add(SidecarStatus.engineStopped);
      await tester.pump();

      // Banner is shown; shell is disabled beneath it. There is no close/
      // dismiss control — only Restart.
      expect(
        find.byKey(const ValueKey('engine-stopped-banner')),
        findsOneWidget,
      );
      expect(find.text('SHELL DISABLED'), findsOneWidget);
      expect(find.text('SHELL ENABLED'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('engine-restart-button')));
      await tester.pump();
      await tester.pump();
      expect(restarts, 1);
    });

    testWidgets(
        'recovers to the enabled shell after a successful restart from the '
        'failure screen (Requirements 3.9, 3.4)', (tester) async {
      final controller = StreamController<SidecarStatus>.broadcast();
      addTearDown(controller.close);

      await tester.pumpWidget(
        _host(
          status: controller.stream,
          initialStatus: SidecarStatus.waitingHealth,
          stderr: () => 'boom',
          onRestart: () async {},
        ),
      );

      controller.add(SidecarStatus.failed);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('startup-failure-screen')),
        findsOneWidget,
      );

      // A successful relaunch eventually drives the stream back to ready.
      controller.add(SidecarStatus.ready);
      await tester.pump();
      expect(find.text('SHELL ENABLED'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('startup-failure-screen')),
        findsNothing,
      );
    });
  });
}

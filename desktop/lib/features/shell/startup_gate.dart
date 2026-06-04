import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/sidecar_manager.dart';
import '../../core/theme_controller.dart';

/// Gates the tool UI on the engine sidecar's startup lifecycle (task 6.2).
///
/// The Flutter app must not let the user touch the tools until the engine is
/// actually serving requests, and it must surface a clear, recoverable error
/// whenever the engine cannot start or stops running. [StartupGate] subscribes
/// to the [SidecarManager]'s public [SidecarStatus] stream and maps each state
/// to one of three presentations:
///
///  * **Not ready** ([SidecarStatus.selectingPort], [SidecarStatus.starting],
///    [SidecarStatus.waitingHealth], [SidecarStatus.stopped]) — the shell is
///    rendered *disabled* (greyed tabs via [shellBuilder]'s `enabled` flag and
///    an [AbsorbPointer] over the whole shell) beneath a "starting the engine"
///    overlay, so no tool can be used until the engine reports ready
///    (Requirement 3.4).
///  * **Ready** ([SidecarStatus.ready]) — the shell is rendered enabled and the
///    overlay is gone; the UI is now bound to the published Base_URL
///    (Requirement 3.4).
///  * **Failed** ([SidecarStatus.failed]) — a *blocking* full-screen failure
///    view replaces the shell entirely, showing a human-readable message plus
///    the captured engine stderr, with a **Retry** action (Requirements 3.5,
///    3.9).
///  * **Engine stopped** ([SidecarStatus.engineStopped]) — a *non-dismissable*
///    banner is pinned over the now-disabled shell, telling the user the engine
///    stopped, with a **Restart** action (Requirement 3.10).
///
/// The gate consumes only the manager's public API. Rather than holding the
/// [SidecarManager] directly, it takes the exact slices it needs ([status],
/// [initialStatus], [stderr]) so it can be driven deterministically in tests
/// and so the engine's lifecycle owner ([QpicApp]) can swap in a fresh manager
/// on retry without reshaping this widget.
class StartupGate extends StatefulWidget {
  const StartupGate({
    super.key,
    required this.status,
    required this.initialStatus,
    required this.stderr,
    required this.onRestart,
    required this.shellBuilder,
  });

  /// The manager's broadcast lifecycle stream (`manager.status`).
  final Stream<SidecarStatus> status;

  /// The manager's status at the moment this gate is (re)built
  /// (`manager.currentStatus`), used as the seed before the first stream event
  /// and to recover the correct view after a hot restart of the gate.
  final SidecarStatus initialStatus;

  /// Accessor for the engine's captured stderr (`() => manager.capturedStderr`),
  /// read lazily when rendering the failure view so it reflects whatever the
  /// engine emitted up to the failure (Requirements 3.5, 3.9).
  final String Function() stderr;

  /// Invoked by the failure-screen **Retry** and the engine-stopped **Restart**
  /// actions. The owner re-initiates the full startup sequence (typically by
  /// creating and starting a fresh [SidecarManager]).
  final Future<void> Function() onRestart;

  /// Builds the application shell. [enabled] is `false` while the engine is not
  /// ready so the shell renders its tabs/controls in a disabled state
  /// (Requirement 3.4); the gate additionally blocks pointer input over the
  /// shell while disabled.
  final Widget Function(BuildContext context, bool enabled) shellBuilder;

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  late SidecarStatus _status;
  StreamSubscription<SidecarStatus>? _sub;

  /// True while an [onRestart] call is in flight, so the Retry/Restart buttons
  /// can be disabled to prevent double-triggering a relaunch.
  bool _restarting = false;

  @override
  void initState() {
    super.initState();
    _status = widget.initialStatus;
    _subscribe();
  }

  @override
  void didUpdateWidget(StartupGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    // When the owner swaps in a fresh manager (e.g. on retry), the status
    // stream identity changes: re-subscribe and reseed from the new manager's
    // current status.
    if (!identical(oldWidget.status, widget.status)) {
      _status = widget.initialStatus;
      _restarting = false;
      _subscribe();
    }
  }

  void _subscribe() {
    _sub?.cancel();
    _sub = widget.status.listen((next) {
      if (!mounted) return;
      setState(() => _status = next);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _handleRestart() async {
    if (_restarting) return;
    setState(() => _restarting = true);
    try {
      await widget.onRestart();
    } finally {
      if (mounted) {
        setState(() => _restarting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (_status) {
      case SidecarStatus.ready:
        return widget.shellBuilder(context, true);

      case SidecarStatus.failed:
        return StartupFailureScreen(
          stderr: widget.stderr(),
          onRetry: _handleRestart,
          retryInProgress: _restarting,
        );

      case SidecarStatus.engineStopped:
        return _DisabledShell(
          shell: widget.shellBuilder(context, false),
          overlay: EngineStoppedBanner(
            onRestart: _handleRestart,
            restartInProgress: _restarting,
          ),
          overlayAlignment: Alignment.topCenter,
        );

      case SidecarStatus.selectingPort:
      case SidecarStatus.starting:
      case SidecarStatus.waitingHealth:
      case SidecarStatus.stopped:
        return _DisabledShell(
          shell: widget.shellBuilder(context, false),
          overlay: const _StartingOverlay(),
          overlayAlignment: Alignment.center,
        );
    }
  }
}

/// Lays a disabled (input-blocked) shell beneath a pointer-enabled [overlay].
///
/// The shell is wrapped in an [AbsorbPointer] so none of its tools can be
/// interacted with while the engine is not ready, while the [overlay] (a
/// progress card or the engine-stopped banner) stays interactive so its action
/// button remains tappable.
class _DisabledShell extends StatelessWidget {
  const _DisabledShell({
    required this.shell,
    required this.overlay,
    required this.overlayAlignment,
  });

  final Widget shell;
  final Widget overlay;
  final AlignmentGeometry overlayAlignment;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        // Tool UI stays mounted (preserving state) but is inert until ready.
        AbsorbPointer(child: shell),
        // A dimming scrim communicates the disabled state without tearing the
        // shell down.
        const Positioned.fill(
          child: IgnorePointer(
            child: ColoredBox(color: Color(0x66000000)),
          ),
        ),
        Positioned.fill(
          child: SafeArea(
            child: Align(
              alignment: overlayAlignment,
              child: overlay,
            ),
          ),
        ),
      ],
    );
  }
}

/// Centered progress card shown while the engine is starting (Requirement 3.4).
class _StartingOverlay extends StatelessWidget {
  const _StartingOverlay();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();
    return Card(
      key: const ValueKey<String>('startup-progress'),
      color: palette?.panel ?? theme.colorScheme.surface,
      elevation: 6,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: 16),
            Text(
              'Starting the Qpic engine…',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: palette?.text ?? theme.colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Just a moment while the engine gets ready.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Blocking full-screen view shown when the engine fails to start within the
/// startup timeout, or after port-conflict retries are exhausted (Requirements
/// 3.5, 3.9).
///
/// Shows a human-readable explanation, the engine's captured [stderr]
/// verbatim (so the failure is diagnosable), and a **Retry** action that
/// re-initiates startup. Because it replaces the shell entirely, the tool UI is
/// unreachable while the engine is down.
class StartupFailureScreen extends StatelessWidget {
  const StartupFailureScreen({
    super.key,
    required this.stderr,
    required this.onRetry,
    this.retryInProgress = false,
  });

  /// The engine's captured stderr, shown verbatim to aid diagnosis.
  final String stderr;

  /// Re-initiates the startup sequence.
  final Future<void> Function() onRetry;

  /// Disables the Retry button and shows a spinner while a relaunch is running.
  final bool retryInProgress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();
    final danger = palette?.danger ?? theme.colorScheme.error;
    final hasStderr = stderr.trim().isNotEmpty;

    return Scaffold(
      key: const ValueKey<String>('startup-failure-screen'),
      backgroundColor: palette?.background ?? theme.colorScheme.surface,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(Icons.error_outline, color: danger, size: 28),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'The Qpic engine did not start',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: palette?.text ?? theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'The background engine could not be started, so the tools are '
                  'unavailable. The captured engine output below may explain why. '
                  'You can retry once the issue is resolved.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'Engine output',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: palette?.muted ?? theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 240),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: palette?.field ??
                        theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: palette?.border ?? theme.dividerColor,
                    ),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      hasStderr ? stderr : 'No diagnostic output was captured.',
                      key: const ValueKey<String>('startup-failure-stderr'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        color: hasStderr
                            ? (palette?.text ?? theme.colorScheme.onSurface)
                            : (palette?.muted ??
                                theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    key: const ValueKey<String>('startup-retry-button'),
                    onPressed: retryInProgress ? null : onRetry,
                    icon: retryInProgress
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                    label: Text(retryInProgress ? 'Retrying…' : 'Retry'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Non-dismissable banner pinned over the disabled shell when the engine exits
/// unexpectedly after having been ready (Requirement 3.10).
///
/// It has no close affordance — the only way forward is **Restart**, which
/// re-initiates the startup sequence.
class EngineStoppedBanner extends StatelessWidget {
  const EngineStoppedBanner({
    super.key,
    required this.onRestart,
    this.restartInProgress = false,
  });

  /// Re-initiates the startup sequence.
  final Future<void> Function() onRestart;

  /// Disables the Restart button and shows a spinner while a relaunch is
  /// running.
  final bool restartInProgress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();
    final danger = palette?.danger ?? theme.colorScheme.error;

    return Material(
      key: const ValueKey<String>('engine-stopped-banner'),
      elevation: 4,
      color: palette?.panel ?? theme.colorScheme.surface,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: danger, width: 3)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: <Widget>[
            Icon(Icons.warning_amber_rounded, color: danger, size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'The Qpic engine stopped',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: palette?.text ?? theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'The background engine is no longer running, so the tools '
                    'are disabled. Restart the engine to continue.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color:
                          palette?.muted ?? theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            FilledButton.icon(
              key: const ValueKey<String>('engine-restart-button'),
              onPressed: restartInProgress ? null : onRestart,
              icon: restartInProgress
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.restart_alt),
              label: Text(restartInProgress ? 'Restarting…' : 'Restart'),
            ),
          ],
        ),
      ),
    );
  }
}

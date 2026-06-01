import 'dart:async';

import 'package:flutter/material.dart';

import 'core/api_client.dart';
import 'core/download_service.dart';
import 'core/file_picker_service.dart';
import 'core/sidecar_bootstrap.dart';
import 'core/sidecar_manager.dart';
import 'core/theme_controller.dart';
import 'features/auto_crop/auto_crop_controller.dart';
import 'features/auto_crop/auto_crop_view.dart';
import 'features/rename/rename_controller.dart';
import 'features/rename/rename_view.dart';
import 'features/shell/app_shell.dart';
import 'features/shell/document_zoom_controller.dart';
import 'features/shell/document_zoom_scope.dart';
import 'features/shell/platform_menu_bar.dart';
import 'features/shell/startup_gate.dart';
import 'features/shell/tool_placeholder.dart';

/// Root MaterialApp for the Qpic desktop client.
///
/// Drives `MaterialApp.theme` / `darkTheme` / `themeMode` from [QpicTheme] and
/// a [ThemeController] (Requirement 4.5–4.9) and hosts the [AppShell] — the
/// top app bar with the Auto Crop / Manual Crop / Rename Batch / Tools tabs,
/// the Help control, and the segmented theme switcher (Requirement 4.1–4.4).
///
/// The controller is normally created and `load()`-ed in `main.dart` and
/// injected here. When no controller is supplied (e.g. lightweight widget
/// tests) the app creates and owns a default one, which starts in
/// [ThemeMode.system] (Requirement 4.9).
///
/// Startup wiring (task 6.2): when a [sidecarBootstrap] is supplied, the shell
/// is wrapped in a [StartupGate] that gates the tool UI on the engine's
/// lifecycle — the tabs stay disabled until the engine reports ready
/// (Requirement 3.4), a blocking failure screen with Retry appears if startup
/// fails or port retries are exhausted (Requirements 3.5, 3.9), and a
/// non-dismissable banner with Restart appears if the engine stops after being
/// ready (Requirement 3.10). The bootstrap's [SidecarBootstrap.start] is kicked
/// off here so the starting overlay shows immediately. When no bootstrap is
/// supplied (lightweight widget tests), the shell is rendered enabled directly.
class QpicApp extends StatefulWidget {
  const QpicApp({super.key, this.themeController, this.sidecarBootstrap});

  /// Optional injected controller. When null, [QpicApp] creates and owns one.
  final ThemeController? themeController;

  /// Optional engine bootstrap. When supplied, [QpicApp] starts it and wraps
  /// the shell in a [StartupGate]; when null, the shell is rendered enabled
  /// with no startup gating.
  final SidecarBootstrap? sidecarBootstrap;

  @override
  State<QpicApp> createState() => _QpicAppState();
}

class _QpicAppState extends State<QpicApp> {
  late final ThemeController _controller;

  /// Backs the Auto Crop form (Requirement 5). Owned by the app so the form
  /// retains its state across tab switches (the shell keeps every tool view
  /// mounted). The submit path is wired by later tasks (9.2 / 12.5).
  final AutoCropController _autoCropController = AutoCropController();

  /// Backs the Rename Batch form (Requirement 12). Owned by the app so the
  /// form retains its state across tab switches. The session flow (file
  /// picking, rename & download) is wired by task 15.2 against the engine's
  /// Base_URL once the sidecar reports ready.
  final RenameController _renameController =
      RenameController(filePickerService: const FilePickerService());

  /// Tracks the engine lifecycle so feature controllers can be (re)bound to the
  /// published Base_URL on ready and unbound when the engine stops.
  StreamSubscription<SidecarStatus>? _engineStatusSub;

  /// Shell-wide zoom registry. The platform menu bar and zoom shortcuts drive
  /// whichever document view is currently active via this registry
  /// (Requirement 19.4).
  final ActiveDocumentZoom _zoomRegistry = ActiveDocumentZoom();

  /// Whether this widget created the controller and is responsible for
  /// disposing it. Injected controllers are owned by the caller (`main.dart`).
  late final bool _ownsController;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.themeController == null;
    _controller = widget.themeController ?? ThemeController();
    // Kick off engine startup so the StartupGate shows the starting overlay
    // immediately and transitions to ready/failed as the manager progresses.
    final bootstrap = widget.sidecarBootstrap;
    if (bootstrap != null) {
      // Bind the engine-backed services (ApiClient + DownloadService) to the
      // feature controllers whenever the sidecar publishes its Base_URL, and
      // unbind them if the engine stops or fails, so the rename PDF/session
      // affordances always target the live engine (task 15.2).
      _engineStatusSub = bootstrap.status.listen(_onEngineStatus);
      bootstrap.start();
      // Seed from the current status in case `ready` was reached before the
      // listener was attached.
      _onEngineStatus(bootstrap.currentStatus);
    }
  }

  /// Reacts to engine lifecycle transitions: binds the rename controller to a
  /// fresh [ApiClient] on ready (Requirement 3.4) and unbinds it otherwise so
  /// the engine-dependent affordances guard against an unavailable engine.
  void _onEngineStatus(SidecarStatus status) {
    final bootstrap = widget.sidecarBootstrap;
    final baseUrl = bootstrap?.baseUrl;
    if (status == SidecarStatus.ready && baseUrl != null) {
      if (_renameController.apiClient == null) {
        final apiClient = ApiClient(baseUrl);
        _renameController.bindEngine(
          apiClient: apiClient,
          downloadService: DownloadService(apiClient),
        );
      }
    } else if (_renameController.engineReady) {
      _renameController.unbindEngine();
    }
  }

  @override
  void dispose() {
    _engineStatusSub?.cancel();
    _autoCropController.dispose();
    _renameController.dispose();
    _zoomRegistry.dispose();
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  /// Builds the view for a given tool tab. Auto Crop and Rename Batch render
  /// their real forms; the remaining tools fall back to placeholders until
  /// their own tasks land.
  Widget _buildToolView(QpicTool tool) {
    switch (tool) {
      case QpicTool.autoCrop:
        return AutoCropView(
          key: const ValueKey<String>('tool-view-autoCrop'),
          controller: _autoCropController,
          onSubmit: () => _autoCropController.submit(),
        );
      case QpicTool.renameBatch:
        // The naming controls + live preview (task 15.1) are driven by the
        // controller. The native file picker and the rename-&-download session
        // flow (task 15.2) are wired here: `onPickFiles` opens the images-and-
        // PDF dialog (adding images directly and converting PDFs to page items
        // via the engine), and `onRename` runs the streamed session flow and
        // saves the ZIP. Both are no-ops until the engine is bound, so the
        // affordances stay disabled until the sidecar is ready.
        return AnimatedBuilder(
          animation: _renameController,
          builder: (context, _) {
            final ready = _renameController.engineReady;
            return RenameView(
              key: const ValueKey<String>('tool-view-renameBatch'),
              controller: _renameController,
              busy: _renameController.busy,
              errorText: _renameController.errorText,
              statusText: _renameController.statusText,
              onPickFiles: ready && !_renameController.busy
                  ? () => _renameController.pickAndAddFiles()
                  : null,
              onRename: ready &&
                      !_renameController.busy &&
                      _renameController.itemCount > 0
                  ? () => _renameController.rename()
                  : null,
            );
          },
        );
      case QpicTool.manualCrop:
      case QpicTool.tools:
        return ToolPlaceholder(
          key: ValueKey<String>('tool-view-${tool.name}'),
          label: tool.label,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild MaterialApp whenever the selected theme mode changes so the
    // palette is re-applied live, without an app restart (Requirement 4.6).
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return MaterialApp(
          title: 'Qpic',
          debugShowCheckedModeBanner: false,
          theme: QpicTheme.light,
          darkTheme: QpicTheme.dark,
          themeMode: _controller.themeMode,
          home: _buildHome(),
        );
      },
    );
  }

  /// Builds the app's home surface. With a [SidecarBootstrap] present, the shell
  /// is wrapped in a [StartupGate] that disables the tool UI until the engine is
  /// ready and presents the failure / engine-stopped recovery surfaces
  /// (Requirements 3.4, 3.5, 3.9, 3.10). Without one, the enabled shell is
  /// rendered directly (used by lightweight widget tests).
  Widget _buildHome() {
    final bootstrap = widget.sidecarBootstrap;
    if (bootstrap == null) {
      return _buildShellChrome(enabled: true);
    }
    return StartupGate(
      status: bootstrap.status,
      initialStatus: bootstrap.currentStatus,
      stderr: () => bootstrap.capturedStderr,
      onRestart: bootstrap.restart,
      shellBuilder: (context, enabled) => _buildShellChrome(enabled: enabled),
    );
  }

  /// Builds the shell chrome (menu bar + zoom scope + [AppShell]). [enabled]
  /// gates the shell's tabs and Help control on engine readiness
  /// (Requirement 3.4).
  Widget _buildShellChrome({required bool enabled}) {
    return QpicPlatformMenuBar(
      zoomRegistry: _zoomRegistry,
      child: DocumentZoomScope(
        registry: _zoomRegistry,
        child: AppShell(
          themeController: _controller,
          toolViewBuilder: _buildToolView,
          enabled: enabled,
        ),
      ),
    );
  }
}

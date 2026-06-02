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
import 'features/manual_crop/manual_crop_controller.dart';
import 'features/manual_crop/manual_crop_view.dart';
import 'features/rename/rename_controller.dart';
import 'features/rename/rename_view.dart';
import 'features/review/review_controller.dart';
import 'features/review/review_screen.dart';
import 'features/shell/app_shell.dart';
import 'features/shell/document_zoom_controller.dart';
import 'features/shell/document_zoom_scope.dart';
import 'features/shell/platform_menu_bar.dart';
import 'features/shell/startup_gate.dart';
import 'features/shell/tool_placeholder.dart';
import 'models/analyze.dart';

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

  /// Navigator key shared with [QpicPlatformMenuBar] so the Help dialog can be
  /// opened through the MaterialApp's navigator even though the menu bar sits
  /// above it (avoids the PlatformMenuBar context-lock assertion).
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  /// Backs the Auto Crop form (Requirement 5). Owned by the app so the form
  /// retains its state across tab switches (the shell keeps every tool view
  /// mounted). Bound to the engine on ready so its non-Smart crop (task 9.2)
  /// and Smart analyze (task 12.5) target the live Base_URL.
  final AutoCropController _autoCropController = AutoCropController();

  /// Native PDF picker shared by the crop flows (Requirement 17.1). Loads the
  /// chosen PDF into the Auto Crop controller before submit.
  final FilePickerService _filePickerService = const FilePickerService();

  /// Backs the Smart Auto Crop review session (Requirement 6.2). Owned by the
  /// app so the review state survives tab switches while the canvas is open.
  /// Populated from a successful `POST /api/analyze` and reset when the user
  /// leaves the canvas.
  final ReviewController _autoCropReview = ReviewController();

  /// Whether the Smart Auto Crop Review Canvas is currently shown. Flipped true
  /// after a successful analyze (Requirement 6.2) and false when the user
  /// returns to the form.
  bool _autoCropReviewOpen = false;

  /// Backs the Rename Batch form (Requirement 12). Owned by the app so the
  /// form retains its state across tab switches. The session flow (file
  /// picking, rename & download) is wired by task 15.2 against the engine's
  /// Base_URL once the sidecar reports ready.
  final RenameController _renameController =
      RenameController(filePickerService: const FilePickerService());

  /// Backs the Manual Crop tool (Requirement 7). Owned by the app so the tool
  /// retains its OWN output config (prefix/start/format/quality) independently
  /// of Auto Crop across tab switches (Requirement 7.3). The open flow
  /// (`POST /api/prepare-manual` → Review Canvas) is bound to the engine's
  /// Base_URL once the sidecar reports ready; the manual finalize is task 13.2.
  final ManualCropController _manualCropController =
      ManualCropController(filePickerService: const FilePickerService());

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

  /// Reacts to engine lifecycle transitions: binds the auto-crop, rename and
  /// manual-crop controllers to a fresh [ApiClient] on ready (Requirement 3.4)
  /// and unbinds them otherwise so the engine-dependent affordances guard
  /// against an unavailable engine.
  void _onEngineStatus(SidecarStatus status) {
    final bootstrap = widget.sidecarBootstrap;
    final baseUrl = bootstrap?.baseUrl;
    if (status == SidecarStatus.ready && baseUrl != null) {
      if (_autoCropController.apiClient == null) {
        final apiClient = ApiClient(baseUrl);
        _autoCropController.bindEngine(
          apiClient: apiClient,
          downloadService: DownloadService(apiClient),
        );
      }
      if (_renameController.apiClient == null) {
        final apiClient = ApiClient(baseUrl);
        _renameController.bindEngine(
          apiClient: apiClient,
          downloadService: DownloadService(apiClient),
        );
      }
      if (_manualCropController.apiClient == null) {
        final apiClient = ApiClient(baseUrl);
        _manualCropController.bindEngine(
          apiClient: apiClient,
          downloadService: DownloadService(apiClient),
        );
      }
      if (_autoCropReview.apiClient == null) {
        final apiClient = ApiClient(baseUrl);
        _autoCropReview.bindEngine(
          apiClient: apiClient,
          downloadService: DownloadService(apiClient),
        );
      }
    } else {
      if (_autoCropController.engineReady) {
        _autoCropController.unbindEngine();
      }
      if (_renameController.engineReady) {
        _renameController.unbindEngine();
      }
      if (_manualCropController.engineReady) {
        _manualCropController.unbindEngine();
      }
      if (_autoCropReview.engineReady) {
        _autoCropReview.unbindEngine();
      }
    }
  }

  @override
  void dispose() {
    _engineStatusSub?.cancel();
    _autoCropController.dispose();
    _autoCropReview.dispose();
    _renameController.dispose();
    _manualCropController.dispose();
    _zoomRegistry.dispose();
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  // --- Auto Crop file picking + Smart analyze entry (Req 6.1, 6.2, 17.1) ---

  /// Opens the native PDF dialog and loads the chosen file into the Auto Crop
  /// controller (Req 17.1). A no-op when the user cancels.
  Future<void> _pickAutoCropPdf() async {
    final picked = await _filePickerService.pickPdf();
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    _autoCropController.setFile(bytes: bytes, filename: picked.name);
  }

  /// Runs the Auto Crop submit. For a non-Smart crop the controller streams the
  /// archive itself; for a Smart submit a successful `POST /api/analyze` lands
  /// an [AutoCropController.analyzeResult], which this opens in the shared
  /// Review Canvas regardless of `needs_review` (Req 6.2). On an analyze error
  /// the controller surfaces the engine `detail` and stores no analysis, so the
  /// canvas is NOT opened (Req 6.7).
  Future<void> _submitAutoCrop() async {
    await _autoCropController.submit();
    final analysis = _autoCropController.analyzeResult;
    if (analysis != null) {
      _openAutoCropReview(analysis);
    }
  }

  /// Loads an analyze response into the shared review session and shows the
  /// Review Canvas (Req 6.2). The `answer_key_count` carried on the response
  /// drives the canvas's answer-sheet advisory (Req 6.4, 6.5).
  void _openAutoCropReview(AnalyzeResponse analysis) {
    _autoCropReview.loadFromAnalyze(analysis);
    // Consume the stored result so a later rebuild doesn't re-open the canvas.
    _autoCropController.consumeAnalyzeResult();
    setState(() => _autoCropReviewOpen = true);
  }

  /// Returns from the Review Canvas to the Auto Crop form, clearing the review
  /// session.
  void _closeAutoCropReview() {
    _autoCropReview.reset();
    setState(() => _autoCropReviewOpen = false);
  }

  /// Finalizes the reviewed Smart Auto Crop set (Req 6.6): builds a
  /// `FinalizeRequest` from the kept auto items plus drawn/re-selected items and
  /// the Auto Crop tool's output config, calls `POST /api/finalize`, and — on
  /// success — leaves the Combined/Questions/Solutions download actions on the
  /// Review Canvas (Req 11.1–11.5). The Answer-sheet toggle is honored via
  /// `answer_sheet` (Req 11.5). On an engine error the canvas keeps the items so
  /// the user can retry. The review controller owns the call + state, so this
  /// just forwards the tool's output config.
  Future<void> _finalizeAutoCropReview() async {
    await _autoCropReview.finalize(
      dpi: _autoCropController.dpi,
      padding: _autoCropController.padding,
      questionPrefix: _autoCropController.questionPrefix,
      solutionPrefix: _autoCropController.solutionPrefix,
      startNumber: _autoCropController.startNumber,
      imageFormat: _autoCropController.imageFormatValue,
      jpgQuality: _autoCropController.jpgQuality,
      answerSheet: _autoCropController.answerSheet,
    );
  }

  /// Builds the view for a given tool tab. Auto Crop and Rename Batch render
  /// their real forms; the remaining tools fall back to placeholders until
  /// their own tasks land.
  Widget _buildToolView(QpicTool tool) {
    switch (tool) {
      case QpicTool.autoCrop:
        // The form drives the submit guards + the non-Smart crop (task 9.2) and
        // the Smart analyze entry (this task). When a Smart analyze succeeds the
        // app shows the shared Review Canvas inline (Req 6.2); the form is
        // restored when the user leaves the canvas. `onPickFile` opens the
        // native PDF dialog and loads the bytes into the controller (Req 17.1);
        // both affordances stay disabled until the engine is bound.
        return AnimatedBuilder(
          animation: _autoCropController,
          builder: (context, _) {
            if (_autoCropReviewOpen) {
              final apiClient = _autoCropController.apiClient;
              return ReviewScreen(
                key: const ValueKey<String>('tool-view-autoCrop'),
                controller: _autoCropReview,
                questionPrefix: _autoCropController.questionPrefix,
                solutionPrefix: _autoCropController.solutionPrefix,
                previewUrlResolver: apiClient != null
                    ? (url) => apiClient.resolveUri(url).toString()
                    : null,
                onClose: _closeAutoCropReview,
                onFinalize: _autoCropReview.engineReady
                    ? _finalizeAutoCropReview
                    : null,
              );
            }
            final ready = _autoCropController.engineReady;
            return AutoCropView(
              key: const ValueKey<String>('tool-view-autoCrop'),
              controller: _autoCropController,
              onPickFile: ready && !_autoCropController.busy
                  ? _pickAutoCropPdf
                  : null,
              onSubmit: ready && !_autoCropController.busy
                  ? _submitAutoCrop
                  : null,
            );
          },
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
        // Manual Crop opens a PDF via POST /api/prepare-manual and drives the
        // shared Review Canvas with an empty item list (Req 7.1, 7.2). Its
        // output config is held independently of Auto Crop on its own
        // controller (Req 7.3). The picker/open affordance stays disabled until
        // the engine is bound; the preview resolver joins each page's
        // `preview_url` onto the live Base_URL.
        return AnimatedBuilder(
          animation: _manualCropController,
          builder: (context, _) {
            final ready = _manualCropController.engineReady;
            final apiClient = _manualCropController.apiClient;
            return ManualCropView(
              key: const ValueKey<String>('tool-view-manualCrop'),
              controller: _manualCropController,
              onPickFile: ready && !_manualCropController.busy
                  ? () => _manualCropController.pickPdf()
                  : null,
              previewUrlResolver:
                  apiClient != null ? (url) => apiClient.resolveUri(url).toString() : null,
            );
          },
        );
      case QpicTool.tools:
        return ToolPlaceholder(
          key: ValueKey<String>('tool-view-${tool.name}'),
          label: tool.label,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    // PlatformMenuBar must live ABOVE MaterialApp so it keeps a stable
    // BuildContext across MaterialApp rebuilds (theme changes). Flutter's
    // PlatformMenuBar locks onto its element's context — if a second context
    // tries to lock while the first is still active, an assertion fires.
    return QpicPlatformMenuBar(
      zoomRegistry: _zoomRegistry,
      navigatorKey: _navigatorKey,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return MaterialApp(
            title: 'Qpic',
            debugShowCheckedModeBanner: false,
            theme: QpicTheme.light,
            darkTheme: QpicTheme.dark,
            themeMode: _controller.themeMode,
            navigatorKey: _navigatorKey,
            home: _buildHome(),
          );
        },
      ),
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

  /// Builds the shell chrome (zoom scope + [AppShell]). [enabled] gates the
  /// shell's tabs and Help control on engine readiness (Requirement 3.4).
  /// The [QpicPlatformMenuBar] now lives above [MaterialApp] in [build], so
  /// it's not repeated here.
  Widget _buildShellChrome({required bool enabled}) {
    return DocumentZoomScope(
      registry: _zoomRegistry,
      child: AppShell(
        themeController: _controller,
        toolViewBuilder: _buildToolView,
        enabled: enabled,
      ),
    );
  }
}

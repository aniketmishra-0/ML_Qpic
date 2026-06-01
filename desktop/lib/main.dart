import 'package:flutter/widgets.dart';

import 'app.dart';
import 'core/sidecar_bootstrap.dart';
import 'core/theme_controller.dart';

/// Entry point for the Qpic desktop client.
///
/// Creates the [ThemeController] and `load()`s the persisted theme selection
/// before the first frame so the stored Light/Dark/System choice is applied on
/// launch without a flash of the wrong theme (Requirement 4.8, 4.9). The
/// controller is injected into [QpicApp], which drives `MaterialApp`'s theme.
///
/// A [SidecarBootstrap] is also created and injected so [QpicApp] gates the
/// tool UI on the engine's lifecycle (task 6.2): the tabs stay disabled until
/// the engine reports ready (Requirement 3.4), a blocking failure screen with
/// Retry appears on startup failure / exhausted retries (Requirements 3.5,
/// 3.9), and a non-dismissable Restart banner appears if the engine stops after
/// being ready (Requirement 3.10). [QpicApp] starts the bootstrap itself.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final themeController = ThemeController();
  await themeController.load();

  final sidecarBootstrap = SidecarBootstrap();

  runApp(
    QpicApp(
      themeController: themeController,
      sidecarBootstrap: sidecarBootstrap,
    ),
  );
}

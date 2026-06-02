// Platform menu bar providing standard macOS/Windows menus with Edit shortcuts
// and zoom shortcuts (Requirement 19.3, 19.4).
//
// On macOS this produces the native app menu bar (Qpic app menu, Edit, View,
// Help). On Windows/Linux it produces the equivalent via Flutter's
// PlatformMenuBar widget, which delegates to the platform's native menu system.
//
// The Edit menu provides cut/copy/paste/select-all that reach focused text
// fields — reproducing the fix that `desktop.py`'s `_install_macos_edit_menu`
// applies via AppKit selectors. Flutter's PlatformMenuBar with standard
// keyboard shortcuts dispatches to the focused text field's editing actions
// through the Actions/Shortcuts system.
//
// Zoom shortcuts (Ctrl/Cmd +/-/0) drive the active document view's zoom via
// the [ActiveDocumentZoom] registry, mirroring `desktop_qt.py`'s zoom
// shortcuts.

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'document_zoom_controller.dart';
import 'help_screen.dart';

/// Wraps [child] in a [PlatformMenuBar] that provides:
///
/// - **macOS app menu** with About, Services, Hide, Quit (Cmd+Q)
/// - **Edit menu** with Cut, Copy, Paste, Select All — these reach focused
///   text fields via standard keyboard shortcuts (Req 19.3)
/// - **View menu** with Zoom In (Cmd/Ctrl +), Zoom Out (Cmd/Ctrl -), and
///   Actual Size / Reset (Cmd/Ctrl 0) — these drive the active document view's
///   zoom (Req 19.4)
/// - **Help menu** with an entry that opens the in-app Help walkthrough
///
/// The [zoomRegistry] is the shell's [ActiveDocumentZoom] that forwards zoom
/// commands to whichever document view is currently active. When no document
/// view is active, zoom commands are harmless no-ops.
///
/// **Important:** This widget must be placed in a stable position in the widget
/// tree — specifically _outside_ any widget that might rebuild with a new
/// `BuildContext` (such as `MaterialApp`'s `home:`). Flutter's
/// `PlatformMenuBar` locks onto its element's context and asserts if a second
/// context tries to acquire the lock before the first releases it. Placing
/// this widget above `MaterialApp` avoids that race. Use [navigatorKey] to
/// provide a `GlobalKey<NavigatorState>` from the `MaterialApp` so the Help
/// dialog can route correctly.
class QpicPlatformMenuBar extends StatelessWidget {
  const QpicPlatformMenuBar({
    super.key,
    required this.zoomRegistry,
    this.navigatorKey,
    required this.child,
  });

  /// The shell-wide zoom registry that zoom shortcuts drive.
  final ActiveDocumentZoom zoomRegistry;

  /// Optional navigator key from the `MaterialApp`. Used by the Help menu to
  /// open a dialog through the app's navigator when this widget sits above the
  /// `MaterialApp` (and therefore lacks a `Navigator` ancestor in its own
  /// context).
  final GlobalKey<NavigatorState>? navigatorKey;

  /// The app content below the menu bar.
  final Widget child;

  /// Whether the current platform is macOS (uses Flutter's target platform
  /// which is consistent between runtime and test environments).
  static bool get _isMacOS => defaultTargetPlatform == TargetPlatform.macOS;

  @override
  Widget build(BuildContext context) {
    return PlatformMenuBar(
      menus: <PlatformMenuItem>[
        _buildAppMenu(),
        _buildEditMenu(),
        _buildViewMenu(),
        _buildHelpMenu(context),
      ],
      child: _wrapZoomShortcuts(child),
    );
  }

  /// Wraps [content] so the zoom shortcuts (Ctrl/Cmd +, -, 0) drive the active
  /// document view's zoom on every platform (Requirement 19.4).
  ///
  /// On macOS the [PlatformMenuBar] installs a real native menu whose key
  /// equivalents fire the View-menu items, so the menu already delivers the
  /// zoom shortcuts. On Windows and Linux, however, [PlatformMenuBar] renders
  /// only its child and does **not** activate menu-item shortcuts — so the
  /// "Windows equivalent" needs an explicit [Shortcuts]/[Actions] layer to make
  /// Ctrl +/-/0 reach [zoomRegistry]. (Edit shortcuts like Ctrl+C/V/X/A already
  /// work cross-platform via Flutter's built-in `DefaultTextEditingShortcuts`.)
  ///
  /// The bindings mirror `desktop_qt.py`'s zoom shortcuts: `Ctrl+=`/`Ctrl++`
  /// (and numpad +) zoom in, `Ctrl+-` (and numpad -) zoom out, and `Ctrl+0`
  /// resets to fit-width.
  Widget _wrapZoomShortcuts(Widget content) {
    if (_isMacOS) return content;
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        // Zoom in: Ctrl+= (unshifted), Ctrl++ (shifted), and numpad +.
        SingleActivator(LogicalKeyboardKey.equal, control: true):
            _ZoomInIntent(),
        SingleActivator(LogicalKeyboardKey.add, control: true):
            _ZoomInIntent(),
        SingleActivator(LogicalKeyboardKey.numpadAdd, control: true):
            _ZoomInIntent(),
        // Zoom out: Ctrl+- and numpad -.
        SingleActivator(LogicalKeyboardKey.minus, control: true):
            _ZoomOutIntent(),
        SingleActivator(LogicalKeyboardKey.numpadSubtract, control: true):
            _ZoomOutIntent(),
        // Reset to fit-width: Ctrl+0 and numpad 0.
        SingleActivator(LogicalKeyboardKey.digit0, control: true):
            _ZoomResetIntent(),
        SingleActivator(LogicalKeyboardKey.numpad0, control: true):
            _ZoomResetIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _ZoomInIntent: CallbackAction<_ZoomInIntent>(
            onInvoke: (_) {
              zoomRegistry.zoomIn();
              return null;
            },
          ),
          _ZoomOutIntent: CallbackAction<_ZoomOutIntent>(
            onInvoke: (_) {
              zoomRegistry.zoomOut();
              return null;
            },
          ),
          _ZoomResetIntent: CallbackAction<_ZoomResetIntent>(
            onInvoke: (_) {
              zoomRegistry.reset();
              return null;
            },
          ),
        },
        child: content,
      ),
    );
  }

  /// The application menu. On macOS this is the first menu and carries About,
  /// Services, Hide, and Quit. On other platforms it's a simple "Qpic" menu
  /// with Quit.
  PlatformMenu _buildAppMenu() {
    return PlatformMenu(
      label: 'Qpic',
      menus: <PlatformMenuItem>[
        if (_isMacOS &&
            PlatformProvidedMenuItem.hasMenu(
                PlatformProvidedMenuItemType.about))
          const PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.about,
          ),
        if (_isMacOS &&
            PlatformProvidedMenuItem.hasMenu(
                PlatformProvidedMenuItemType.servicesSubmenu))
          const PlatformMenuItemGroup(members: <PlatformMenuItem>[
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.servicesSubmenu,
            ),
          ]),
        if (_isMacOS &&
            PlatformProvidedMenuItem.hasMenu(
                PlatformProvidedMenuItemType.hide))
          const PlatformMenuItemGroup(members: <PlatformMenuItem>[
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.hide,
            ),
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.hideOtherApplications,
            ),
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.showAllApplications,
            ),
          ]),
        if (PlatformProvidedMenuItem.hasMenu(
            PlatformProvidedMenuItemType.quit))
          const PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.quit,
          )
        else
          PlatformMenuItem(
            label: 'Quit',
            shortcut: SingleActivator(
              LogicalKeyboardKey.keyQ,
              meta: _isMacOS,
              control: !_isMacOS,
            ),
            onSelected: () => SystemNavigator.pop(),
          ),
      ],
    );
  }

  /// Edit menu — standard text-editing actions that reach focused text fields
  /// (Requirement 19.3).
  ///
  /// Each item carries the standard shortcut (Cmd+X/C/V/A on macOS,
  /// Ctrl+X/C/V/A on Windows). The menu items invoke the corresponding
  /// editing actions through the primary focus's Actions system, which Flutter
  /// text fields already handle.
  PlatformMenu _buildEditMenu() {
    return PlatformMenu(
      label: 'Edit',
      menus: <PlatformMenuItem>[
        PlatformMenuItem(
          label: 'Cut',
          shortcut: SingleActivator(
            LogicalKeyboardKey.keyX,
            meta: _isMacOS,
            control: !_isMacOS,
          ),
          onSelected: () {
            _invokeEditAction(const CopySelectionTextIntent.cut(SelectionChangedCause.keyboard));
          },
        ),
        PlatformMenuItem(
          label: 'Copy',
          shortcut: SingleActivator(
            LogicalKeyboardKey.keyC,
            meta: _isMacOS,
            control: !_isMacOS,
          ),
          onSelected: () {
            _invokeEditAction(CopySelectionTextIntent.copy);
          },
        ),
        PlatformMenuItem(
          label: 'Paste',
          shortcut: SingleActivator(
            LogicalKeyboardKey.keyV,
            meta: _isMacOS,
            control: !_isMacOS,
          ),
          onSelected: () {
            _invokeEditAction(const PasteTextIntent(SelectionChangedCause.keyboard));
          },
        ),
        PlatformMenuItem(
          label: 'Select All',
          shortcut: SingleActivator(
            LogicalKeyboardKey.keyA,
            meta: _isMacOS,
            control: !_isMacOS,
          ),
          onSelected: () {
            _invokeEditAction(const SelectAllTextIntent(SelectionChangedCause.keyboard));
          },
        ),
      ],
    );
  }

  /// Dispatches an editing intent to the primary focus's Actions system.
  ///
  /// This is how Flutter text fields receive edit commands from the menu bar:
  /// the focused text field registers action handlers for the standard text
  /// editing intents, and we invoke them through the primary focus context.
  void _invokeEditAction(Intent intent) {
    final FocusNode? primaryFocus = FocusManager.instance.primaryFocus;
    if (primaryFocus == null) return;
    final BuildContext? context = primaryFocus.context;
    if (context == null) return;
    Actions.maybeInvoke(context, intent);
  }

  /// View menu — zoom shortcuts driving the active document view's zoom
  /// (Requirement 19.4). Mirrors `desktop_qt.py`'s Ctrl/Cmd +/-/0 shortcuts.
  PlatformMenu _buildViewMenu() {
    return PlatformMenu(
      label: 'View',
      menus: <PlatformMenuItem>[
        PlatformMenuItem(
          label: 'Zoom In',
          shortcut: SingleActivator(
            LogicalKeyboardKey.equal,
            meta: _isMacOS,
            control: !_isMacOS,
          ),
          onSelected: () => zoomRegistry.zoomIn(),
        ),
        PlatformMenuItem(
          label: 'Zoom Out',
          shortcut: SingleActivator(
            LogicalKeyboardKey.minus,
            meta: _isMacOS,
            control: !_isMacOS,
          ),
          onSelected: () => zoomRegistry.zoomOut(),
        ),
        PlatformMenuItem(
          label: 'Actual Size',
          shortcut: SingleActivator(
            LogicalKeyboardKey.digit0,
            meta: _isMacOS,
            control: !_isMacOS,
          ),
          onSelected: () => zoomRegistry.reset(),
        ),
      ],
    );
  }

  /// Help menu — opens the in-app walkthrough (Requirement 19.1).
  ///
  /// When a [navigatorKey] is available (widget sits above `MaterialApp`), the
  /// dialog is opened through the navigator's overlay context. Otherwise falls
  /// back to the widget's own [context] (for legacy placement or tests).
  PlatformMenu _buildHelpMenu(BuildContext context) {
    return PlatformMenu(
      label: 'Help',
      menus: <PlatformMenuItem>[
        PlatformMenuItem(
          label: 'How to Use Qpic',
          onSelected: () {
            final navContext = navigatorKey?.currentContext;
            HelpScreen.open(navContext ?? context);
          },
        ),
      ],
    );
  }
}

/// Intent fired by the Ctrl + / Ctrl numpad-+ zoom-in shortcut on the
/// non-macOS (Windows/Linux) shortcut layer.
class _ZoomInIntent extends Intent {
  const _ZoomInIntent();
}

/// Intent fired by the Ctrl - / Ctrl numpad-- zoom-out shortcut on the
/// non-macOS (Windows/Linux) shortcut layer.
class _ZoomOutIntent extends Intent {
  const _ZoomOutIntent();
}

/// Intent fired by the Ctrl 0 reset-to-fit-width shortcut on the non-macOS
/// (Windows/Linux) shortcut layer.
class _ZoomResetIntent extends Intent {
  const _ZoomResetIntent();
}

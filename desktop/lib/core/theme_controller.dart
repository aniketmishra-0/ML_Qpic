import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Qpic theme support (Requirement 4.5–4.9).
///
/// This file owns three concerns:
///
///  * [QpicPalette] — a [ThemeExtension] that reproduces the web UI's CSS
///    custom properties (`static/index.html` `:root` blocks) as typed Dart
///    colors. The Review Canvas, note chips, and shell read these so the
///    native app's detection-box outlines and note styling match the web.
///  * [ThemeController] — a [ChangeNotifier] holding the selected [ThemeMode]
///    (light / dark / system), persisted via `shared_preferences`. It defaults
///    to [ThemeMode.system] on first launch and re-applies a stored value on
///    later launches (4.8, 4.9).
///  * [QpicTheme] — builders for the light and dark [ThemeData] that carry the
///    [QpicPalette] extension.
///
/// System mode is honored by `MaterialApp(themeMode: ThemeMode.system)`, which
/// follows `MediaQuery.platformBrightness` and rebuilds live when the OS
/// light/dark preference changes while the app is running (4.6, 4.7). This
/// controller therefore only needs to expose the selected [ThemeMode]; it does
/// not poll or listen for OS brightness changes itself.

/// Theme-extension carrying the Qpic palette derived from the web UI's CSS
/// variables. Reproduces the brand duo-tone plus the success / warning /
/// danger accents used by detection-box outlines and review-note chips.
///
/// Access it from a widget with:
/// `Theme.of(context).extension<QpicPalette>()!`.
@immutable
class QpicPalette extends ThemeExtension<QpicPalette> {
  const QpicPalette({
    required this.brand,
    required this.brandMagenta,
    required this.brandBlue,
    required this.success,
    required this.warn,
    required this.danger,
    required this.background,
    required this.backgroundAlt,
    required this.panel,
    required this.panelAlt,
    required this.field,
    required this.border,
    required this.borderSoft,
    required this.text,
    required this.muted,
    required this.mutedAlt,
    required this.appBar,
    required this.appBarText,
  });

  // ---- Brand identity (theme-independent in the web `:root`) -------------
  // --accent / --accent-2 / --accent-3 — the "Electric Iris" violet→magenta→
  // blue duo-tone. Identical in light and dark.

  /// `--accent` (#7c6cff). Primary brand color and the canvas "editing" box.
  final Color brand;

  /// `--accent-2` (#b14eff). Magenta end of the brand gradient.
  final Color brandMagenta;

  /// `--accent-3` (#4b8dff). Blue end of the brand gradient.
  final Color brandBlue;

  // ---- Status accents (used by box outlines + note chips) ----------------

  /// `--success`. Detection-box dashed outline + box tag fill.
  final Color success;

  /// `--warn`. Flagged-box outline/tag and default note-chip accent
  /// (`duplicate`, `tiny`, `low_confidence`).
  final Color warn;

  /// `--danger`. `incomplete` note-chip accent and "Items to Fix" header.
  final Color danger;

  // ---- Surfaces / text ---------------------------------------------------

  /// `--bg`.
  final Color background;

  /// `--bg-2`.
  final Color backgroundAlt;

  /// `--panel`.
  final Color panel;

  /// `--panel-2`. Base for note-chip backgrounds.
  final Color panelAlt;

  /// `--field`.
  final Color field;

  /// `--border`.
  final Color border;

  /// `--border-soft`.
  final Color borderSoft;

  /// `--text`.
  final Color text;

  /// `--muted`.
  final Color muted;

  /// `--muted-2`.
  final Color mutedAlt;

  /// `--appbar`.
  final Color appBar;

  /// `--appbar-text`.
  final Color appBarText;

  // ---- Derived canvas/note colors ----------------------------------------
  // These mirror the web CSS rules so downstream tasks (Review Canvas 8.x,
  // Review Notes 10.5) can read a single source of truth.

  /// `.existing-box` dashed outline — `var(--success)`.
  Color get boxOutline => success;

  /// `.existing-box.flagged` outline — `var(--warn)`.
  Color get boxFlagged => warn;

  /// `.existing-box.editing` outline — `var(--accent)`.
  Color get boxEditing => brand;

  /// `.sel-box` fill while drawing — `color-mix(in srgb, var(--accent) 16%,
  /// transparent)`, i.e. the brand color at 16% opacity over the page.
  Color get selectionFill => brand.withValues(alpha: 0.16);

  /// `.note.gap` accent dot/border — `var(--accent)`.
  Color get noteGap => brand;

  /// `.note.incomplete` accent dot/border — `var(--danger)`.
  Color get noteIncomplete => danger;

  /// Default `.note` accent (`duplicate`, `tiny`, `low_confidence`) —
  /// `var(--warn)`.
  Color get noteDefault => warn;

  @override
  QpicPalette copyWith({
    Color? brand,
    Color? brandMagenta,
    Color? brandBlue,
    Color? success,
    Color? warn,
    Color? danger,
    Color? background,
    Color? backgroundAlt,
    Color? panel,
    Color? panelAlt,
    Color? field,
    Color? border,
    Color? borderSoft,
    Color? text,
    Color? muted,
    Color? mutedAlt,
    Color? appBar,
    Color? appBarText,
  }) {
    return QpicPalette(
      brand: brand ?? this.brand,
      brandMagenta: brandMagenta ?? this.brandMagenta,
      brandBlue: brandBlue ?? this.brandBlue,
      success: success ?? this.success,
      warn: warn ?? this.warn,
      danger: danger ?? this.danger,
      background: background ?? this.background,
      backgroundAlt: backgroundAlt ?? this.backgroundAlt,
      panel: panel ?? this.panel,
      panelAlt: panelAlt ?? this.panelAlt,
      field: field ?? this.field,
      border: border ?? this.border,
      borderSoft: borderSoft ?? this.borderSoft,
      text: text ?? this.text,
      muted: muted ?? this.muted,
      mutedAlt: mutedAlt ?? this.mutedAlt,
      appBar: appBar ?? this.appBar,
      appBarText: appBarText ?? this.appBarText,
    );
  }

  @override
  QpicPalette lerp(ThemeExtension<QpicPalette>? other, double t) {
    if (other is! QpicPalette) return this;
    return QpicPalette(
      brand: Color.lerp(brand, other.brand, t)!,
      brandMagenta: Color.lerp(brandMagenta, other.brandMagenta, t)!,
      brandBlue: Color.lerp(brandBlue, other.brandBlue, t)!,
      success: Color.lerp(success, other.success, t)!,
      warn: Color.lerp(warn, other.warn, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      background: Color.lerp(background, other.background, t)!,
      backgroundAlt: Color.lerp(backgroundAlt, other.backgroundAlt, t)!,
      panel: Color.lerp(panel, other.panel, t)!,
      panelAlt: Color.lerp(panelAlt, other.panelAlt, t)!,
      field: Color.lerp(field, other.field, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderSoft: Color.lerp(borderSoft, other.borderSoft, t)!,
      text: Color.lerp(text, other.text, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      mutedAlt: Color.lerp(mutedAlt, other.mutedAlt, t)!,
      appBar: Color.lerp(appBar, other.appBar, t)!,
      appBarText: Color.lerp(appBarText, other.appBarText, t)!,
    );
  }

  /// Dark palette — reproduces the web `:root` / `:root[data-theme="dark"]`
  /// block (the web UI's default).
  static const QpicPalette dark = QpicPalette(
    brand: Color(0xFF7C6CFF), // --accent
    brandMagenta: Color(0xFFB14EFF), // --accent-2
    brandBlue: Color(0xFF4B8DFF), // --accent-3
    success: Color(0xFF2DD4BF), // --success
    warn: Color(0xFFFBBF24), // --warn
    danger: Color(0xFFFB7185), // --danger
    background: Color(0xFF111113), // --bg  (true near-black)
    backgroundAlt: Color(0xFF161618), // --bg-2
    panel: Color(0xFF1C1C1E), // --panel
    panelAlt: Color(0xFF1A1A1C), // --panel-2
    field: Color(0xFF232325), // --field
    border: Color(0xFF2C2C2E), // --border (subtle dark gray)
    borderSoft: Color(0xFF252527), // --border-soft
    text: Color(0xFFF5F5F7), // --text (clean white)
    muted: Color(0xFF98989D), // --muted (neutral gray)
    mutedAlt: Color(0xFF636366), // --muted-2
    appBar: Color(0xFF161618), // --appbar
    appBarText: Color(0xFFF5F5F7), // --appbar-text
  );

  /// Light palette — reproduces the web `:root[data-theme="light"]` block
  /// (and the matching `prefers-color-scheme: light` system block).
  static const QpicPalette light = QpicPalette(
    brand: Color(0xFF7C6CFF), // --accent
    brandMagenta: Color(0xFFB14EFF), // --accent-2
    brandBlue: Color(0xFF4B8DFF), // --accent-3
    success: Color(0xFF0D9488), // --success
    warn: Color(0xFFD97706), // --warn
    danger: Color(0xFFE11D48), // --danger
    background: Color(0xFFF5F5F7), // --bg (neutral gray-white)
    backgroundAlt: Color(0xFFEFEFEF), // --bg-2
    panel: Color(0xFFFFFFFF), // --panel
    panelAlt: Color(0xFFFAFAFA), // --panel-2
    field: Color(0xFFF0F0F2), // --field
    border: Color(0xFFD1D1D6), // --border (neutral gray)
    borderSoft: Color(0xFFE5E5EA), // --border-soft
    text: Color(0xFF1C1C1E), // --text (near-black)
    muted: Color(0xFF6E6E73), // --muted
    mutedAlt: Color(0xFF8E8E93), // --muted-2
    appBar: Color(0xFFFFFFFF), // --appbar
    appBarText: Color(0xFF1C1C1E), // --appbar-text
  );
}

/// Builders for the light/dark [ThemeData] used by `MaterialApp`.
///
/// Each theme carries a [QpicPalette] extension so widgets can read the exact
/// web CSS colors while still benefiting from a Material 3 [ColorScheme].
class QpicTheme {
  const QpicTheme._();

  /// Light theme reproducing the web light palette.
  static ThemeData get light => _build(Brightness.light, QpicPalette.light);

  /// Dark theme reproducing the web dark palette.
  static ThemeData get dark => _build(Brightness.dark, QpicPalette.dark);

  static ThemeData _build(Brightness brightness, QpicPalette palette) {
    final scheme = ColorScheme.fromSeed(
      seedColor: palette.brand,
      brightness: brightness,
    ).copyWith(
      primary: palette.brand,
      secondary: palette.brandBlue,
      tertiary: palette.brandMagenta,
      error: palette.danger,
      surface: palette.panel,
      onSurface: palette.text,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: palette.background,
      canvasColor: palette.field, // Used by DropdownButton popups
      dividerColor: palette.border,
      appBarTheme: AppBarTheme(
        backgroundColor: palette.appBar,
        foregroundColor: palette.appBarText,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      // Input fields — nearly invisible until focused.
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.field,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: palette.borderSoft, width: 1.0),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: palette.borderSoft.withValues(alpha: 0.5), width: 1.0),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: palette.brand, width: 1.5),
        ),
        labelStyle: TextStyle(color: palette.muted, fontSize: 13),
        hintStyle: TextStyle(color: palette.mutedAlt, fontSize: 13),
        helperStyle: TextStyle(color: palette.mutedAlt, fontSize: 11),
      ),
      // Refined slider theme — brand-colored, compact.
      sliderTheme: SliderThemeData(
        activeTrackColor: palette.brand,
        inactiveTrackColor: palette.border,
        thumbColor: palette.brand,
        overlayColor: palette.brand.withValues(alpha: 0.12),
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
      ),
      // Refined switch theme.
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return palette.brand;
          return palette.muted;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return palette.brand.withValues(alpha: 0.35);
          }
          return palette.border;
        }),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
      // Filled button — clean solid brand.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: palette.brand,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: const TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      // Outlined button style.
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: palette.brand,
          side: BorderSide(color: palette.brand.withValues(alpha: 0.5)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      // Dropdown menu style.
      dropdownMenuTheme: DropdownMenuThemeData(
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: palette.field,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: palette.border, width: 1.0),
          ),
        ),
      ),
      // Segmented button — clean, subtle.
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return palette.brand.withValues(alpha: 0.12);
            }
            return Colors.transparent;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return palette.brand;
            return palette.muted;
          }),
          side: WidgetStateProperty.all(
            BorderSide(color: palette.borderSoft.withValues(alpha: 0.5)),
          ),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          textStyle: WidgetStateProperty.all(
            const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
          ),
        ),
      ),
      // Card theme — borderless, flat, modern.
      cardTheme: CardThemeData(
        color: palette.panel,
        elevation: 0,
        shadowColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide.none,
        ),
      ),
      // Tooltip.
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: palette.panelAlt,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: palette.border),
        ),
        textStyle: TextStyle(color: palette.text, fontSize: 12),
      ),
      // ScrollbarTheme — subtle, app-like.
      scrollbarTheme: ScrollbarThemeData(
        radius: const Radius.circular(4),
        thickness: WidgetStateProperty.all(6),
        thumbColor: WidgetStateProperty.all(palette.border),
      ),
      // Popup menu — matches the app's dark/light surface.
      popupMenuTheme: PopupMenuThemeData(
        color: palette.field,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: palette.borderSoft,
          ),
        ),
        elevation: 8,
        shadowColor: Colors.black.withValues(alpha: 0.35),
        textStyle: TextStyle(
          color: palette.text,
          fontSize: 13,
        ),
      ),
      extensions: <ThemeExtension<dynamic>>[palette],
    );
  }
}

/// Holds and persists the user's [ThemeMode] selection (Requirement 4.5–4.9).
///
/// * [load] reads the stored value, defaulting to [ThemeMode.system] when none
///   exists (first launch, 4.9) or when the stored value is unrecognized.
/// * [setThemeMode] applies and persists a new selection (4.8) and notifies
///   listeners so `MaterialApp` re-themes without a restart (4.6).
///
/// System mode tracking is delegated to `MaterialApp(themeMode: system)`, which
/// follows `MediaQuery.platformBrightness` live (4.7); this controller does not
/// need to observe OS brightness itself.
class ThemeController extends ChangeNotifier {
  ThemeController({SharedPreferences? preferences})
      : _preferences = preferences;

  /// `shared_preferences` key under which the selected mode is stored.
  static const String storageKey = 'qpic.theme_mode';
  static const String dpiKey = 'qpic.default_dpi';
  static const String paddingKey = 'qpic.default_padding';
  static const String questionPrefixKey = 'qpic.default_q_prefix';
  static const String solutionPrefixKey = 'qpic.default_s_prefix';
  static const String imageFormatKey = 'qpic.default_image_format';
  static const String smartModeKey = 'qpic.default_smart_mode';

  /// Optional injected store (used by tests). When null, the controller
  /// resolves the shared singleton lazily inside [load]/[setThemeMode].
  SharedPreferences? _preferences;

  ThemeMode _themeMode = ThemeMode.system;

  int _defaultDpi = 200;
  int _defaultPadding = 20;
  String _defaultQuestionPrefix = 'Q';
  String _defaultSolutionPrefix = 'S';
  String _defaultImageFormat = 'png';
  bool _defaultSmartMode = true;

  /// The currently selected theme mode. Defaults to [ThemeMode.system] until
  /// [load] completes.
  ThemeMode get themeMode => _themeMode;

  int get defaultDpi => _defaultDpi;
  int get defaultPadding => _defaultPadding;
  String get defaultQuestionPrefix => _defaultQuestionPrefix;
  String get defaultSolutionPrefix => _defaultSolutionPrefix;
  String get defaultImageFormat => _defaultImageFormat;
  bool get defaultSmartMode => _defaultSmartMode;

  /// Reads the persisted selection. Defaults to [ThemeMode.system] when there
  /// is no stored value (first launch) or the stored value is unrecognized,
  /// then re-applies any valid stored value (Requirement 4.9).
  Future<void> load() async {
    final prefs = await _prefs();
    final stored = prefs.getString(storageKey);
    final resolved = _decode(stored) ?? ThemeMode.system;

    final storedDpi = prefs.getInt(dpiKey);
    final storedPadding = prefs.getInt(paddingKey);
    final storedQPrefix = prefs.getString(questionPrefixKey);
    final storedSPrefix = prefs.getString(solutionPrefixKey);
    final storedFormat = prefs.getString(imageFormatKey);
    final storedSmartMode = prefs.getBool(smartModeKey);

    bool changed = false;
    if (resolved != _themeMode) {
      _themeMode = resolved;
      changed = true;
    }
    if (storedDpi != null && storedDpi != _defaultDpi) {
      _defaultDpi = storedDpi;
      changed = true;
    }
    if (storedPadding != null && storedPadding != _defaultPadding) {
      _defaultPadding = storedPadding;
      changed = true;
    }
    if (storedQPrefix != null && storedQPrefix != _defaultQuestionPrefix) {
      _defaultQuestionPrefix = storedQPrefix;
      changed = true;
    }
    if (storedSPrefix != null && storedSPrefix != _defaultSolutionPrefix) {
      _defaultSolutionPrefix = storedSPrefix;
      changed = true;
    }
    if (storedFormat != null && storedFormat != _defaultImageFormat) {
      _defaultImageFormat = storedFormat;
      changed = true;
    }
    if (storedSmartMode != null && storedSmartMode != _defaultSmartMode) {
      _defaultSmartMode = storedSmartMode;
      changed = true;
    }

    if (changed) {
      notifyListeners();
    }
  }

  /// Applies [mode], notifies listeners, and persists the choice so it is
  /// retained across restarts (Requirements 4.6, 4.8).
  Future<void> setThemeMode(ThemeMode mode) async {
    if (mode != _themeMode) {
      _themeMode = mode;
      notifyListeners();
    }
    final prefs = await _prefs();
    await prefs.setString(storageKey, _encode(mode));
  }

  Future<void> setDefaultDpi(int value) async {
    if (_defaultDpi != value) {
      _defaultDpi = value;
      notifyListeners();
    }
    final prefs = await _prefs();
    await prefs.setInt(dpiKey, value);
  }

  Future<void> setDefaultPadding(int value) async {
    if (_defaultPadding != value) {
      _defaultPadding = value;
      notifyListeners();
    }
    final prefs = await _prefs();
    await prefs.setInt(paddingKey, value);
  }

  Future<void> setDefaultQuestionPrefix(String value) async {
    if (_defaultQuestionPrefix != value) {
      _defaultQuestionPrefix = value;
      notifyListeners();
    }
    final prefs = await _prefs();
    await prefs.setString(questionPrefixKey, value);
  }

  Future<void> setDefaultSolutionPrefix(String value) async {
    if (_defaultSolutionPrefix != value) {
      _defaultSolutionPrefix = value;
      notifyListeners();
    }
    final prefs = await _prefs();
    await prefs.setString(solutionPrefixKey, value);
  }

  Future<void> setDefaultImageFormat(String value) async {
    if (_defaultImageFormat != value) {
      _defaultImageFormat = value;
      notifyListeners();
    }
    final prefs = await _prefs();
    await prefs.setString(imageFormatKey, value);
  }

  Future<void> setDefaultSmartMode(bool value) async {
    if (_defaultSmartMode != value) {
      _defaultSmartMode = value;
      notifyListeners();
    }
    final prefs = await _prefs();
    await prefs.setBool(smartModeKey, value);
  }

  Future<void> resetToDefaults() async {
    _themeMode = ThemeMode.system;
    _defaultDpi = 200;
    _defaultPadding = 20;
    _defaultQuestionPrefix = 'Q';
    _defaultSolutionPrefix = 'S';
    _defaultImageFormat = 'png';
    _defaultSmartMode = true;
    notifyListeners();

    final prefs = await _prefs();
    await prefs.remove(storageKey);
    await prefs.remove(dpiKey);
    await prefs.remove(paddingKey);
    await prefs.remove(questionPrefixKey);
    await prefs.remove(solutionPrefixKey);
    await prefs.remove(imageFormatKey);
    await prefs.remove(smartModeKey);
  }

  Future<SharedPreferences> _prefs() async {
    return _preferences ??= await SharedPreferences.getInstance();
  }

  /// Serializes a [ThemeMode] to a stable string token.
  static String _encode(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
        return 'system';
    }
  }

  /// Parses a stored token back into a [ThemeMode], or null when the value is
  /// absent or unrecognized (caller falls back to [ThemeMode.system]).
  static ThemeMode? _decode(String? value) {
    switch (value) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      case 'system':
        return ThemeMode.system;
      default:
        return null;
    }
  }
}

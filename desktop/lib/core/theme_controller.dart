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
    background: Color(0xFF0C0B15), // --bg
    backgroundAlt: Color(0xFF14121F), // --bg-2
    panel: Color(0xFF181626), // --panel
    panelAlt: Color(0xFF131120), // --panel-2
    field: Color(0xFF211E33), // --field
    border: Color(0xFF2F2B46), // --border
    borderSoft: Color(0xFF262339), // --border-soft
    text: Color(0xFFF4F3FB), // --text
    muted: Color(0xFFB5B1CC), // --muted
    mutedAlt: Color(0xFF7D789A), // --muted-2
    appBar: Color(0xFF14121F), // --appbar
    appBarText: Color(0xFFF4F3FB), // --appbar-text
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
    background: Color(0xFFF4F3FB), // --bg
    backgroundAlt: Color(0xFFECEAF8), // --bg-2
    panel: Color(0xFFFFFFFF), // --panel
    panelAlt: Color(0xFFF7F6FD), // --panel-2
    field: Color(0xFFF1EFFB), // --field
    border: Color(0xFFE0DCF0), // --border
    borderSoft: Color(0xFFEBE8F7), // --border-soft
    text: Color(0xFF1B1830), // --text
    muted: Color(0xFF58536F), // --muted
    mutedAlt: Color(0xFF8B86A3), // --muted-2
    appBar: Color(0xFFFFFFFF), // --appbar
    appBarText: Color(0xFF1B1830), // --appbar-text
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
      canvasColor: palette.panel,
      dividerColor: palette.border,
      appBarTheme: AppBarTheme(
        backgroundColor: palette.appBar,
        foregroundColor: palette.appBarText,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      // Refined input decoration for text fields — tighter, more polished.
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.field,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: palette.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: palette.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
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
      // Refined filled button style — brand gradient feel.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: palette.brand,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(9),
          ),
          textStyle: const TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
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
            borderRadius: BorderRadius.circular(9),
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
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: palette.border),
          ),
        ),
      ),
      // Segmented button refinements.
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return palette.brand.withValues(alpha: 0.15);
            }
            return palette.field;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return palette.brand;
            return palette.muted;
          }),
          side: WidgetStateProperty.all(
            BorderSide(color: palette.border),
          ),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          textStyle: WidgetStateProperty.all(
            const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
          ),
        ),
      ),
      // Card theme.
      cardTheme: CardThemeData(
        color: palette.panel,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: palette.border),
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
  ThemeController({SharedPreferences? preferences}) : _preferences = preferences;

  /// `shared_preferences` key under which the selected mode is stored.
  static const String storageKey = 'qpic.theme_mode';

  /// Optional injected store (used by tests). When null, the controller
  /// resolves the shared singleton lazily inside [load]/[setThemeMode].
  SharedPreferences? _preferences;

  ThemeMode _themeMode = ThemeMode.system;

  /// The currently selected theme mode. Defaults to [ThemeMode.system] until
  /// [load] completes.
  ThemeMode get themeMode => _themeMode;

  /// Reads the persisted selection. Defaults to [ThemeMode.system] when there
  /// is no stored value (first launch) or the stored value is unrecognized,
  /// then re-applies any valid stored value (Requirement 4.9).
  Future<void> load() async {
    final prefs = await _prefs();
    final stored = prefs.getString(storageKey);
    final resolved = _decode(stored) ?? ThemeMode.system;
    if (resolved != _themeMode) {
      _themeMode = resolved;
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

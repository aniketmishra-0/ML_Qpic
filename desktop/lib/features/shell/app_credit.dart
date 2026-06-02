import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme_controller.dart';

/// Compact portrait-style "Aniket Mishra" credit pinned in the left navigation
/// rail.
///
/// Shows the author's initials in a gradient avatar above the full name
/// "Aniket Mishra". The entire box is clickable and opens the author's LinkedIn
/// profile in the user's default browser.
///
/// Styled to match the nav-rail item aesthetic with hover effects and
/// micro-animations.
class AppCredit extends StatefulWidget {
  const AppCredit({super.key, required this.palette});

  /// The author's LinkedIn profile (same link used by the web credit footer).
  static final Uri linkedInUrl =
      Uri.parse('https://www.linkedin.com/in/aniketmishra0/');

  final QpicPalette? palette;

  @override
  State<AppCredit> createState() => _AppCreditState();
}

class _AppCreditState extends State<AppCredit>
    with SingleTickerProviderStateMixin {
  bool _hovered = false;

  late final AnimationController _glowController;
  late final Animation<double> _glowAnimation;

  @override
  void initState() {
    super.initState();
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _glowAnimation = CurvedAnimation(
      parent: _glowController,
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    _glowController.dispose();
    super.dispose();
  }

  Future<void> _openLinkedIn() async {
    await launchUrl(
      AppCredit.linkedInUrl,
      mode: LaunchMode.externalApplication,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = widget.palette;
    final brand = palette?.brand ?? theme.colorScheme.primary;
    final brandMagenta = palette?.brandMagenta ?? theme.colorScheme.tertiary;
    final brandBlue = palette?.brandBlue ?? theme.colorScheme.secondary;
    final muted = palette?.muted ?? theme.colorScheme.onSurfaceVariant;
    final fieldColor =
        palette?.field ?? theme.colorScheme.surfaceContainerHighest;
    final appBarText = palette?.appBarText ?? theme.colorScheme.onSurface;

    return Tooltip(
      message: 'Aniket Mishra — open LinkedIn',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          key: const ValueKey<String>('shell-credit'),
          onTap: _openLinkedIn,
          child: AnimatedBuilder(
            animation: _glowAnimation,
            builder: (context, child) {
              final glowOpacity = _hovered ? 0.0 : _glowAnimation.value * 0.15;

              return AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                width: 60,
                padding:
                    const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                decoration: BoxDecoration(
                  color: _hovered
                      ? fieldColor
                      : brand.withValues(alpha: glowOpacity),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _hovered
                        ? brand.withValues(alpha: 0.5)
                        : Colors.transparent,
                  ),
                ),
                child: child,
              );
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                // Portrait avatar with initials.
                Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: <Color>[brand, brandMagenta, brandBlue],
                      stops: const [0.0, 0.5, 1.0],
                    ),
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: brand.withValues(alpha: _hovered ? 0.45 : 0.2),
                        blurRadius: _hovered ? 12 : 6,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: const Text(
                    'AM',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      letterSpacing: 0.5,
                      height: 1,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                // Full name — "Aniket" on first line, "Mishra" on second.
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 200),
                  style: TextStyle(
                    fontSize: 9.5,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                    color: _hovered ? brand : appBarText,
                    letterSpacing: 0.1,
                  ),
                  child: const Text(
                    'Aniket\nMishra',
                    textAlign: TextAlign.center,
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

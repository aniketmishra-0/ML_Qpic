import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme_controller.dart';

/// Vertical "root@aniketmishra:~# ./launch-qpic" credit in the left nav rail.
///
/// The full terminal-style prompt is written vertically (rotated, reading
/// bottom-to-top). Only "aniketmishra" within the text is clickable and opens
/// the author's LinkedIn profile.
class AppCredit extends StatefulWidget {
  const AppCredit({super.key, required this.palette});

  /// The author's LinkedIn profile.
  static final Uri linkedInUrl =
      Uri.parse('https://www.linkedin.com/in/aniketmishra0/');

  final QpicPalette? palette;

  @override
  State<AppCredit> createState() => _AppCreditState();
}

class _AppCreditState extends State<AppCredit> {
  bool _nameHovered = false;
  late final TapGestureRecognizer _tapRecognizer;

  @override
  void initState() {
    super.initState();
    _tapRecognizer = TapGestureRecognizer()..onTap = _openLinkedIn;
  }

  @override
  void dispose() {
    _tapRecognizer.dispose();
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
    final muted = palette?.muted ?? theme.colorScheme.onSurfaceVariant;

    final baseStyle = TextStyle(
      fontSize: 13.5,
      fontWeight: FontWeight.w500,
      color: muted,
      letterSpacing: 0.2,
    );

    return Padding(
      key: const ValueKey<String>('shell-credit'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: RotatedBox(
        quarterTurns: 3,
        child: MouseRegion(
          onEnter: (_) => setState(() => _nameHovered = true),
          onExit: (_) => setState(() => _nameHovered = false),
          child: Text.rich(
            TextSpan(
              children: <TextSpan>[
                TextSpan(text: 'root@', style: baseStyle),
                TextSpan(
                  text: 'aniketmishra',
                  recognizer: _tapRecognizer,
                  style: baseStyle.copyWith(
                    fontWeight: FontWeight.w700,
                    color: _nameHovered ? brand : muted,
                    decoration: _nameHovered
                        ? TextDecoration.underline
                        : TextDecoration.none,
                    decorationColor: brand,
                  ),
                ),
                TextSpan(text: ':~# ./launch-qpic', style: baseStyle),
              ],
            ),
            maxLines: 1,
          ),
        ),
      ),
    );
  }
}

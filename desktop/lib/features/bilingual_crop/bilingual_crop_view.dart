import 'package:flutter/material.dart';

import '../../core/theme_controller.dart';
import '../auto_crop/auto_crop_controller.dart';
import '../auto_crop/auto_crop_view.dart';
import '../manual_crop/manual_crop_controller.dart';
import '../manual_crop/manual_crop_view.dart';

/// A view that hosts both Auto and Manual bilingual cropping workflows,
/// switching between them via a segmented button.
class BilingualCropView extends StatefulWidget {
  const BilingualCropView({
    super.key,
    required this.autoController,
    required this.manualController,
    this.onPickAutoFile,
    this.onSubmitAuto,
    this.onClearAuto,
    this.onViewAuto,
    this.onPickManualFile,
    this.onClearManual,
    this.previewUrlResolver,
  });

  final AutoCropController autoController;
  final ManualCropController manualController;
  final VoidCallback? onPickAutoFile;
  final VoidCallback? onSubmitAuto;
  final VoidCallback? onClearAuto;
  final VoidCallback? onViewAuto;
  final VoidCallback? onPickManualFile;
  final VoidCallback? onClearManual;
  final String Function(String)? previewUrlResolver;

  @override
  State<BilingualCropView> createState() => _BilingualCropViewState();
}

class _BilingualCropViewState extends State<BilingualCropView> {
  int _activeTab = 0; // 0 for Auto, 1 for Manual

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Top sub-navigation bar for Bilingual mode sub-workflows
        Container(
          padding: const EdgeInsets.fromLTRB(28, 16, 28, 0),
          color: palette?.background ?? theme.colorScheme.surface,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              SegmentedButton<int>(
                key: const ValueKey<String>('bilingual-crop-mode-segmented'),
                selected: {_activeTab},
                onSelectionChanged: (set) {
                  setState(() {
                    _activeTab = set.first;
                  });
                },
                segments: const [
                  ButtonSegment<int>(
                    value: 0,
                    label: Text('Auto Bilingual'),
                    icon: Icon(Icons.auto_awesome_rounded),
                  ),
                  ButtonSegment<int>(
                    value: 1,
                    label: Text('Manual Bilingual'),
                    icon: Icon(Icons.edit_note_rounded),
                  ),
                ],
              ),
            ],
          ),
        ),
        // Active view content
        Expanded(
          child: IndexedStack(
            index: _activeTab,
            children: [
              AutoCropView(
                key: const ValueKey<String>('bilingual-auto-crop-tab'),
                controller: widget.autoController,
                onSubmit: widget.onSubmitAuto,
                onPickFile: widget.onPickAutoFile,
                onClear: widget.onClearAuto,
                onView: widget.onViewAuto,
                title: 'Bilingual Auto Crop',
              ),
              ManualCropView(
                key: const ValueKey<String>('bilingual-manual-crop-tab'),
                controller: widget.manualController,
                onPickFile: widget.onPickManualFile,
                onClear: widget.onClearManual,
                previewUrlResolver: widget.previewUrlResolver,
                title: 'Bilingual Manual Crop',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

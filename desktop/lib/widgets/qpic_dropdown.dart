import 'package:flutter/material.dart';
import '../core/theme_controller.dart'; // to get QpicPalette

class QpicDropdownItem<T> {
  const QpicDropdownItem({
    required this.value,
    required this.label,
    this.icon,
  });

  final T value;
  final String label;
  final IconData? icon;
}

class QpicDropdownField<T> extends StatefulWidget {
  const QpicDropdownField({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.prefixIcon,
    this.hint,
  });

  final T value;
  final List<QpicDropdownItem<T>> items;
  final ValueChanged<T> onChanged;
  final Widget? prefixIcon;
  final String? hint;

  @override
  State<QpicDropdownField<T>> createState() => _QpicDropdownFieldState<T>();
}

class _QpicDropdownFieldState<T> extends State<QpicDropdownField<T>> {
  final GlobalKey _anchorKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();
    
    final selectedItem = widget.items.firstWhere(
      (item) => item.value == widget.value,
      orElse: () => widget.items.first,
    );

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double? layoutWidth = constraints.maxWidth.isFinite ? constraints.maxWidth : null;

        return Container(
          key: _anchorKey,
          child: PopupMenuButton<T>(
            tooltip: '',
            offset: const Offset(0, 48), // Position popup below the field
            constraints: layoutWidth != null 
                ? BoxConstraints(minWidth: layoutWidth, maxWidth: layoutWidth)
                : null,
            onSelected: widget.onChanged,
            itemBuilder: (BuildContext context) {
              final renderBox = _anchorKey.currentContext?.findRenderObject() as RenderBox?;
              final width = renderBox?.size.width ?? layoutWidth;

              return widget.items.map((item) {
                final isSelected = item.value == widget.value;
                return PopupMenuItem<T>(
                  value: item.value,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: SizedBox(
                    width: width != null ? (width - 24) : null,
                    child: Row(
                      children: [
                        if (item.icon != null) ...[
                          Icon(
                            item.icon,
                            size: 16,
                            color: isSelected
                                ? (palette?.brand ?? theme.colorScheme.primary)
                                : (palette?.muted ?? theme.colorScheme.onSurfaceVariant),
                          ),
                          const SizedBox(width: 10),
                        ],
                        Expanded(
                          child: Text(
                            item.label,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                              color: isSelected
                                  ? (palette?.brand ?? theme.colorScheme.primary)
                                  : (palette?.text ?? theme.colorScheme.onSurface),
                            ),
                          ),
                        ),
                        if (isSelected)
                          Icon(
                            Icons.check_rounded,
                            size: 16,
                            color: palette?.brand ?? theme.colorScheme.primary,
                          ),
                      ],
                    ),
                  ),
                );
              }).toList();
            },
            child: InputDecorator(
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: widget.prefixIcon,
                suffixIcon: Icon(
                  Icons.keyboard_arrow_down_rounded,
                  color: palette?.muted,
                  size: 20,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              child: Text(
                selectedItem.label,
                style: TextStyle(
                  fontSize: 14,
                  color: palette?.text ?? theme.colorScheme.onSurface,
                ),
              ),
            ),
          ),
        );
      }
    );
  }
}

class QpicDropdownButton<T> extends StatefulWidget {
  const QpicDropdownButton({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.dense = false,
    this.isExpanded = false,
  });

  final T value;
  final List<QpicDropdownItem<T>> items;
  final ValueChanged<T> onChanged;
  final bool dense;
  final bool isExpanded;

  @override
  State<QpicDropdownButton<T>> createState() => _QpicDropdownButtonState<T>();
}

class _QpicDropdownButtonState<T> extends State<QpicDropdownButton<T>> {
  final GlobalKey _anchorKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<QpicPalette>();
    
    final selectedItem = widget.items.firstWhere(
      (item) => item.value == widget.value,
      orElse: () => widget.items.first,
    );

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double? layoutWidth = constraints.maxWidth.isFinite ? constraints.maxWidth : null;

        return Container(
          key: _anchorKey,
          child: PopupMenuButton<T>(
            tooltip: '',
            offset: const Offset(0, 36),
            constraints: layoutWidth != null 
                ? BoxConstraints(minWidth: layoutWidth, maxWidth: layoutWidth)
                : null,
            onSelected: widget.onChanged,
            itemBuilder: (BuildContext context) {
              final renderBox = _anchorKey.currentContext?.findRenderObject() as RenderBox?;
              final width = renderBox?.size.width ?? layoutWidth;

              return widget.items.map((item) {
                final isSelected = item.value == widget.value;
                return PopupMenuItem<T>(
                  value: item.value,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: SizedBox(
                    width: width != null ? (width - 24) : null,
                    child: Row(
                      children: [
                        if (item.icon != null) ...[
                          Icon(
                            item.icon,
                            size: 16,
                            color: isSelected
                                ? (palette?.brand ?? theme.colorScheme.primary)
                                : (palette?.muted ?? theme.colorScheme.onSurfaceVariant),
                          ),
                          const SizedBox(width: 10),
                        ],
                        Expanded(
                          child: Text(
                            item.label,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                              color: isSelected
                                  ? (palette?.brand ?? theme.colorScheme.primary)
                                  : (palette?.text ?? theme.colorScheme.onSurface),
                            ),
                          ),
                        ),
                        if (isSelected)
                          Icon(
                            Icons.check_rounded,
                            size: 16,
                            color: palette?.brand ?? theme.colorScheme.primary,
                          ),
                      ],
                    ),
                  ),
                );
              }).toList();
            },
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: widget.dense ? 8 : 12,
                vertical: widget.dense ? 6 : 8,
              ),
              decoration: BoxDecoration(
                color: palette?.field,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: palette?.borderSoft ?? theme.dividerColor,
                  width: 1.0,
                ),
              ),
              child: Row(
                mainAxisSize: widget.isExpanded ? MainAxisSize.max : MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (widget.isExpanded)
                    Expanded(
                      child: Text(
                        selectedItem.label,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: widget.dense ? 12 : 13,
                          fontWeight: FontWeight.w500,
                          color: palette?.text ?? theme.colorScheme.onSurface,
                        ),
                      ),
                    )
                  else
                    Text(
                      selectedItem.label,
                      style: TextStyle(
                        fontSize: widget.dense ? 12 : 13,
                        fontWeight: FontWeight.w500,
                        color: palette?.text ?? theme.colorScheme.onSurface,
                      ),
                    ),
                  const SizedBox(width: 6),
                  Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: widget.dense ? 16 : 18,
                    color: palette?.muted,
                  ),
                ],
              ),
            ),
          ),
        );
      }
    );
  }
}

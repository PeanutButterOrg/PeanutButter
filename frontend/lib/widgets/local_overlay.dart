import 'package:flutter/material.dart';

/// Overlay that stays inside this box so hover cards cannot paint over the
/// Movies / Series / Anime / All bars above the catalog.
class ClippedOverlay extends StatefulWidget {
  const ClippedOverlay({super.key, required this.child});

  final Widget child;

  @override
  State<ClippedOverlay> createState() => _ClippedOverlayState();
}

class _ClippedOverlayState extends State<ClippedOverlay> {
  late final OverlayEntry _entry = OverlayEntry(
    builder: (context) => widget.child,
  );

  @override
  void didUpdateWidget(covariant ClippedOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    _entry.markNeedsBuild();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: Overlay(
        initialEntries: [_entry],
      ),
    );
  }
}

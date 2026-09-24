import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'tv.dart';
import 'tv_nav.dart';

/// Universal Android TV remote mapping.
///
/// Cheap Chinese boxes (BeyondTV, etc.) and brand remotes disagree on whether
/// D-pad arrives as arrow keys, DPAD_*, channel/page keys, or gamepad buttons.
/// Map all of them so navigation works without per-device hacks.
TvNavDir? tvNavDirFromKey(KeyEvent event) {
  final key = event.logicalKey;
  final physical = event.physicalKey;

  if (key == LogicalKeyboardKey.arrowUp ||
      key == LogicalKeyboardKey.channelUp ||
      key == LogicalKeyboardKey.pageUp ||
      key == LogicalKeyboardKey.mediaTrackPrevious ||
      physical == PhysicalKeyboardKey.arrowUp ||
      physical == PhysicalKeyboardKey.pageUp) {
    return TvNavDir.up;
  }
  if (key == LogicalKeyboardKey.arrowDown ||
      key == LogicalKeyboardKey.channelDown ||
      key == LogicalKeyboardKey.pageDown ||
      key == LogicalKeyboardKey.mediaTrackNext ||
      physical == PhysicalKeyboardKey.arrowDown ||
      physical == PhysicalKeyboardKey.pageDown) {
    return TvNavDir.down;
  }
  if (key == LogicalKeyboardKey.arrowLeft ||
      key == LogicalKeyboardKey.mediaRewind ||
      physical == PhysicalKeyboardKey.arrowLeft) {
    return TvNavDir.left;
  }
  if (key == LogicalKeyboardKey.arrowRight ||
      key == LogicalKeyboardKey.mediaFastForward ||
      physical == PhysicalKeyboardKey.arrowRight) {
    return TvNavDir.right;
  }
  return null;
}

bool tvIsActivateKey(LogicalKeyboardKey key) {
  return key == LogicalKeyboardKey.select ||
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter ||
      key == LogicalKeyboardKey.space ||
      key == LogicalKeyboardKey.gameButtonA ||
      key == LogicalKeyboardKey.gameButtonStart ||
      key == LogicalKeyboardKey.accept ||
      key == LogicalKeyboardKey.open;
}

bool tvIsBackKey(LogicalKeyboardKey key) {
  return key == LogicalKeyboardKey.goBack ||
      key == LogicalKeyboardKey.escape ||
      key == LogicalKeyboardKey.browserBack ||
      key == LogicalKeyboardKey.gameButtonB;
}

bool _editingText() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  return ctx.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// Global D-pad handler installed once on Android TV.
///
/// Shortcuts alone miss remotes that don't map to arrow LogicalKeys, and they
/// also fail when focus is outside the Shortcuts subtree. This handler covers both.
///
/// Only consume the event when navigation actually moved focus — otherwise
/// physical TVs with unlabeled / not-yet-laid-out focus would go dead.
bool tvRemoteHardwareHandler(KeyEvent event) {
  if (!isAndroidTv) return false;
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
  if (_editingText()) return false;

  final dir = tvNavDirFromKey(event);
  if (dir == null) {
    if (kDebugMode && event is KeyDownEvent) {
      debugPrint(
        'TV key unmapped logical=${event.logicalKey} '
        'physical=${event.physicalKey} keyId=${event.logicalKey.keyId}',
      );
    }
    return false;
  }

  final nav = TvNavController.active;
  if (nav != null && nav.move(dir)) return true;

  final focus = FocusManager.instance.primaryFocus;
  if (focus == null) return false;
  final traversal = switch (dir) {
    TvNavDir.up => TraversalDirection.up,
    TvNavDir.down => TraversalDirection.down,
    TvNavDir.left => TraversalDirection.left,
    TvNavDir.right => TraversalDirection.right,
  };
  return focus.focusInDirection(traversal);
}

void installTvRemoteHandler() {
  if (!isAndroidTv) return;
  HardwareKeyboard.instance.removeHandler(tvRemoteHardwareHandler);
  HardwareKeyboard.instance.addHandler(tvRemoteHardwareHandler);
}

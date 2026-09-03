import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

class LinuxEmbeddedWebView extends StatefulWidget {
  const LinuxEmbeddedWebView({
    super.key,
    required this.url,
    this.visible = true,
    this.onReadyScript,
  });

  final String url;
  final bool visible;
  final String? onReadyScript;

  @override
  State<LinuxEmbeddedWebView> createState() => LinuxEmbeddedWebViewState();
}

class LinuxEmbeddedWebViewState extends State<LinuxEmbeddedWebView> {
  static const _channel = MethodChannel('linux_embedded_webview');
  int? _frameCallback;
  Rect _last = Rect.zero;
  bool _loaded = false;

  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    if (!mounted || _disposed) return;
    try {
      if (widget.onReadyScript != null) {
        await _channel.invokeMethod('setOnReadyScript', {'js': widget.onReadyScript});
      }
      if (!mounted || _disposed) return;
      await _channel.invokeMethod('load', {'url': widget.url});
      _loaded = true;
      _schedule();
    } catch (_) {}
  }

  void _schedule() {
    _frameCallback ??= SchedulerBinding.instance.scheduleFrameCallback(_onFrame);
  }

  void _onFrame(Duration _) {
    _frameCallback = null;
    if (!mounted || _disposed) return;
    _syncBounds();
    _schedule();
    SchedulerBinding.instance.scheduleFrame();
  }

  Future<void> eval(String js) {
    return _channel.invokeMethod('eval', {'js': js});
  }

  void _syncBounds() {
    if (_disposed || !mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || !box.attached) {
      _channel.invokeMethod('setBounds', {
        'x': 0,
        'y': 0,
        'w': 0,
        'h': 0,
        'visible': false,
      });
      return;
    }
    final topLeft = box.localToGlobal(Offset.zero);
    final bottomRight = box.localToGlobal(Offset(box.size.width, box.size.height));
    final rect = Rect.fromPoints(topLeft, bottomRight);
    final visible = widget.visible && rect.width >= 8 && rect.height >= 8;
    if (rect == _last && visible == widget.visible) return;
    _last = rect;
    _channel.invokeMethod('setBounds', {
      'x': rect.left.round(),
      'y': rect.top.round(),
      'w': rect.width.round(),
      'h': rect.height.round(),
      'visible': visible,
    });
  }

  @override
  void didUpdateWidget(covariant LinuxEmbeddedWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url && _loaded) {
      _channel.invokeMethod('load', {'url': widget.url});
    }
    if (oldWidget.onReadyScript != widget.onReadyScript && widget.onReadyScript != null) {
      _channel.invokeMethod('setOnReadyScript', {'js': widget.onReadyScript});
    }
    _syncBounds();
  }

  @override
  void dispose() {
    _disposed = true;
    if (_frameCallback != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(_frameCallback!);
      _frameCallback = null;
    }
    try {
      _channel.invokeMethod('hide');
      _channel.invokeMethod('disposeView');
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(color: Color(0xFF000000));
  }
}

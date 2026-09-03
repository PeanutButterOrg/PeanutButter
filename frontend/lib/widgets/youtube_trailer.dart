import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:linux_embedded_webview/linux_embedded_webview.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../youtube.dart';

bool get linuxDesktop => !kIsWeb && Platform.isLinux;

Future<void> openYoutubeTrailer(String videoId) async {
  final uri = Uri.parse('https://www.youtube.com/watch?v=$videoId');
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

class YoutubeTrailerView extends StatefulWidget {
  const YoutubeTrailerView({
    super.key,
    required this.videoId,
    this.muted = false,
    this.background,
  });

  final String videoId;
  final bool muted;
  final Widget? background;

  @override
  State<YoutubeTrailerView> createState() => YoutubeTrailerViewState();
}

class YoutubeTrailerViewState extends State<YoutubeTrailerView> {
  WebViewController? _controller;
  final GlobalKey<LinuxEmbeddedWebViewState> _linux = GlobalKey();

  String get _url => youtubeEmbedUri(widget.videoId, muted: false).toString();

  String get _readyScript => youtubeForcePlayJs.replaceAll(
        '__MUTED__',
        widget.muted ? 'true' : 'false',
      );

  @override
  void initState() {
    super.initState();
    if (!linuxDesktop) {
      _controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(const Color(0xFF000000))
        ..loadHtmlString(
          youtubeEmbedHtml(widget.videoId, muted: widget.muted),
          baseUrl: 'https://www.youtube.com/',
        );
    }
  }

  Future<void> setMuted(bool muted) async {
    await _controller?.runJavaScript('setMuted(${muted ? 'true' : 'false'});');
    await _linux.currentState?.eval(
      youtubeForcePlayJs.replaceAll('__MUTED__', muted ? 'true' : 'false'),
    );
  }

  Future<void> play() async {
    await _controller?.runJavaScript('playTrailer();');
    await _linux.currentState?.eval(_readyScript);
  }

  @override
  void didUpdateWidget(covariant YoutubeTrailerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.muted != widget.muted) {
      setMuted(widget.muted);
    }
    if (oldWidget.videoId != widget.videoId) {
      _controller?.loadHtmlString(
        youtubeEmbedHtml(widget.videoId, muted: widget.muted),
        baseUrl: 'https://www.youtube.com/',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final backdrop = widget.background ?? const ColoredBox(color: Colors.black);
    if (linuxDesktop) {
      return Stack(
        fit: StackFit.expand,
        children: [
          backdrop,
          LinuxEmbeddedWebView(
            key: _linux,
            url: _url,
            onReadyScript: _readyScript,
          ),
        ],
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        backdrop,
        if (_controller != null) WebViewWidget(controller: _controller!),
      ],
    );
  }
}

class YoutubeTrailerPage extends StatelessWidget {
  const YoutubeTrailerPage({
    super.key,
    required this.videoId,
    required this.title,
  });

  final String videoId;
  final String title;

  @override
  Widget build(BuildContext context) {
    if (linuxDesktop) {
      return _LinuxYoutubeTrailerPage(videoId: videoId, title: title);
    }
    return _WebYoutubeTrailerPage(videoId: videoId, title: title);
  }
}

class _WebYoutubeTrailerPage extends StatefulWidget {
  const _WebYoutubeTrailerPage({required this.videoId, required this.title});

  final String videoId;
  final String title;

  @override
  State<_WebYoutubeTrailerPage> createState() => _WebYoutubeTrailerPageState();
}

class _WebYoutubeTrailerPageState extends State<_WebYoutubeTrailerPage> {
  final GlobalKey<YoutubeTrailerViewState> _player = GlobalKey();
  bool _muted = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: YoutubeTrailerView(
              key: _player,
              videoId: widget.videoId,
              muted: _muted,
            ),
          ),
          Positioned(
            top: 12,
            left: 8,
            child: IconButton(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back, color: Colors.white),
            ),
          ),
          Positioned(
            top: 12,
            right: 12,
            child: IconButton(
              tooltip: _muted ? 'Unmute' : 'Mute',
              onPressed: () {
                setState(() => _muted = !_muted);
                _player.currentState?.setMuted(_muted);
              },
              icon: Icon(_muted ? Icons.volume_off : Icons.volume_up, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

/// WebKitGTK YouTube embeds crash the Linux desktop app, so trailers open in the browser.
class _LinuxYoutubeTrailerPage extends StatefulWidget {
  const _LinuxYoutubeTrailerPage({required this.videoId, required this.title});

  final String videoId;
  final String title;

  @override
  State<_LinuxYoutubeTrailerPage> createState() => _LinuxYoutubeTrailerPageState();
}

class _LinuxYoutubeTrailerPageState extends State<_LinuxYoutubeTrailerPage> {
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_open());
    });
  }

  Future<void> _open() async {
    try {
      await openYoutubeTrailer(widget.videoId);
      if (mounted) Navigator.of(context).maybePop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not open YouTube. $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Center(
            child: _error == null
                ? const CircularProgressIndicator()
                : Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!, style: const TextStyle(color: Colors.white)),
                  ),
          ),
          Positioned(
            top: 12,
            left: 8,
            child: IconButton(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

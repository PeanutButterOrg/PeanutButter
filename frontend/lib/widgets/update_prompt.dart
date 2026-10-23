import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_updater.dart';

/// "PeanutButter 0.3.0 is available" with download progress and install.
class UpdatePrompt extends StatefulWidget {
  const UpdatePrompt({super.key, required this.update});

  final AppUpdate update;

  @override
  State<UpdatePrompt> createState() => _UpdatePromptState();
}

class _UpdatePromptState extends State<UpdatePrompt> {
  double? _progress;
  String? _error;
  bool _revealed = false;
  final _cancel = CancelToken();

  bool get _mac => defaultTargetPlatform == TargetPlatform.macOS;

  Future<void> _install() async {
    setState(() {
      _error = null;
      _progress = 0;
    });
    try {
      final file = await downloadAppUpdate(
        widget.update,
        cancel: _cancel,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p.clamp(0.0, 1.0));
        },
      );
      if (!mounted) return;
      setState(() => _progress = 1);
      await installAppUpdate(widget.update, file);
      // Only macOS gets here (others exit into the installer).
      if (mounted) setState(() => _revealed = true);
    } catch (e) {
      if (!mounted || _cancel.isCancelled) return;
      setState(() {
        _progress = null;
        _error = e is UpdateException ? e.message : 'Update failed: $e';
      });
    }
  }

  @override
  void dispose() {
    if (_progress != null && _progress! < 1) _cancel.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.update;
    final downloading = _progress != null && !_revealed;
    final mb = (u.size / (1024 * 1024)).toStringAsFixed(0);
    return AlertDialog(
      title: Text('PeanutButter ${u.version} is available'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_revealed)
            const Text(
              'The new version is open in Finder. Quit PeanutButter, then drag '
              'PeanutButter into Applications and choose Replace.',
            )
          else if (downloading)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_progress! >= 1 ? 'Installing…' : 'Downloading ($mb MB)…'),
                const SizedBox(height: 12),
                LinearProgressIndicator(value: _progress! >= 1 ? null : _progress),
              ],
            )
          else
            Text(_mac
                ? 'Download the update ($mb MB)? You will move it into Applications.'
                : 'Download and install the update ($mb MB)? PeanutButter restarts when it is done.'),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
      actions: [
        if (u.notesUrl.isNotEmpty && !downloading)
          TextButton(
            onPressed: () => launchUrl(Uri.parse(u.notesUrl)),
            child: const Text('What’s new'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_revealed ? 'Close' : (downloading ? 'Cancel' : 'Later')),
        ),
        if (!_revealed)
          FilledButton(
            onPressed: downloading ? null : _install,
            child: Text(_error != null ? 'Retry' : 'Install'),
          ),
      ],
    );
  }
}

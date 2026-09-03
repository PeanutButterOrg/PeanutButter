import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:graphql_flutter/graphql_flutter.dart';

import '../content_languages.dart';
import '../graphql/client.dart';
import '../graphql/queries.dart';
import '../models.dart';
import '../providers/catalog.dart';
import '../providers/settings.dart';
import '../theme.dart';
import '../tv.dart';
import '../widgets/app_menu.dart';
import '../widgets/cached_art.dart';
import '../widgets/tv_chrome.dart';
import '../widgets/tv_text_field.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _tmdb = TextEditingController();
  final _omdb = TextEditingController();
  final _mediaPath = TextEditingController();
  final _opensubKey = TextEditingController();
  final bool _obscure = true;
  bool _saving = false;
  bool _opensubEnabled = false;
  bool _opensubHydrated = false;
  String? _saveMessage;
  String? _cacheMessage;
  String? _opensubMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final data = ref.read(serverInfoProvider).asData?.value;
      if (data != null) _applyServerInfo(data);
    });
  }

  @override
  void dispose() {
    _tmdb.dispose();
    _omdb.dispose();
    _mediaPath.dispose();
    _opensubKey.dispose();
    super.dispose();
  }

  void _applyServerInfo(ServerInfo data) {
    var changed = false;
    if (_mediaPath.text.isEmpty && data.libraryPath.isNotEmpty) {
      _mediaPath.text = data.libraryPath;
    }
    if (!_opensubHydrated) {
      _opensubHydrated = true;
      if (_opensubEnabled != data.opensubtitlesEnabled) {
        _opensubEnabled = data.opensubtitlesEnabled;
        changed = true;
      }
    }
    if (changed && mounted) setState(() {});
  }

  InputDecoration _field(String hint) {
    return InputDecoration(
      hintText: hint,
      isDense: true,
      filled: true,
      fillColor: const Color(0xFF121218),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
    );
  }

  Future<void> _saveServerFields() async {
    setState(() {
      _saving = true;
      _saveMessage = null;
    });
    final input = <String, dynamic>{};
    if (_tmdb.text.trim().isNotEmpty) input['tmdbApiKey'] = _tmdb.text.trim();
    if (_omdb.text.trim().isNotEmpty) input['omdbApiKey'] = _omdb.text.trim();
    if (_mediaPath.text.trim().isNotEmpty) input['mediaPath'] = _mediaPath.text.trim();
    try {
      if (input.isEmpty) {
        setState(() => _saveMessage = 'Nothing to save');
        return;
      }
      final client = ref.read(graphQLClientProvider);
      final result = await client.mutate(
        MutationOptions(document: gql(UPDATE_SETTINGS), variables: {'input': input}),
      );
      if (result.hasException) {
        setState(() => _saveMessage = graphqlMessage(result));
        return;
      }
      _tmdb.clear();
      _omdb.clear();
      ref.invalidate(serverInfoProvider);
      setState(() => _saveMessage = result.data?['updateSettings']?['message'] as String? ?? 'Saved');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveOpensubtitles() async {
    setState(() {
      _saving = true;
      _opensubMessage = null;
    });
    final keyEntered = _opensubKey.text.trim().isNotEmpty;
    final already = ref.read(serverInfoProvider).valueOrNull?.opensubtitlesConfigured ?? false;
    if (_opensubEnabled && !keyEntered && !already) {
      setState(() {
        _saving = false;
        _opensubMessage = 'Paste your OpenSubtitles API key to enable subtitles.';
      });
      return;
    }
    final input = <String, dynamic>{
      'opensubtitlesEnabled': _opensubEnabled,
    };
    if (keyEntered) input['opensubtitlesApiKey'] = _opensubKey.text.trim();
    try {
      final client = ref.read(graphQLClientProvider);
      final result = await client.mutate(
        MutationOptions(document: gql(UPDATE_SETTINGS), variables: {'input': input}),
      );
      if (result.hasException) {
        setState(() => _opensubMessage = graphqlMessage(result));
        return;
      }
      _opensubKey.clear();
      ref.invalidate(serverInfoProvider);
      setState(() {
        _opensubMessage = _opensubEnabled
            ? 'OpenSubtitles saved. Use the subtitle button on the player to download captions.'
            : 'OpenSubtitles turned off.';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _applyWatchQuality(String value) async {
    await ref.read(settingsProvider.notifier).setDefaultQuality(value);
  }

  Future<void> _clearCache() async {
    await ArtCache.clear();
    if (!mounted) return;
    setState(() => _cacheMessage = 'Downloaded posters and artwork were removed from this device.');
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final info = ref.watch(serverInfoProvider);
    final sync = ref.watch(syncProvider);
    ref.listen(serverInfoProvider, (prev, next) {
      next.whenData((data) {
        if (data != null) _applyServerInfo(data);
      });
    });

    return Scaffold(
      backgroundColor: AppTheme.canvas,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(28, 20, 28, 120),
        children: [
          Row(
            children: [
              if (!isAndroidTv)
                IconButton(
                  tooltip: 'Back',
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
              Text(
                'Settings',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Playback, language, and this device.',
            style: TextStyle(color: Colors.white54, fontSize: 15),
          ),
          const SizedBox(height: 28),
          const _Heading('Watching'),
          const Text(
            'Languages',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
          ),
          const SizedBox(height: 4),
          const Text(
            'Jackett Play keeps sources in any language you select. Choose more than one, or All languages.',
            style: TextStyle(color: Colors.white54, height: 1.35, fontSize: 13),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              AppFilterChip(
                label: 'All languages',
                selected: settings.preferredLanguages.isEmpty,
                onSelected: (_) =>
                    ref.read(settingsProvider.notifier).setPreferredLanguages(const []),
              ),
              for (final lang in kContentLanguages)
                AppFilterChip(
                  label: lang.label,
                  selected: settings.preferredLanguages.contains(lang.code),
                  onSelected: (on) {
                    final next = [...settings.preferredLanguages];
                    if (on) {
                      if (!next.contains(lang.code)) next.add(lang.code);
                    } else {
                      next.remove(lang.code);
                    }
                    ref.read(settingsProvider.notifier).setPreferredLanguages(next);
                  },
                ),
            ],
          ),
          const SizedBox(height: 16),
          _Row(
            title: 'Quality',
            subtitle: 'Applies immediately to local files and streams.',
            child: AppMenuButton<String>(
              hint: 'Quality',
              value: settings.defaultQuality,
              entries: const [
                AppMenuEntry(value: '480p', label: '480p'),
                AppMenuEntry(value: '720p', label: '720p'),
                AppMenuEntry(value: '1080p', label: '1080p'),
                AppMenuEntry(value: '2160p', label: '4K'),
              ],
              onSelected: (v) => _applyWatchQuality(v),
            ),
          ),
          const SizedBox(height: 20),
          const _Heading('Subtitles'),
          const Text(
            'OpenSubtitles downloads captions in the player. Create a free consumer API key at opensubtitles.com, then turn this on.',
            style: TextStyle(color: Colors.white54, height: 1.35, fontSize: 13),
          ),
          const SizedBox(height: 12),
          _Row(
            title: 'Enable OpenSubtitles',
            subtitle: 'Shows a subtitle button on the player and fetches captions automatically.',
            child: TvFocus(
              child: Switch(
                value: _opensubEnabled,
                onChanged: (v) => setState(() => _opensubEnabled = v),
              ),
            ),
          ),
          if (_opensubEnabled) ...[
            TvTextField(
              controller: _opensubKey,
              obscureText: _obscure,
              decoration: _field(
                (ref.watch(serverInfoProvider).valueOrNull?.opensubtitlesConfigured ?? false)
                    ? 'API key — configured, paste to replace'
                    : 'OpenSubtitles API key',
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: _saving ? null : _saveOpensubtitles,
              child: Text(_saving ? 'Saving…' : 'Save OpenSubtitles'),
            ),
          ] else
            FilledButton.tonal(
              onPressed: _saving ? null : _saveOpensubtitles,
              child: Text(_saving ? 'Saving…' : 'Save'),
            ),
          if (_opensubMessage != null) ...[
            const SizedBox(height: 8),
            Text(_opensubMessage!, style: const TextStyle(color: Colors.white70, height: 1.35)),
          ],
          const SizedBox(height: 16),
          _Row(
            title: 'Appearance',
            child: Wrap(
              spacing: 8,
              children: [
                for (final mode in const [
                  (ThemeMode.dark, 'Dark'),
                  (ThemeMode.light, 'Light'),
                  (ThemeMode.system, 'System'),
                ])
                  AppFilterChip(
                    label: mode.$2,
                    selected: settings.themeMode == mode.$1,
                    onSelected: (_) => ref.read(settingsProvider.notifier).setThemeMode(mode.$1),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const _Heading('This device'),
          _Row(
            title: settings.serverUrl.isEmpty ? 'Catalog server' : settings.serverUrl,
            subtitle: 'Disconnect to pair again with a new code from the server console.',
            child: TvFocus(
              child: FilledButton.tonal(
                onPressed: () async {
                  await ref.read(settingsProvider.notifier).forgetPairing(
                        message: 'Disconnected. Pair this device again to continue.',
                      );
                  if (context.mounted) context.go('/');
                },
                child: const Text('Disconnect'),
              ),
            ),
          ),
          _Row(
            title: 'Artwork cache',
            subtitle: 'Posters and backdrops downloaded so rows stay smooth.',
            child: TvFocus(
              child: TextButton(
                onPressed: _clearCache,
                child: const Text('Clear now'),
              ),
            ),
          ),
          if (_cacheMessage != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_cacheMessage!, style: const TextStyle(color: Colors.white70, height: 1.35)),
            ),
          _Row(
            title: 'Clear artwork when the app closes',
            subtitle: 'Deletes downloaded posters from this device each time you leave the app.',
            child: TvFocus(
              child: Switch(
                value: settings.clearCacheOnExit,
                onChanged: (v) => ref.read(settingsProvider.notifier).setClearCacheOnExit(v),
              ),
            ),
          ),
          const SizedBox(height: 20),
          const _Heading('Library'),
          info.when(
            loading: () => const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: LinearProgressIndicator(minHeight: 2),
            ),
            error: (_, __) => const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Text('Connect to the server to manage the library.', style: TextStyle(color: Colors.white54)),
            ),
            data: (data) {
              if (data == null) {
                return const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: Text('Connect to a server to manage the library.', style: TextStyle(color: Colors.white54)),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${data.totalTitles} titles  ·  ${data.syncing ? 'Syncing…' : (data.lastSyncAt == null ? 'Never synced' : 'Last sync ${data.lastSyncAt}')}',
                    style: const TextStyle(color: Colors.white54),
                  ),
                  const SizedBox(height: 12),
                  TvTextField(
                    controller: _mediaPath,
                    decoration: _field('Media folder on the server'),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.tonal(
                        onPressed: _saving ? null : _saveServerFields,
                        child: Text(_saving ? 'Saving…' : 'Save folder'),
                      ),
                      TextButton.icon(
                        onPressed: sync.isLoading ? null : () => ref.read(syncProvider.notifier).trigger(),
                        icon: const Icon(Icons.sync, size: 18),
                        label: Text(sync.isLoading ? 'Starting…' : 'Sync metadata'),
                      ),
                    ],
                  ),
                  sync.when(
                    data: (msg) => msg == null
                        ? const SizedBox.shrink()
                        : Padding(padding: const EdgeInsets.only(top: 8), child: Text(msg)),
                    loading: () => const SizedBox.shrink(),
                    error: (e, _) => Padding(padding: const EdgeInsets.only(top: 8), child: Text('$e')),
                  ),
                  const SizedBox(height: 22),
                  const Text('Optional keys', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  const Text(
                    'OMDb for Rotten Tomatoes. TMDB for extra art.',
                    style: TextStyle(color: Colors.white38, fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  TvTextField(
                    controller: _omdb,
                    obscureText: _obscure,
                    decoration: _field(data.omdbConfigured ? 'OMDb — configured, paste to replace' : 'OMDb key'),
                  ),
                  const SizedBox(height: 10),
                  TvTextField(
                    controller: _tmdb,
                    obscureText: _obscure,
                    decoration: _field(data.tmdbConfigured ? 'TMDB — configured, paste to replace' : 'TMDB key'),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.tonal(
                    onPressed: _saving ? null : _saveServerFields,
                    child: Text(_saving ? 'Saving…' : 'Save keys'),
                  ),
                  if (_saveMessage != null) ...[
                    const SizedBox(height: 8),
                    Text(_saveMessage!, style: const TextStyle(color: Colors.white70)),
                  ],
                  const SizedBox(height: 28),
                  const _Heading('Jackett streaming'),
                  Text(
                    data.jackettConfigured
                        ? 'This server is ready. Every device uses the same Jackett indexers. Configure URL and API key on the server console, not here.'
                        : 'Not configured on the server yet. Sign in at the server address in a browser, then add Jackett under Streaming. After that, every TV and desktop uses it automatically.',
                    style: const TextStyle(color: Colors.white54, height: 1.4, fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  _Row(
                    title: data.jackettConfigured ? 'Ready on the server' : 'Waiting on the server',
                    subtitle: data.jackettEnabled
                        ? (data.jackettConfigured
                            ? 'Magnet search is on for all paired devices.'
                            : 'Jackett is on, but the server still needs a URL and API key.')
                        : 'Jackett is off. Turn it on in the server console.',
                    child: Icon(
                      data.jackettConfigured ? Icons.check_circle_rounded : Icons.cloud_off_rounded,
                      color: data.jackettConfigured ? const Color(0xFF7CFFB2) : Colors.white38,
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.title, required this.child, this.subtitle});

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(subtitle!, style: const TextStyle(color: Colors.white54, height: 1.35, fontSize: 13)),
                ],
              ],
            ),
          ),
          const SizedBox(width: 16),
          child,
        ],
      ),
    );
  }
}

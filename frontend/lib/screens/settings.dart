import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:graphql_flutter/graphql_flutter.dart';

import '../android_playback.dart';
import '../content_languages.dart';
import '../graphql/client.dart';
import '../graphql/queries.dart';
import '../models.dart';
import '../providers/settings.dart';
import '../theme.dart';
import '../tv.dart';
import '../widgets/app_menu.dart';
import '../widgets/cached_art.dart';
import '../player_cache.dart';
import '../widgets/tv_chrome.dart';
import '../widgets/tv_text_field.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _opensubKey = TextEditingController();
  bool _saving = false;
  bool _opensubEnabled = false;
  bool _opensubHydrated = false;
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
    _opensubKey.dispose();
    super.dispose();
  }

  void _applyServerInfo(ServerInfo data) {
    if (_opensubHydrated) return;
    _opensubHydrated = true;
    if (_opensubEnabled != data.opensubtitlesEnabled) {
      _opensubEnabled = data.opensubtitlesEnabled;
      if (mounted) setState(() {});
    }
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
        _opensubMessage = 'Paste your OpenSubtitles API key to turn captions on.';
      });
      return;
    }
    final input = <String, dynamic>{'opensubtitlesEnabled': _opensubEnabled};
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
        _opensubMessage = _opensubEnabled ? 'Subtitles enabled.' : 'Subtitles turned off.';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _clearCache() async {
    await ArtCache.clear();
    await PlayerCache.clear();
    if (!mounted) return;
    setState(() => _cacheMessage = 'Artwork and stream cache cleared.');
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final info = ref.watch(serverInfoProvider);
    ref.listen(serverInfoProvider, (prev, next) {
      next.whenData((data) {
        if (data != null) _applyServerInfo(data);
      });
    });

    final server = info.asData?.value;
    final langs = server?.preferredLanguages ?? settings.preferredLanguages;

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
          const SizedBox(height: 28),

          // —— Playback ——
          const _Heading('Playback'),
          _Card(
            children: [
              _SimpleRow(
                label: 'Video quality',
                trailing: AppMenuButton<String>(
                  hint: 'Quality',
                  value: settings.defaultQuality,
                  entries: const [
                    AppMenuEntry(value: '480p', label: '480p'),
                    AppMenuEntry(value: '720p', label: '720p'),
                    AppMenuEntry(value: '1080p', label: '1080p'),
                    AppMenuEntry(value: '2160p', label: '4K'),
                  ],
                  onSelected: (v) => ref.read(settingsProvider.notifier).setDefaultQuality(v),
                ),
              ),
              if (AndroidPlayback.isAndroid) ...[
                const _Divider(),
                _SimpleRow(
                  label: 'Android player',
                  trailing: AppMenuButton<String>(
                    hint: 'Player',
                    value: AndroidPlayback.toPrefs(
                      settings.androidPlaybackBackend == AndroidPlaybackBackend.external
                          ? AndroidPlaybackBackend.vlc
                          : settings.androidPlaybackBackend,
                    ),
                    entries: const [
                      AppMenuEntry(
                        value: 'vlc',
                        label: 'VLC (in-app, TV)',
                      ),
                      AppMenuEntry(
                        value: 'inApp',
                        label: 'Flutter (Exo / MediaKit)',
                      ),
                    ],
                    onSelected: (v) => ref
                        .read(settingsProvider.notifier)
                        .setAndroidPlaybackBackend(AndroidPlayback.fromPrefs(v)),
                  ),
                ),
              ],
              const _Divider(),
              _SimpleRow(
                label: 'Theme',
                trailing: Wrap(
                  spacing: 8,
                  children: [
                    for (final mode in const [
                      (ThemeMode.dark, 'Dark'),
                      (ThemeMode.light, 'Light'),
                    ])
                      AppFilterChip(
                        label: mode.$2,
                        selected: settings.themeMode == mode.$1,
                        onSelected: (_) => ref.read(settingsProvider.notifier).setThemeMode(mode.$1),
                      ),
                  ],
                ),
              ),
            ],
          ),

          // —— Server ——
          const _Heading('Server'),
          _Card(
            children: [
              _SimpleRow(
                label: 'Languages',
                subtitle: 'Catalog + Jackett · synced to this device',
                trailing: AppMultiMenuButton(
                  hint: 'Languages',
                  icon: Icons.translate_rounded,
                  emptyLabel: 'All languages',
                  values: langs,
                  entries: [
                    for (final lang in kContentLanguages)
                      AppMenuEntry(value: lang.code, label: lang.label),
                  ],
                  onChanged: (next) async {
                    await ref.read(settingsProvider.notifier).setPreferredLanguages(next);
                    try {
                      final client = ref.read(graphQLClientProvider);
                      await client.mutate(
                        MutationOptions(
                          document: gql(UPDATE_SETTINGS),
                          variables: {
                            'input': {'preferredLanguages': next},
                          },
                        ),
                      );
                      ref.invalidate(serverInfoProvider);
                    } catch (_) {}
                  },
                ),
              ),
              const _Divider(),
              _SimpleRow(
                label: 'Jackett',
                subtitle: server == null
                    ? 'Connect to see status'
                    : (server.jackettConfigured
                        ? 'Ready for Play on every device'
                        : 'Configure on the server console'),
                trailing: Icon(
                  server?.jackettConfigured == true
                      ? Icons.check_circle_rounded
                      : Icons.cloud_off_rounded,
                  color: server?.jackettConfigured == true
                      ? const Color(0xFF7CFFB2)
                      : Colors.white38,
                ),
              ),
              if (server != null) ...[
                const _Divider(),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    '${server.totalTitles} titles'
                    '${server.syncing ? ' · Syncing…' : ''}',
                    style: const TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                ),
              ],
            ],
          ),

          // —— Subtitles ——
          const _Heading('Subtitles'),
          _Card(
            children: [
              _SimpleRow(
                label: 'OpenSubtitles',
                subtitle: 'Download captions in the player',
                trailing: TvFocus(
                  child: Switch(
                    value: _opensubEnabled,
                    onChanged: (v) => setState(() => _opensubEnabled = v),
                  ),
                ),
              ),
              if (_opensubEnabled) ...[
                const SizedBox(height: 10),
                TvTextField(
                  controller: _opensubKey,
                  obscureText: true,
                  decoration: _field(
                    (server?.opensubtitlesConfigured ?? false)
                        ? 'API key — paste to replace'
                        : 'OpenSubtitles API key',
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonal(
                  onPressed: _saving ? null : _saveOpensubtitles,
                  child: Text(_saving ? 'Saving…' : 'Save'),
                ),
              ),
              if (_opensubMessage != null) ...[
                const SizedBox(height: 8),
                Text(_opensubMessage!, style: const TextStyle(color: Colors.white70, height: 1.35)),
              ],
            ],
          ),

          // —— This device ——
          const _Heading('This device'),
          _Card(
            children: [
              _SimpleRow(
                label: settings.serverUrl.isEmpty ? 'Not paired' : settings.serverUrl,
                subtitle: 'Remove this device’s pairing code',
                trailing: TvFocus(
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
              const _Divider(),
              _SimpleRow(
                label: 'Artwork cache',
                subtitle: _cacheMessage ?? 'Posters and stream downloads on this device',
                trailing: TvFocus(
                  child: TextButton(
                    onPressed: _clearCache,
                    child: const Text('Clear'),
                  ),
                ),
              ),
              const _Divider(),
              _SimpleRow(
                label: 'Clear cache on exit',
                subtitle: 'Delete streamed downloads when the app closes',
                trailing: TvFocus(
                  child: Switch(
                    value: settings.clearCacheOnExit,
                    onChanged: (v) => ref.read(settingsProvider.notifier).setClearCacheOnExit(v),
                  ),
                ),
              ),
            ],
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
      padding: const EdgeInsets.only(bottom: 10, top: 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: Colors.white70,
            ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF121218),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 10),
      child: Divider(height: 1, color: Color(0x22FFFFFF)),
    );
  }
}

class _SimpleRow extends StatelessWidget {
  const _SimpleRow({
    required this.label,
    required this.trailing,
    this.subtitle,
  });

  final String label;
  final String? subtitle;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              if (subtitle != null) ...[
                const SizedBox(height: 3),
                Text(subtitle!, style: const TextStyle(color: Colors.white54, fontSize: 12, height: 1.3)),
              ],
            ],
          ),
        ),
        const SizedBox(width: 12),
        trailing,
      ],
    );
  }
}

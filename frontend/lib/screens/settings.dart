import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:graphql_flutter/graphql_flutter.dart';

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
import 'package:package_info_plus/package_info_plus.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _opensubKey = TextEditingController();
  final _wyzieKey = TextEditingController();
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
    _wyzieKey.dispose();
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
    final info = ref.read(serverInfoProvider).valueOrNull;
    final osKey = _opensubKey.text.trim();
    final wyzieKey = _wyzieKey.text.trim();
    final osAlready = info?.opensubtitlesConfigured ?? false;
    final wyzieAlready = info?.wyzieConfigured ?? false;
    if (_opensubEnabled && osKey.isEmpty && !osAlready && wyzieKey.isEmpty && !wyzieAlready) {
      setState(() {
        _saving = false;
        _opensubMessage =
            'Paste an OpenSubtitles or Wyzie (store.wyzie.io) key — or use a key already saved on the server.';
      });
      return;
    }
    final input = <String, dynamic>{'opensubtitlesEnabled': _opensubEnabled};
    if (osKey.isNotEmpty) input['opensubtitlesApiKey'] = osKey;
    if (wyzieKey.isNotEmpty) input['wyzieApiKey'] = wyzieKey;
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
      _wyzieKey.clear();
      ref.invalidate(serverInfoProvider);
      setState(() {
        _opensubMessage = 'Subtitle settings saved. Devices use the server key when set.';
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
    final sourcesReady = server?.jackettConfigured == true;

    return Scaffold(
      backgroundColor: AppTheme.canvas,
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          // A readable column instead of rows stretched across wide windows.
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 120),
            children: [
              _Header(
                serverUrl: settings.serverUrl,
                onBack: isAndroidTv ? null : () => Navigator.of(context).maybePop(),
              ),
              const SizedBox(height: 24),

              _Section(
                icon: Icons.play_circle_outline_rounded,
                title: 'Playback',
                description: 'How videos look on this device.',
                children: [
                  _SettingRow(
                    icon: Icons.high_quality_rounded,
                    label: 'Preferred quality',
                    subtitle: 'Torrents closest to this are listed first',
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
                  _SettingRow(
                    icon: Icons.contrast_rounded,
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

              _Section(
                icon: Icons.video_library_outlined,
                title: 'Library & sources',
                description: 'Shared by every device paired with this server.',
                children: [
                  _SettingRow(
                    icon: Icons.translate_rounded,
                    label: 'Content languages',
                    subtitle: 'Catalog and torrent search',
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
                  _SettingRow(
                    icon: Icons.hub_outlined,
                    label: 'Torrent sources',
                    subtitle: server == null
                        ? 'Connect to see status'
                        : (sourcesReady
                            ? 'Jackett or Stremio add-ons on the server'
                            : 'Add Jackett or a Stremio add-on in the server console'),
                    trailing: _StatusPill(
                      label: server == null ? 'Offline' : (sourcesReady ? 'Ready' : 'Not set up'),
                      ok: sourcesReady,
                    ),
                  ),
                  if (server != null)
                    _SettingRow(
                      icon: Icons.movie_filter_outlined,
                      label: 'Catalog',
                      subtitle: server.syncing ? 'Syncing new titles…' : 'Movies, series and anime on the server',
                      trailing: Text(
                        '${server.totalTitles} titles',
                        style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600),
                      ),
                    ),
                ],
              ),

              _Section(
                icon: Icons.closed_caption_outlined,
                title: 'Subtitles',
                description: 'Search and download captions while you watch.',
                children: [
                  _SettingRow(
                    icon: Icons.subtitles_outlined,
                    label: 'Online subtitles',
                    subtitle: server?.subtitlesConfigured == true
                        ? 'A server key is set and used by every device'
                        : 'Needs an OpenSubtitles or Wyzie key',
                    trailing: TvFocus(
                      child: Switch(
                        value: _opensubEnabled,
                        onChanged: (v) => setState(() => _opensubEnabled = v),
                      ),
                    ),
                  ),
                  if (_opensubEnabled)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TvTextField(
                            controller: _opensubKey,
                            obscureText: true,
                            decoration: _field(
                              (server?.opensubtitlesConfigured ?? false)
                                  ? 'OpenSubtitles key (saved; paste to replace)'
                                  : 'OpenSubtitles API key',
                            ),
                          ),
                          const SizedBox(height: 10),
                          TvTextField(
                            controller: _wyzieKey,
                            obscureText: true,
                            decoration: _field(
                              (server?.wyzieConfigured ?? false)
                                  ? 'Wyzie key (saved; paste to replace)'
                                  : 'Wyzie API key (store.wyzie.io)',
                            ),
                          ),
                        ],
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                    child: Row(
                      children: [
                        Expanded(
                          child: _opensubMessage == null
                              ? const SizedBox.shrink()
                              : Text(
                                  _opensubMessage!,
                                  style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.35),
                                ),
                        ),
                        const SizedBox(width: 12),
                        TvFocus(
                          child: FilledButton.tonal(
                            onPressed: _saving ? null : _saveOpensubtitles,
                            child: Text(_saving ? 'Saving…' : 'Save'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              _Section(
                icon: Icons.devices_other_rounded,
                title: 'This device',
                description: 'Storage on this computer.',
                children: [
                  _SettingRow(
                    icon: Icons.cleaning_services_outlined,
                    label: 'Clear stream cache when leaving',
                    subtitle: 'Delete downloaded pieces when you close the player or quit',
                    trailing: TvFocus(
                      child: Switch(
                        value: settings.clearCacheOnExit,
                        onChanged: (v) => ref.read(settingsProvider.notifier).setClearCacheOnExit(v),
                      ),
                    ),
                  ),
                  _SettingRow(
                    icon: Icons.photo_library_outlined,
                    label: 'Cached artwork and streams',
                    subtitle: _cacheMessage ?? 'Free up space; posters download again as needed',
                    trailing: TvFocus(
                      child: OutlinedButton(
                        onPressed: _clearCache,
                        child: const Text('Clear now'),
                      ),
                    ),
                  ),
                ],
              ),

              _Section(
                icon: Icons.info_outline_rounded,
                title: 'About',
                children: [
                  _SettingRow(
                    icon: Icons.apps_rounded,
                    label: 'App version',
                    trailing: const _AppVersion(),
                  ),
                  _SettingRow(
                    icon: Icons.dns_outlined,
                    label: 'Server version',
                    subtitle: settings.serverUrl.isEmpty ? null : settings.serverUrl,
                    trailing: Text(
                      server?.version ?? '–',
                      style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),

              // Kept apart from everyday settings so it isn't hit by accident.
              _DangerZone(
                onDisconnect: () async {
                  await ref.read(settingsProvider.notifier).forgetPairing(
                        message: 'Disconnected. Pair this device again to continue.',
                      );
                  if (context.mounted) context.go('/');
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.serverUrl, this.onBack});

  final String serverUrl;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (onBack != null) ...[
          IconButton.filledTonal(
            tooltip: 'Back',
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          const SizedBox(width: 14),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Settings',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 2),
              Text(
                serverUrl.isEmpty ? 'Not paired with a server' : 'Connected to $serverUrl',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A titled group of settings: icon + title + one-line description over a card.
class _Section extends StatelessWidget {
  const _Section({
    required this.icon,
    required this.title,
    required this.children,
    this.description,
  });

  final IconData icon;
  final String title;
  final String? description;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var k = 0; k < children.length; k++) {
      if (k > 0 && children[k] is _SettingRow && children[k - 1] is _SettingRow) {
        rows.add(const Divider(height: 1, indent: 68, color: Color(0x14FFFFFF)));
      }
      rows.add(children[k]);
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
            child: Row(
              children: [
                Icon(icon, size: 18, color: AppTheme.seed),
                const SizedBox(width: 8),
                Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                if (description != null) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      description!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white38, fontSize: 12.5),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF15151C),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0x14FFFFFF)),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
          ),
        ],
      ),
    );
  }
}

/// Icon tile · label + subtitle · control, at a consistent height.
class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.icon,
    required this.label,
    required this.trailing,
    this.subtitle,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 68),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppTheme.seed.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 19, color: AppTheme.seed),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      subtitle!,
                      style: const TextStyle(color: Colors.white54, fontSize: 12.5, height: 1.3),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 16),
            trailing,
          ],
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.ok});

  final String label;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final color = ok ? const Color(0xFF7DD3A0) : Colors.white54;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _AppVersion extends StatelessWidget {
  const _AppVersion();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (context, snap) {
        final info = snap.data;
        final text = info == null ? '–' : '${info.version} (${info.buildNumber})';
        return Text(text, style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600));
      },
    );
  }
}

class _DangerZone extends StatelessWidget {
  const _DangerZone({required this.onDisconnect});

  final Future<void> Function() onDisconnect;

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFFF8A80);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
      decoration: BoxDecoration(
        color: red.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: red.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Disconnect this device', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5)),
                SizedBox(height: 3),
                Text(
                  'Signs this app out of the server. You will need a new pairing code.',
                  style: TextStyle(color: Colors.white54, fontSize: 12.5, height: 1.3),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          TvFocus(
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: red,
                side: BorderSide(color: red.withValues(alpha: 0.5)),
              ),
              onPressed: onDisconnect,
              child: const Text('Disconnect'),
            ),
          ),
        ],
      ),
    );
  }
}

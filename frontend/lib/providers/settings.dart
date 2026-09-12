import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../graphql/client.dart';
import '../graphql/queries.dart';
import '../models.dart';
import '../services/discovery.dart';

final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError('SharedPreferences must be overridden in main()');
});

final discoveryServiceProvider = Provider<DiscoveryService>((ref) {
  return DiscoveryService();
});

/// True while PlayerScreen is open — keep playback going if the API blips.
final playbackActiveProvider = StateProvider<bool>((ref) => false);

/// Non-Riverpod mirror so SettingsNotifier can ignore auth blips mid-playback.
bool playbackSessionActive = false;

class SettingsState {
  const SettingsState({
    this.serverUrl = '',
    this.apiToken = '',
    this.themeMode = ThemeMode.dark,
    this.defaultQuality = '1080p',
    this.preferredLanguages = const ['en'],
    this.connected = false,
    this.discovering = false,
    this.pairingInProgress = false,
    this.booting = true,
    this.lastError,
    this.clearCacheOnExit = false,
    this.jackettCatalogPending = false,
    this.jackettEnabled = false,
    this.jackettUrl = '',
    this.jackettConfigured = false,
    this.jackettStreamingResolution = '1080p',
  });

  final String serverUrl;
  final String apiToken;
  final ThemeMode themeMode;
  final String defaultQuality;
  final List<String> preferredLanguages;
  final bool connected;
  final bool discovering;
  /// True while Connect is verifying a code — keeps the pairing UI mounted.
  final bool pairingInProgress;
  /// True until the first reachability check finishes — hides Unreachable flash.
  final bool booting;
  final String? lastError;
  final bool clearCacheOnExit;
  final bool jackettCatalogPending;
  final bool jackettEnabled;
  final String jackettUrl;
  final bool jackettConfigured;
  final String jackettStreamingResolution;

  SettingsState copyWith({
    String? serverUrl,
    String? apiToken,
    ThemeMode? themeMode,
    String? defaultQuality,
    List<String>? preferredLanguages,
    bool? connected,
    bool? discovering,
    bool? pairingInProgress,
    bool? booting,
    String? lastError,
    bool? clearCacheOnExit,
    bool? jackettCatalogPending,
    bool? jackettEnabled,
    String? jackettUrl,
    bool? jackettConfigured,
    String? jackettStreamingResolution,
    bool clearError = false,
  }) {
    return SettingsState(
      serverUrl: serverUrl ?? this.serverUrl,
      apiToken: apiToken ?? this.apiToken,
      themeMode: themeMode ?? this.themeMode,
      defaultQuality: defaultQuality ?? this.defaultQuality,
      preferredLanguages: preferredLanguages ?? this.preferredLanguages,
      connected: connected ?? this.connected,
      discovering: discovering ?? this.discovering,
      pairingInProgress: pairingInProgress ?? this.pairingInProgress,
      booting: booting ?? this.booting,
      lastError: clearError ? null : (lastError ?? this.lastError),
      clearCacheOnExit: clearCacheOnExit ?? this.clearCacheOnExit,
      jackettCatalogPending: jackettCatalogPending ?? this.jackettCatalogPending,
      jackettEnabled: jackettEnabled ?? this.jackettEnabled,
      jackettUrl: jackettUrl ?? this.jackettUrl,
      jackettConfigured: jackettConfigured ?? this.jackettConfigured,
      jackettStreamingResolution: jackettStreamingResolution ?? this.jackettStreamingResolution,
    );
  }
}

class SettingsNotifier extends StateNotifier<SettingsState> {
  SettingsNotifier(this._prefs, this._discovery) : super(const SettingsState()) {
    _load();
  }

  final SharedPreferences _prefs;
  final DiscoveryService _discovery;

  static const _kUrl = 'serverUrl';
  static const _kToken = 'apiToken';
  static const _kTheme = 'themeMode';
  static const _kQuality = 'defaultQuality';
  static const _kLangs = 'preferredLanguages';
  static const _kClearCache = 'clearCacheOnExit';
  static const _kJackettPending = 'jackettCatalogPending';
  static const _kJackettEnabled = 'jackettEnabled';
  static const _kJackettUrl = 'jackettUrl';
  static const _kJackettConfigured = 'jackettConfigured';
  static const _kJackettRes = 'jackettStreamingResolution';

  void _load() {
    var theme = _prefs.getString(_kTheme);
    var serverUrl = _prefs.getString(_kUrl) ?? '';
    // Drop stale loopback pairings — the app always uses a LAN/remote host.
    if (isLocalServer(serverUrl)) {
      serverUrl = '';
      unawaited(_prefs.setString(_kUrl, ''));
    }
    final apiToken = _prefs.getString(_kToken) ?? '';
    // Drop legacy "system" preference — on Windows/macOS it followed the OS
    // light theme and painted a white home screen after boot.
    if (theme == 'system') {
      theme = 'dark';
      unawaited(_prefs.setString(_kTheme, 'dark'));
    }
    state = SettingsState(
      serverUrl: serverUrl,
      apiToken: apiToken,
      themeMode: theme == 'light' ? ThemeMode.light : ThemeMode.dark,
      defaultQuality: _prefs.getString(_kQuality) ?? '1080p',
      preferredLanguages: _prefs.getStringList(_kLangs) ?? const ['en'],
      // Always start on the loading gate; bootstrap decides home / pairing / unreachable.
      booting: true,
      clearCacheOnExit: _prefs.getBool(_kClearCache) ?? false,
      jackettCatalogPending: _prefs.getBool(_kJackettPending) ?? false,
      jackettEnabled: _prefs.getBool(_kJackettEnabled) ?? false,
      jackettUrl: _prefs.getString(_kJackettUrl) ?? '',
      jackettConfigured: _prefs.getBool(_kJackettConfigured) ?? false,
      jackettStreamingResolution: _prefs.getString(_kJackettRes) ?? '1080p',
    );
  }

  Future<void> setServerUrl(String url) async {
    var next = url.trim();
    if (isLocalServer(next)) next = '';
    if (next == state.serverUrl) return;
    await _prefs.setString(_kUrl, next);
    state = state.copyWith(serverUrl: next, connected: false, clearError: true);
  }

  Future<void> setApiToken(String token) async {
    final digits = token.replaceAll(RegExp(r'[^0-9]'), '');
    final next = digits.length == 6 ? digits : token.trim();
    if (next == state.apiToken) return;
    await _prefs.setString(_kToken, next);
    state = state.copyWith(apiToken: next);
  }

  Future<void> forgetPairing({String? message}) async {
    await _prefs.remove(_kToken);
    state = state.copyWith(
      apiToken: '',
      connected: false,
      lastError: message ?? 'This device was disconnected. Pair it again with a new code.',
    );
  }

  /// Clears a pairing attempt without treating it as an intentional disconnect.
  Future<void> clearPairingAttempt(String message) async {
    await _prefs.remove(_kToken);
    state = state.copyWith(apiToken: '', connected: false, lastError: message);
  }

  void noteUnauthorized() {
    if (_pairingAttempt) return;
    if (state.apiToken.isEmpty) return;
    // Don't yank pairing while a movie/series is playing.
    if (playbackSessionActive) return;
    unawaited(forgetPairing(
      message: 'This pairing code is no longer valid. Create a new code in the server console.',
    ));
  }

  var _pairingAttempt = false;

  Future<T> runPairingAttempt<T>(Future<T> Function() body) async {
    _pairingAttempt = true;
    state = state.copyWith(pairingInProgress: true, clearError: true);
    try {
      return await body();
    } finally {
      _pairingAttempt = false;
      if (state.pairingInProgress) {
        state = state.copyWith(pairingInProgress: false);
      }
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    // "System" followed OS light theme on Windows/macOS and blanked the UI white.
    final effective = mode == ThemeMode.system ? ThemeMode.dark : mode;
    await _prefs.setString(
      _kTheme,
      effective == ThemeMode.light ? 'light' : 'dark',
    );
    state = state.copyWith(themeMode: effective);
  }

  Future<void> setDefaultQuality(String quality) async {
    await _prefs.setString(_kQuality, quality);
    state = state.copyWith(defaultQuality: quality);
  }

  Future<void> setPreferredLanguages(List<String> codes) async {
    final unique = <String>{
      for (final code in codes)
        if (code.trim().isNotEmpty) code.trim().toLowerCase(),
    }.toList();
    await _prefs.setStringList(_kLangs, unique);
    state = state.copyWith(preferredLanguages: unique);
  }

  Future<void> setClearCacheOnExit(bool value) async {
    await _prefs.setBool(_kClearCache, value);
    state = state.copyWith(clearCacheOnExit: value);
  }

  Future<void> setJackettCatalogPending(bool value) async {
    await _prefs.setBool(_kJackettPending, value);
    if (state.jackettCatalogPending == value) return;
    state = state.copyWith(jackettCatalogPending: value);
  }

  Future<void> rememberJackett({
    required bool enabled,
    required String url,
    required bool configured,
    required String resolution,
  }) async {
    final nextUrl = url.trim();
    if (state.jackettEnabled == enabled &&
        state.jackettUrl == nextUrl &&
        state.jackettConfigured == configured &&
        state.jackettStreamingResolution == resolution) {
      return;
    }
    await _prefs.setBool(_kJackettEnabled, enabled);
    await _prefs.setString(_kJackettUrl, nextUrl);
    await _prefs.setBool(_kJackettConfigured, configured);
    await _prefs.setString(_kJackettRes, resolution);
    state = state.copyWith(
      jackettEnabled: enabled,
      jackettUrl: nextUrl,
      jackettConfigured: configured,
      jackettStreamingResolution: resolution,
    );
  }

  Future<void> rememberJackettFromServer(ServerInfo info) async {
    await rememberJackett(
      enabled: info.jackettEnabled,
      url: info.jackettUrl ?? '',
      configured: info.jackettConfigured,
      resolution: info.streamingResolution,
    );
    // Mirror server content languages for Play + subtitles on this device.
    await setPreferredLanguages(info.preferredLanguages);
  }

  Future<bool> probeCurrent() async {
    final url = state.serverUrl.trim();
    if (url.isEmpty) {
      state = state.copyWith(connected: false);
      return false;
    }
    final ok = await _discovery.probeHealth(url);
    if (!ok) {
      state = state.copyWith(connected: false, lastError: 'Cannot reach $url');
      return false;
    }
    if (state.apiToken.isEmpty) {
      state = state.copyWith(
        connected: false,
        lastError:
            'Type the 6-digit pairing code from the server console (sign in at the server address in a browser).',
      );
      return false;
    }
    return true;
  }

  /// Boot probe with short retries — NAS/API often need a moment after wake.
  Future<bool> probeCurrentWithRetry({int attempts = 4}) async {
    for (var i = 0; i < attempts; i++) {
      if (await probeCurrent()) return true;
      if (i + 1 < attempts) {
        await Future<void>.delayed(Duration(milliseconds: 350 * (i + 1)));
      }
    }
    return false;
  }

  Future<void> markConnected() async {
    // Do not clear booting here — finishBoot() owns leaving the loading gate
    // so Unreachable/Home never flash mid-check.
    state = state.copyWith(connected: true, clearError: true);
  }

  Future<void> markDisconnected(String message) async {
    state = state.copyWith(connected: false, lastError: message);
  }

  void beginBoot() {
    if (state.booting) return;
    state = state.copyWith(booting: true, clearError: true);
  }

  void finishBoot() {
    if (!state.booting) return;
    state = state.copyWith(booting: false);
  }

  Future<String?> discoverLocalhost() async {
    // Don't stomp a live session or an in-flight Connect.
    if (state.connected || state.pairingInProgress) {
      return state.serverUrl.isEmpty ? null : state.serverUrl;
    }
    state = state.copyWith(discovering: true, clearError: true);
    try {
      final found = await _discovery.discover(savedUrl: state.serverUrl);
      // Pairing may have finished while we were scanning the LAN.
      if (state.connected || state.pairingInProgress) {
        state = state.copyWith(discovering: false);
        return found ?? (state.serverUrl.isEmpty ? null : state.serverUrl);
      }
      if (found != null) {
        await setServerUrl(found);
        if (state.connected || state.pairingInProgress) {
          state = state.copyWith(discovering: false);
          return found;
        }
        if (state.apiToken.isEmpty) {
          state = state.copyWith(
            discovering: false,
            connected: false,
            lastError:
                'Server found. Type the 6-digit pairing code from the console, then Connect.',
          );
          return found;
        }
        // URL only — session gate / bootstrap decides connected via /health.
        state = state.copyWith(discovering: false);
        return found;
      }
      if (state.connected || state.pairingInProgress) {
        state = state.copyWith(discovering: false);
        return state.serverUrl.isEmpty ? null : state.serverUrl;
      }
      state = state.copyWith(
        discovering: false,
        connected: false,
        lastError: 'No catalog server found on this network',
      );
      return null;
    } catch (e) {
      state = state.copyWith(discovering: false, lastError: e.toString());
      return null;
    }
  }
}

final settingsProvider = StateNotifierProvider<SettingsNotifier, SettingsState>((ref) {
  return SettingsNotifier(
    ref.watch(sharedPreferencesProvider),
    ref.watch(discoveryServiceProvider),
  );
});

final graphQLClientProvider = Provider<GraphQLClient>((ref) {
  final url = ref.watch(settingsProvider.select((s) => s.serverUrl));
  final token = ref.watch(settingsProvider.select((s) => s.apiToken));
  return createGraphQLClient(
    url,
    apiToken: token,
    onUnauthorized: () => ref.read(settingsProvider.notifier).noteUnauthorized(),
  );
});

final serverInfoProvider = FutureProvider<ServerInfo?>((ref) async {
  final client = ref.watch(graphQLClientProvider);
  final serverUrl = ref.watch(settingsProvider.select((s) => s.serverUrl));
  final apiToken = ref.watch(settingsProvider.select((s) => s.apiToken));
  if (serverUrl.isEmpty || apiToken.isEmpty) {
    return null;
  }
  final result = await client
      .query(
        QueryOptions(
          document: gql(GET_SERVER_INFO),
          fetchPolicy: FetchPolicy.networkOnly,
        ),
      )
      .timeout(const Duration(seconds: 20));
  if (result.hasException) {
    throw result.exception!;
  }
  final json = result.data?['serverInfo'] as Map<String, dynamic>?;
  if (json == null) return null;
  final parsed = ServerInfo.fromJson(json);
  // Defer so we don't rebuild this provider while it's still resolving.
  Future.microtask(() {
    ref.read(settingsProvider.notifier).rememberJackettFromServer(parsed);
  });
  return parsed;
});

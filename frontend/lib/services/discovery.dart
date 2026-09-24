import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:network_info_plus/network_info_plus.dart';

import '../graphql/client.dart';

/// Finds a catalog API on the LAN (gateway + subnet) via `/health`.
/// Never uses loopback — the app always targets a real network host.
class DiscoveryService {
  DiscoveryService({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                // Without connectTimeout, dead LAN IPs hang Find for a long time.
                connectTimeout: const Duration(milliseconds: 700),
                sendTimeout: const Duration(milliseconds: 1000),
                receiveTimeout: const Duration(milliseconds: 1000),
              ),
            );

  final Dio _dio;

  bool get _android => !kIsWeb && Platform.isAndroid;

  Future<String?> discover({
    String? savedUrl,
    Duration timeout = const Duration(milliseconds: 1000),
  }) async {
    final candidates = <String>[];

    // 1) Prefer a previously saved LAN/remote URL (ignore loopback leftovers).
    if (savedUrl != null && savedUrl.trim().isNotEmpty) {
      final saved = normalizeServerBase(savedUrl);
      if (!isLocalServer(saved)) {
        candidates.add(saved);
      }
    }

    // 2) Local network: gateway first, then common hosts on this subnet.
    if (!kIsWeb) {
      try {
        candidates.addAll(await _lanCandidates());
      } catch (_) {}
    } else {
      final origin = Uri.base.origin;
      if (origin.isNotEmpty && !isLocalServer(origin)) {
        candidates.add(origin);
      }
    }

    final seen = <String>{};
    final unique = <String>[];
    for (final url in candidates) {
      final base = normalizeServerBase(url);
      if (isLocalServer(base)) continue;
      if (seen.add(base)) unique.add(base);
    }

    const batch = 32;
    for (var i = 0; i < unique.length; i += batch) {
      final chunk = unique.skip(i).take(batch);
      final found = await Future.wait(
        chunk.map((url) async {
          if (await probeHealth(url, timeout: timeout)) return url;
          return null;
        }),
      );
      for (final url in found) {
        if (url != null) return url;
      }
    }
    return null;
  }

  Future<bool> probeHealth(String serverUrl, {Duration timeout = const Duration(seconds: 2)}) async {
    final base = normalizeServerBase(serverUrl);
    if (isLocalServer(base)) return false;
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '$base/health',
        options: Options(
          sendTimeout: timeout,
          receiveTimeout: timeout,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final data = response.data;
      return response.statusCode == 200 && data != null && data['status'] != null;
    } catch (_) {
      return false;
    }
  }

  /// Probe [serverUrl]; if it fails and no non-default port was typed, try `:3001`
  /// (PeanutButter’s published console/API port). Returns the reachable base or null.
  Future<String?> resolveReachableBase(
    String serverUrl, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final base = normalizeServerBase(serverUrl);
    if (base.isEmpty || isLocalServer(base)) return null;
    if (await probeHealth(base, timeout: timeout)) return base;

    final uri = Uri.tryParse(base);
    if (uri == null || uri.host.isEmpty) return null;
    // Default http→80 / https→443, or an explicit :80 — try the app port.
    final try3001 = !uri.hasPort || uri.port == 80 || uri.port == 443;
    if (!try3001) return null;

    final alt = uri.replace(port: 3001).toString().replaceFirst(RegExp(r'/+$'), '');
    if (alt == base) return null;
    if (await probeHealth(alt, timeout: timeout)) return alt;
    return null;
  }

  /// Legacy name used by settings.
  Future<bool> probe(String graphqlUrl, {Duration timeout = const Duration(seconds: 2)}) {
    return probeHealth(graphqlUrl, timeout: timeout);
  }

  Future<List<String>> _lanCandidates() async {
    final candidates = <String>[];

    // Gateway / router IP often hosts the home server (e.g. ZimaOS).
    try {
      final gateway = await NetworkInfo().getWifiGatewayIP();
      final gw = gateway?.trim() ?? '';
      if (gw.isNotEmpty && !gw.startsWith('127.')) {
        candidates.add('http://$gw:3001');
        candidates.add('http://$gw:8080');
      }
    } catch (_) {}

    final prefixes = await _subnetPrefixes();
    // Prefer known / common NAS hosts early (110 = typical Zima / PeanutButter box).
    const preferred = [110, 1, 2, 4, 5, 7, 8, 10, 20, 28, 30, 50, 100, 101, 150, 200, 254];
    for (final prefix in prefixes) {
      for (final host in preferred) {
        candidates.add('http://$prefix.$host:3001');
      }
    }
    // Full /24 sweeps are very slow on Android TV and raced with pairing.
    if (!_android) {
      for (final prefix in prefixes) {
        for (var i = 1; i <= 254; i++) {
          if (preferred.contains(i)) continue;
          candidates.add('http://$prefix.$i:3001');
        }
      }
    }
    return candidates;
  }

  Future<List<String>> _subnetPrefixes() async {
    final prefixes = <String>{};
    if (!kIsWeb) {
      try {
        for (final iface in await NetworkInterface.list(
          includeLinkLocal: false,
          type: InternetAddressType.IPv4,
        )) {
          for (final addr in iface.addresses) {
            if (addr.isLoopback) continue;
            final parts = addr.address.split('.');
            if (parts.length == 4) {
              prefixes.add('${parts[0]}.${parts[1]}.${parts[2]}');
            }
          }
        }
      } catch (_) {}
      try {
        final wifi = await NetworkInfo().getWifiIP();
        final parts = wifi?.split('.') ?? const [];
        if (parts.length == 4) {
          prefixes.add('${parts[0]}.${parts[1]}.${parts[2]}');
        }
      } catch (_) {}
    }
    if (prefixes.isEmpty) {
      prefixes.addAll(const ['10.0.0', '192.168.1', '192.168.0']);
    }
    return prefixes.toList();
  }
}

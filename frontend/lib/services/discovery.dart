import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:network_info_plus/network_info_plus.dart';

import '../graphql/client.dart';

/// Finds a catalog API on this machine or LAN via `/health`.
class DiscoveryService {
  DiscoveryService({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  bool get _android => !kIsWeb && Platform.isAndroid;

  Future<String?> discover({
    String? savedUrl,
    Duration timeout = const Duration(milliseconds: 1200),
  }) async {
    final candidates = <String>[];

    if (savedUrl != null && savedUrl.trim().isNotEmpty) {
      final saved = normalizeServerBase(savedUrl);
      if (!(_android && isLocalServer(saved))) {
        candidates.add(saved);
      }
    }

    if (!_android) {
      candidates.addAll(const [
        'http://127.0.0.1:3001',
        'http://localhost:3001',
        'http://127.0.0.1:8080',
        'http://localhost:8080',
        'http://10.0.2.2:3001',
        'http://10.0.2.2:8080',
      ]);
    }

    if (!kIsWeb) {
      try {
        final lan = await _lanCandidates();
        candidates.addAll(lan);
      } catch (_) {}
    } else {
      final origin = Uri.base.origin;
      if (origin.isNotEmpty) {
        candidates.add(origin);
      }
    }

    final seen = <String>{};
    final unique = <String>[];
    for (final url in candidates) {
      final base = normalizeServerBase(url);
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
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '${normalizeServerBase(serverUrl)}/health',
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

  /// Legacy name used by settings.
  Future<bool> probe(String graphqlUrl, {Duration timeout = const Duration(seconds: 2)}) {
    return probeHealth(graphqlUrl, timeout: timeout);
  }

  Future<List<String>> _lanCandidates() async {
    final prefixes = await _subnetPrefixes();
    final candidates = <String>[];
    const preferred = [1, 2, 4, 5, 7, 8, 10, 20, 28, 30, 50, 100, 101, 150, 200, 254];
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

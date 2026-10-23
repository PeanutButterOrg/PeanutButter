import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// Raw Ed25519 key matching packaging/update-signing-public.pem. Only
/// releases signed by the UPDATE_SIGNING_KEY CI secret are installed.
const _updatePublicKey = 'ZZiyOouovg/54bH4BjyDRk3gldZtS+oHJjjkUGo6e7c=';

class UpdateException implements Exception {
  const UpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

class AppUpdate {
  const AppUpdate({
    required this.version,
    required this.build,
    required this.notesUrl,
    required this.platform,
    required this.name,
    required this.size,
    required this.sha256,
    required this.url,
    required this.token,
  });

  final String version;
  final int build;
  final String notesUrl;
  final String platform;
  final String name;
  final int size;
  final String sha256;
  final String url;
  final String token;
}

/// Which installer this copy of the app can apply, or null when it can't
/// update itself (web, phones, a portable Linux folder).
String? updatePlatformKey() {
  if (kIsWeb) return null;
  if (Platform.isWindows) return 'windows';
  if (Platform.isMacOS) return 'macos';
  if (Platform.isLinux) {
    if ((Platform.environment['APPIMAGE'] ?? '').isNotEmpty) return 'linux-appimage';
    final exe = Platform.resolvedExecutable;
    if (exe.startsWith('/usr/') || exe.startsWith('/opt/')) return 'linux-deb';
  }
  return null;
}

Future<bool> verifyUpdateSignature(List<int> message, String signatureB64) async {
  try {
    final publicKey = SimplePublicKey(
      base64Decode(_updatePublicKey),
      type: KeyPairType.ed25519,
    );
    return await Ed25519().verify(
      message,
      signature: Signature(base64Decode(signatureB64.trim()), publicKey: publicKey),
    );
  } catch (_) {
    return false;
  }
}

/// Ask the paired server for a newer signed release for this platform.
Future<AppUpdate?> checkForAppUpdate({
  required String serverBase,
  required String token,
}) async {
  final platform = updatePlatformKey();
  if (platform == null || serverBase.trim().isEmpty) return null;
  final base = serverBase.trim().replaceAll(RegExp(r'/+$'), '');
  final res = await Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 20),
  )).get<Map<String, dynamic>>(
    '$base/updates/latest',
    queryParameters: {'platform': platform},
    options: Options(
      headers: token.isEmpty ? null : {'X-Api-Key': token},
      validateStatus: (s) => s != null && s < 500,
    ),
  );
  final data = res.data;
  if (res.statusCode != 200 || data == null) return null;

  // Trust only the signed manifest, never the unsigned fields around it.
  final manifestText = data['manifest'] as String? ?? '';
  final signature = data['signature'] as String? ?? '';
  if (!await verifyUpdateSignature(utf8.encode(manifestText), signature)) {
    throw const UpdateException('The server offered an update with an invalid signature.');
  }
  final manifest = jsonDecode(manifestText) as Map<String, dynamic>;
  final asset = (manifest['assets'] as Map?)?[platform] as Map?;
  if (asset == null) return null;
  final build = (manifest['build'] as num?)?.toInt() ?? 0;
  final info = await PackageInfo.fromPlatform();
  final current = int.tryParse(info.buildNumber) ?? 0;
  if (build <= current) return null;

  final path = data['url'] as String? ?? '';
  return AppUpdate(
    version: manifest['version'] as String? ?? '?',
    build: build,
    notesUrl: manifest['notes_url'] as String? ?? '',
    platform: platform,
    name: asset['name'] as String,
    size: (asset['size'] as num).toInt(),
    sha256: (asset['sha256'] as String).toLowerCase(),
    url: path.startsWith('http') ? path : '$base$path',
    token: token,
  );
}

/// Download to a temp file and check it against the signed size + SHA-256.
Future<File> downloadAppUpdate(
  AppUpdate u, {
  void Function(double progress)? onProgress,
  CancelToken? cancel,
}) async {
  final dir = Directory('${(await getTemporaryDirectory()).path}/pb-update');
  await dir.create(recursive: true);
  final file = File('${dir.path}/${u.name}');
  if (await file.exists()) await file.delete();
  await Dio().download(
    u.url,
    file.path,
    cancelToken: cancel,
    options: Options(headers: u.token.isEmpty ? null : {'X-Api-Key': u.token}),
    onReceiveProgress: (got, total) {
      if (onProgress != null) onProgress(got / (total > 0 ? total : u.size));
    },
  );
  final size = await file.length();
  final digest = (await crypto.sha256.bind(file.openRead()).first).toString();
  if (size != u.size || digest != u.sha256) {
    await file.delete();
    throw const UpdateException('The downloaded update does not match the signed release.');
  }
  return file;
}

/// Hand the verified installer to the OS. On Windows / Linux this exits the
/// app (the new version starts on its own); on macOS it returns after
/// revealing the new app for the user to drag into Applications.
Future<void> installAppUpdate(AppUpdate u, File file) async {
  switch (u.platform) {
    case 'windows':
      // Silent Inno Setup run; the installer relaunches PeanutButter.
      await Process.start(
        file.path,
        ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS'],
        mode: ProcessStartMode.detached,
      );
      exit(0);
    case 'linux-appimage':
      final target = Platform.environment['APPIMAGE']!;
      final staged = '$target.new';
      await file.copy(staged);
      await Process.run('chmod', ['+x', staged]);
      // Replacing a running AppImage is safe on Linux (the old inode stays open).
      await File(staged).rename(target);
      await Process.start(target, const [], mode: ProcessStartMode.detached);
      exit(0);
    case 'linux-deb':
      final result = await Process.run('pkexec', ['apt-get', 'install', '-y', file.path]);
      if (result.exitCode != 0) {
        // No polkit agent / user cancelled: let the software centre take it.
        await Process.run('xdg-open', [file.path]);
        return;
      }
      await Process.start(Platform.resolvedExecutable, const [],
          mode: ProcessStartMode.detached);
      exit(0);
    case 'macos':
      // Sandboxed apps can't replace themselves in /Applications: unpack the
      // verified app into Downloads and show it in Finder.
      final home = Platform.environment['HOME'] ?? '';
      final downloads = Directory('$home/Downloads/PeanutButter ${u.version}');
      await downloads.create(recursive: true);
      final unzip = await Process.run('ditto', ['-x', '-k', file.path, downloads.path]);
      if (unzip.exitCode != 0) {
        throw UpdateException('Could not unpack the update: ${unzip.stderr}');
      }
      await launchUrl(Uri.directory(downloads.path));
      return;
  }
  throw UpdateException('This copy of PeanutButter can’t update itself (${u.platform}).');
}

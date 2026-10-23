import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:peanutbutter/app_updater.dart';

/// Signed by CI's exact command (`openssl pkeyutl -sign -rawin`) with the real
/// update key — same fixture as backend/src/updates.rs.
const _fixture = '{"schema":1,"version":"0.0.1","build":1,"tag":"v0.0.1","assets":{}}\n';
const _fixtureSig =
    'Lz4t5lcX/1zacups8J6ny8y15a8z0HAYCjHMt+hzWQqvFE+qzNELo5yte55nORmoqConwMNxZE/9NLGEdnxVAQ==';

void main() {
  test('accepts a release signed with the update key', () async {
    expect(await verifyUpdateSignature(utf8.encode(_fixture), _fixtureSig), isTrue);
  });

  test('rejects tampered manifests and junk signatures', () async {
    final tampered = utf8.encode(_fixture.replaceFirst('0.0.1', '9.9.9'));
    expect(await verifyUpdateSignature(tampered, _fixtureSig), isFalse);
    expect(await verifyUpdateSignature(utf8.encode(_fixture), 'AAAA'), isFalse);
    expect(await verifyUpdateSignature(utf8.encode(_fixture), 'not base64!'), isFalse);
  });
}

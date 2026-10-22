import 'package:dio/dio.dart';

/// Outcome of trading a 6-digit pairing code for this device's key.
sealed class PairingExchange {
  const PairingExchange();
}

/// The server issued a long-lived device key (store it as the API token).
class PairingKey extends PairingExchange {
  const PairingKey(this.key);
  final String key;
}

/// Wrong or expired code.
class PairingRejected extends PairingExchange {
  const PairingRejected(this.message);
  final String message;
}

/// Older server without POST /pair: the code itself is still the token.
class PairingUnsupported extends PairingExchange {
  const PairingUnsupported();
}

/// 6-digit codes are pairing codes; anything else is already a device key.
bool isPairingCode(String token) =>
    RegExp(r'^\d{6}$').hasMatch(token.replaceAll(RegExp(r'\s'), ''));

/// POST {server}/pair `{"code": …}` → `{"key": "pbk_…"}`.
///
/// Throws [DioException] for network failures and rate limiting (429), so
/// callers never mistake "couldn't ask" for "code rejected".
Future<PairingExchange> exchangePairingCode(String serverBase, String code) async {
  final base = serverBase.trim().replaceFirst(RegExp(r'/+$'), '');
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 15),
      // Inspect 4xx ourselves; only network errors and 5xx/429 throw.
      validateStatus: (s) => s != null && s < 500 && s != 429,
    ),
  );
  try {
    final res = await dio.post<Map<String, dynamic>>(
      '$base/pair',
      data: {'code': code.replaceAll(RegExp(r'\s'), '')},
    );
    final status = res.statusCode ?? 0;
    if (status == 404 || status == 405) return const PairingUnsupported();
    final key = res.data?['key'];
    if (status == 200 && key is String && key.isNotEmpty) return PairingKey(key);
    final msg = res.data?['error'];
    return PairingRejected(
      msg is String && msg.isNotEmpty
          ? msg
          : 'That pairing code is wrong or expired. Create a new one in the server console.',
    );
  } finally {
    dio.close(force: true);
  }
}

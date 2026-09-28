import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'hub_lan_token.dart';

/// Protects PIN hashes over the existing HTTP LAN transport. The business ID
/// is authenticated too, so a payload cannot be replayed into another business.
class HubRosterCodec {
  static final _cipher = AesGcm.with256bits();

  static Future<Map<String, String>> requestHeaders({
    required String businessId,
    required String token,
    DateTime? now,
  }) async {
    final timestamp = (now ?? DateTime.now()).toUtc().toIso8601String();
    final nonce = base64Encode(_cipher.newNonce());
    final mac = await Hmac.sha256().calculateMac(
      utf8.encode('$businessId\n$timestamp\n$nonce'),
      secretKey: await _key(token),
    );
    return {
      'Authorization': 'Roster ${base64Encode(mac.bytes)}',
      'x-roster-time': timestamp,
      'x-roster-nonce': nonce,
    };
  }

  static Future<bool> authorize({
    required Map<String, String> headers,
    required String businessId,
    required String token,
    DateTime? now,
  }) async {
    try {
      final time = headers['x-roster-time'] ?? '';
      final timestamp = DateTime.tryParse(time);
      if (timestamp == null ||
          (now ?? DateTime.now()).difference(timestamp).abs() >
              const Duration(minutes: 2)) {
        return false;
      }
      final nonce = headers['x-roster-nonce'] ?? '';
      if (base64Decode(nonce).length != 12) return false;
      final authorization = headers['authorization'] ?? '';
      if (!authorization.startsWith('Roster ')) return false;
      final presented = base64Decode(authorization.substring(7));
      final expected = await Hmac.sha256().calculateMac(
        utf8.encode('$businessId\n$time\n$nonce'),
        secretKey: await _key(token),
      );
      if (presented.length != expected.bytes.length) return false;
      var mismatch = 0;
      for (var i = 0; i < presented.length; i++) {
        mismatch |= presented[i] ^ expected.bytes[i];
      }
      return mismatch == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<SecretKey> _key(String token) async {
    if (token.isEmpty || token == kLegacyHubLanToken) {
      throw StateError('Se requiere el token privado del negocio.');
    }
    final hash = await Sha256().hash(utf8.encode('mangopos-roster-v1:$token'));
    return SecretKey(hash.bytes);
  }

  static Future<Map<String, dynamic>> seal(
    Map<String, dynamic> roster, {
    required String businessId,
    required String token,
  }) async {
    final box = await _cipher.encrypt(
      utf8.encode(jsonEncode(roster)),
      secretKey: await _key(token),
      aad: utf8.encode(businessId),
    );
    return {
      'version': 1,
      'nonce': base64Encode(box.nonce),
      'ciphertext': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    };
  }

  static Future<Map<String, dynamic>> open(
    Map<String, dynamic> envelope, {
    required String businessId,
    required String token,
  }) async {
    if (envelope['version'] != 1) throw const FormatException('Roster version');
    final plain = await _cipher.decrypt(
      SecretBox(
        base64Decode(envelope['ciphertext'] as String),
        nonce: base64Decode(envelope['nonce'] as String),
        mac: Mac(base64Decode(envelope['mac'] as String)),
      ),
      secretKey: await _key(token),
      aad: utf8.encode(businessId),
    );
    return Map<String, dynamic>.from(jsonDecode(utf8.decode(plain)) as Map);
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Cifrado en reposo (envelope encryption) para blobs offline sensibles que
/// viven en SharedPreferences (snapshots de órdenes, roster). Antes iban en
/// texto plano: un dispositivo comprometido exponía montos, items, clientes
/// y PII del personal.
///
/// Esquema:
///   - Una clave aleatoria de 256 bits, generada una sola vez y guardada en
///     `flutter_secure_storage` (Keychain iOS / EncryptedSharedPreferences
///     Android). En memoria se cachea tras el primer uso.
///   - Cada valor se cifra con **AES-GCM** (autenticado: detecta
///     manipulación). Formato del sobre: `enc:v1:<base64(nonce|ct|mac)>`.
///
/// Migración perezosa: [open] devuelve los valores legacy en texto plano
/// tal cual (no tienen el prefijo); el caller los reescribe cifrados en el
/// próximo write. No hay migración masiva bloqueante.
///
/// Degradación segura: si el descifrado falla (clave perdida/rotada o blob
/// corrupto), [open] devuelve null en vez de lanzar — el caller lo trata
/// como "ese dato no está" (ej: un borrador de orden se pierde) sin crashear.
///
/// ⚠️ Web: `flutter_secure_storage` en web es débil (la clave es derivable
/// desde el navegador). En web esto es defensa superficial, no fuerte —
/// aceptado a propósito (los cajeros web son caso secundario del POS).
class SecureBlobCipher {
  SecureBlobCipher._();
  static final SecureBlobCipher instance = SecureBlobCipher._();

  static const String envelopePrefix = 'enc:v1:';
  static const String _keyStorageKey = 'mp_offline_blob_key_v1';
  static const int _nonceLength = 12; // AES-GCM nonce estándar
  static const int _macLength = 16; // AES-GCM tag

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  final AesGcm _algorithm = AesGcm.with256bits();
  Future<SecretKey>? _keyFuture;

  // Memoiza la carga/creación de la clave para no pegarle al secure storage
  // en cada read/write y para evitar generar dos claves en una race.
  Future<SecretKey> _key() => _keyFuture ??= _loadOrCreateKey();

  Future<SecretKey> _loadOrCreateKey() async {
    final existing = await _secureStorage.read(key: _keyStorageKey);
    if (existing != null && existing.isNotEmpty) {
      try {
        return SecretKey(base64Decode(existing));
      } catch (_) {
        // Clave corrupta: regeneramos. Los blobs viejos cifrados con la
        // clave perdida quedarán ilegibles (open → null), aceptable.
      }
    }
    final fresh = await _algorithm.newSecretKey();
    final bytes = await fresh.extractBytes();
    await _secureStorage.write(key: _keyStorageKey, value: base64Encode(bytes));
    return SecretKey(bytes);
  }

  bool isEnveloped(String value) => value.startsWith(envelopePrefix);

  /// Cifra [plaintext] y devuelve el sobre `enc:v1:...`.
  Future<String> seal(String plaintext) async {
    final key = await _key();
    final nonce = _algorithm.newNonce();
    final box = await _algorithm.encrypt(
      utf8.encode(plaintext),
      secretKey: key,
      nonce: nonce,
    );
    final blob = <int>[...box.nonce, ...box.cipherText, ...box.mac.bytes];
    return '$envelopePrefix${base64Encode(blob)}';
  }

  /// Devuelve el texto en claro de [stored]:
  ///   - Si NO está cifrado (legacy en texto plano), lo devuelve tal cual.
  ///   - Si está cifrado, lo descifra; null si el descifrado falla.
  Future<String?> open(String stored) async {
    if (!isEnveloped(stored)) return stored; // legacy plaintext → passthrough
    try {
      final key = await _key();
      final blob = base64Decode(stored.substring(envelopePrefix.length));
      if (blob.length < _nonceLength + _macLength) return null;
      final nonce = blob.sublist(0, _nonceLength);
      final mac = blob.sublist(blob.length - _macLength);
      final cipherText = blob.sublist(_nonceLength, blob.length - _macLength);
      final clear = await _algorithm.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
        secretKey: key,
      );
      return utf8.decode(clear);
    } catch (e) {
      debugPrint('[SecureBlobCipher] descifrado falló: $e');
      return null;
    }
  }
}

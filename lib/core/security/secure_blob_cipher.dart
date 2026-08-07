import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
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
///     manipulación). Formato del sobre:
///     `enc:v2:<kid>:<base64(nonce|ct|mac)>`, donde `kid` es una huella corta
///     de la clave que lo selló. Se sigue leyendo el formato viejo
///     `enc:v1:<base64(...)>` (sin kid).
///
/// El `kid` existe para distinguir dos fallos que antes se veían iguales —
/// "SecretBox has wrong message authentication code" para ambos:
///   - blob manipulado/corrupto (el MAC no cuadra), y
///   - blob sellado con OTRA clave (típico tras un arranque en el que el
///     Keychain no estuvo disponible y se usó una clave efímera).
/// Con kid, el segundo caso se resuelve comparando 8 caracteres: [open]
/// devuelve null de una vez, sin intentar descifrar ni tirar excepción, y
/// avisa una sola vez por clave en vez de una vez por blob.
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

  /// Instancia aislada para tests. La clave se memoiza por instancia, así que
  /// un test puede simular "otro arranque" (otra clave, o Keychain caído)
  /// sin contaminar el singleton que usa el resto de la app.
  @visibleForTesting
  factory SecureBlobCipher.forTesting() = SecureBlobCipher._;

  /// Prefijo histórico, sin id de clave. Se sigue LEYENDO; ya no se escribe.
  static const String envelopePrefix = 'enc:v1:';

  /// Prefijo actual: `enc:v2:<kid>:<payload>`.
  static const String envelopePrefixV2 = 'enc:v2:';

  static const String _keyStorageKey = 'mp_offline_blob_key_v1';
  static const int _nonceLength = 12; // AES-GCM nonce estándar
  static const int _macLength = 16; // AES-GCM tag
  static const int _kidBytes = 6; // 8 chars base64url

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
    // macOS: el data-protection keychain (default) exige un access-group con
    // prefijo de Team. En builds ad-hoc/dev (CODE_SIGN_IDENTITY="-", sin
    // DEVELOPMENT_TEAM) ese prefijo no existe y el Keychain devuelve
    // errSecMissingEntitlement (-34018), rompiendo el sellado de la cola
    // offline (G9b). Usamos el keychain de archivo, accesible bajo App
    // Sandbox con la identidad propia de la app sin necesidad de Team.
    // Nota: el keychain de archivo emite prompts de ACL cuando la firma ad-hoc
    // cambia entre rebuilds; un "Deny" devuelve errSecUserCanceled (-128). El
    // blindaje de _loadOrCreateKey degrada con gracia en vez de tronar.
    mOptions: MacOsOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
      usesDataProtectionKeychain: false,
    ),
  );

  final AesGcm _algorithm = AesGcm.with256bits();
  Future<_ResolvedKey>? _keyFuture;

  /// Kids de los que ya avisamos. Sin esto, un arranque tras perder la clave
  /// escupe una línea de log por cada blob que se intenta abrir.
  final Set<String> _warnedKids = <String>{};

  // Memoiza la carga/creación de la clave para no pegarle al secure storage
  // en cada read/write y para evitar generar dos claves en una race.
  //
  // Deliberadamente NO se reintenta el Keychain a mitad de sesión: si el
  // arranque degradó a clave efímera, cambiar de clave en caliente dejaría
  // ilegible lo que esta misma sesión ya selló (borradores de mesa abiertos,
  // por ejemplo). El reintento ocurre naturalmente en el próximo arranque.
  Future<_ResolvedKey> _key() => _keyFuture ??= _loadOrCreateKey();

  /// `true` cuando la clave de esta sesión NO pudo persistirse (Keychain
  /// inaccesible). Todo lo que se selle con ella nace muerto: no sobrevive
  /// al reinicio. Lo consulta [sealDurable].
  Future<bool> get isEphemeralKey async => (await _key()).ephemeral;

  Future<_ResolvedKey> _loadOrCreateKey() async {
    String? existing;
    var ephemeral = false;
    try {
      existing = await _secureStorage.read(key: _keyStorageKey);
    } catch (e) {
      // Keychain inaccesible: macOS errSecUserCanceled (-128) si se canceló un
      // prompt de ACL, errSecMissingEntitlement (-34018) sin Team, o keychain
      // bloqueado. Degradamos a una clave efímera de sesión en vez de tronar el
      // arranque. Los blobs sellados con otra clave quedan ilegibles (open →
      // null, ya tolerado).
      debugPrint('[SecureBlobCipher] read de clave falló, uso efímera: $e');
      existing = null;
      ephemeral = true;
    }
    if (existing != null && existing.isNotEmpty) {
      try {
        return _ResolvedKey.of(base64Decode(existing), ephemeral: false);
      } catch (_) {
        // Clave corrupta: regeneramos. Los blobs viejos cifrados con la
        // clave perdida quedarán ilegibles (open → null), aceptable.
      }
    }
    final fresh = await _algorithm.newSecretKey();
    final bytes = await fresh.extractBytes();
    try {
      await _secureStorage.write(
        key: _keyStorageKey,
        value: base64Encode(bytes),
      );
    } catch (e) {
      // Si el write falla, seguimos con la clave en memoria para no tronar; no
      // sobrevivirá a un reinicio (se regenerará), aceptable frente a un crash.
      debugPrint('[SecureBlobCipher] write de clave falló, solo en memoria: $e');
      ephemeral = true;
    }
    return _ResolvedKey.of(bytes, ephemeral: ephemeral);
  }

  bool isEnveloped(String value) =>
      value.startsWith(envelopePrefixV2) || value.startsWith(envelopePrefix);

  /// Cifra [plaintext] y devuelve el sobre `enc:v2:<kid>:...`.
  Future<String> seal(String plaintext) async {
    final resolved = await _key();
    final nonce = _algorithm.newNonce();
    final box = await _algorithm.encrypt(
      utf8.encode(plaintext),
      secretKey: resolved.key,
      nonce: nonce,
    );
    final blob = <int>[...box.nonce, ...box.cipherText, ...box.mac.bytes];
    return '$envelopePrefixV2${resolved.kid}:${base64Encode(blob)}';
  }

  /// Sella [plaintext] SOLO si la clave va a sobrevivir al reinicio.
  ///
  /// Para datos que deben durar más que la sesión — el cuerpo de las
  /// operaciones de la cola offline — cifrar con una clave efímera es peor
  /// que no cifrar: el blob queda ilegible para siempre y la venta encolada
  /// se pierde en el replay. En ese caso devolvemos el texto en claro, que
  /// [open] lee sin problema (passthrough de legacy).
  ///
  /// Es un downgrade consciente de cifrado-en-reposo, acotado al caso en que
  /// el Keychain no está disponible, y solo para la cola: preferimos exponer
  /// datos en un equipo que el propio operador controla antes que perderle
  /// una venta. El roster y los snapshots siguen usando [seal] — su pérdida
  /// se recupera sincronizando.
  Future<String> sealDurable(String plaintext) async {
    final resolved = await _key();
    if (resolved.ephemeral) {
      if (_warnedKids.add('ephemeral-seal')) {
        debugPrint(
          '[SecureBlobCipher] clave sin persistir (Keychain no disponible): '
          'la cola offline se guarda SIN cifrar para no perder operaciones '
          'al reiniciar.',
        );
      }
      return plaintext;
    }
    return seal(plaintext);
  }

  /// Devuelve el texto en claro de [stored]:
  ///   - Si NO está cifrado (legacy en texto plano), lo devuelve tal cual.
  ///   - Si lo selló otra clave (kid distinto), null sin intentar descifrar.
  ///   - Si está cifrado con la nuestra, lo descifra; null si falla.
  Future<String?> open(String stored) async {
    if (!isEnveloped(stored)) return stored; // legacy plaintext → passthrough

    final resolved = await _key();
    String body;
    if (stored.startsWith(envelopePrefixV2)) {
      final rest = stored.substring(envelopePrefixV2.length);
      final sep = rest.indexOf(':');
      if (sep <= 0) return null; // sobre v2 malformado
      final kid = rest.substring(0, sep);
      if (kid != resolved.kid) {
        // Sellado con otra clave — típicamente un arranque previo sin
        // Keychain. No es corrupción: no tiene sentido intentar descifrar.
        if (_warnedKids.add(kid)) {
          debugPrint(
            '[SecureBlobCipher] hay datos sellados con otra clave '
            '(kid $kid, actual ${resolved.kid}): quedan ilegibles y se '
            'tratan como inexistentes. Se reescriben en el próximo guardado.',
          );
        }
        return null;
      }
      body = rest.substring(sep + 1);
    } else {
      body = stored.substring(envelopePrefix.length);
    }

    try {
      final blob = base64Decode(body);
      if (blob.length < _nonceLength + _macLength) return null;
      final nonce = blob.sublist(0, _nonceLength);
      final mac = blob.sublist(blob.length - _macLength);
      final cipherText = blob.sublist(_nonceLength, blob.length - _macLength);
      final clear = await _algorithm.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
        secretKey: resolved.key,
      );
      return utf8.decode(clear);
    } catch (e) {
      debugPrint('[SecureBlobCipher] descifrado falló: $e');
      return null;
    }
  }
}

/// Clave de sesión resuelta: la clave en sí, su huella corta (`kid`) y si
/// logró persistirse en el almacenamiento seguro.
class _ResolvedKey {
  _ResolvedKey({
    required this.key,
    required this.kid,
    required this.ephemeral,
  });

  final SecretKey key;
  final String kid;
  final bool ephemeral;

  /// El `kid` es un hash de la clave, no la clave: sirve para comparar sin
  /// exponer material criptográfico en el blob (que vive en disco en claro).
  factory _ResolvedKey.of(List<int> bytes, {required bool ephemeral}) {
    final digest = sha256.convert(bytes).bytes;
    final kid = base64Url
        .encode(digest.sublist(0, SecureBlobCipher._kidBytes))
        .replaceAll('=', '');
    return _ResolvedKey(
      key: SecretKey(bytes),
      kid: kid,
      ephemeral: ephemeral,
    );
  }
}

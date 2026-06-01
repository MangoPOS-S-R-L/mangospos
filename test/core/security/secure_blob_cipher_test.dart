import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/security/secure_blob_cipher.dart';

/// Tests del cifrado en reposo (G9). Mockea el canal de
/// flutter_secure_storage con un mapa en memoria para que la clave AES se
/// genere/persista sin tocar Keychain/Keystore reales.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final store = <String, String>{};

  setUp(() {
    store.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = (call.arguments as Map?) ?? const {};
      switch (call.method) {
        case 'write':
          store[args['key'] as String] = args['value'] as String;
          return null;
        case 'read':
          return store[args['key'] as String];
        case 'delete':
          store.remove(args['key']);
          return null;
        case 'containsKey':
          return store.containsKey(args['key']);
        case 'readAll':
          return Map<String, String>.from(store);
        case 'deleteAll':
          store.clear();
          return null;
      }
      return null;
    });
  });

  final cipher = SecureBlobCipher.instance;

  test('seal produce un sobre enc:v1: y open lo revierte (round-trip)',
      () async {
    const plaintext = '{"order":"local-123","total":1588.01,"cliente":"Ana"}';
    final sealed = await cipher.seal(plaintext);

    expect(cipher.isEnveloped(sealed), isTrue);
    expect(sealed.startsWith('enc:v1:'), isTrue);
    expect(sealed.contains(plaintext), isFalse); // no queda legible

    final opened = await cipher.open(sealed);
    expect(opened, plaintext);
  });

  test('open de un valor legacy en texto plano lo devuelve tal cual', () async {
    const legacy = '{"order":"viejo","total":10}';
    final opened = await cipher.open(legacy);
    expect(opened, legacy); // migración perezosa: passthrough
  });

  test('open de un sobre manipulado devuelve null (no lanza)', () async {
    final sealed = await cipher.seal('dato sensible');
    // Corromper el cuerpo base64 del sobre.
    final tampered = '${sealed.substring(0, sealed.length - 4)}AAAA';
    final opened = await cipher.open(tampered);
    expect(opened, isNull);
  });

  test('dos seals del mismo texto difieren (nonce aleatorio por valor)',
      () async {
    const plaintext = 'mismo contenido';
    final a = await cipher.seal(plaintext);
    final b = await cipher.seal(plaintext);
    expect(a, isNot(b)); // nonce distinto → ciphertext distinto
    expect(await cipher.open(a), plaintext);
    expect(await cipher.open(b), plaintext);
  });
}

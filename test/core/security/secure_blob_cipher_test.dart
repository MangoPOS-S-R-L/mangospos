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

  test('seal produce un sobre enc:v2:<kid>: y open lo revierte (round-trip)',
      () async {
    const plaintext = '{"order":"local-123","total":1588.01,"cliente":"Ana"}';
    final sealed = await cipher.seal(plaintext);

    expect(cipher.isEnveloped(sealed), isTrue);
    expect(sealed.startsWith('enc:v2:'), isTrue);
    // enc:v2:<kid>:<payload> → el kid va entre el prefijo y el cuerpo.
    expect(sealed.split(':')[2], isNotEmpty);
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

  test('un blob sellado con OTRA clave devuelve null por kid, sin excepción',
      () async {
    // Arranque 1: sella con la clave que hay en el Keychain.
    final antes = SecureBlobCipher.forTesting();
    final sealed = await antes.seal('{"order":"local-9","total":500}');
    final kidAntes = sealed.split(':')[2];

    // El Keychain pierde la clave (o el arranque anterior usó una efímera).
    store.clear();

    // Arranque 2: clave nueva → kid distinto → el blob viejo es ilegible,
    // pero no explota ni se confunde con corrupción.
    final despues = SecureBlobCipher.forTesting();
    expect(await despues.open(sealed), isNull);
    final propio = await despues.seal('x');
    expect(propio.split(':')[2], isNot(kidAntes));
    expect(await despues.open(propio), 'x');
  });

  group('clave efímera (Keychain caído)', () {
    late SecureBlobCipher sinKeychain;

    setUp(() {
      // read devuelve null y write revienta: es el caso macOS de firma
      // ad-hoc con prompt de ACL denegado (errSecUserCanceled).
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'write') {
          throw PlatformException(code: '-128', message: 'User canceled');
        }
        return null;
      });
      sinKeychain = SecureBlobCipher.forTesting();
    });

    test('se detecta como efímera', () async {
      expect(await sinKeychain.isEphemeralKey, isTrue);
    });

    test('sealDurable guarda en claro para no perder la operación', () async {
      const payload = '{"order_id":"o1","amount":1588.01}';
      final stored = await sinKeychain.sealDurable(payload);

      // Sin cifrar a propósito: cifrarlo con una clave que no sobrevive al
      // reinicio dejaría la venta encolada ilegible para siempre.
      expect(sinKeychain.isEnveloped(stored), isFalse);
      expect(stored, payload);
      // Y cualquier arranque posterior lo lee (passthrough de legacy).
      expect(await SecureBlobCipher.forTesting().open(stored), payload);
    });

    test('seal normal sí cifra: roster/snapshots se recuperan sincronizando',
        () async {
      final stored = await sinKeychain.seal('roster');
      expect(sinKeychain.isEnveloped(stored), isTrue);
      expect(await sinKeychain.open(stored), 'roster'); // legible en sesión
    });
  });

  test('con Keychain sano, sealDurable sí cifra', () async {
    final durable = SecureBlobCipher.forTesting();
    expect(await durable.isEphemeralKey, isFalse);

    const payload = '{"order_id":"o2","amount":10}';
    final stored = await durable.sealDurable(payload);
    expect(durable.isEnveloped(stored), isTrue);
    expect(stored.contains('1588'), isFalse);
    expect(await durable.open(stored), payload);
  });
}

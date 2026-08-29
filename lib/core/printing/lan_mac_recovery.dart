import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// Recovery de impresoras de red por MAC SIN agente local.
///
/// En escritorio (Windows/macOS) la captura de MAC y el escaneo de LAN los
/// hace el agente Node (`/api/printers/mac-for-ip`, `/resolve-by-mac`). En
/// Android no hay agente, así que este módulo replica esas dos operaciones
/// dentro de la app:
///
///   - [captureMacForIp]: averigua el MAC de la impresora que responde en
///     una IP. Primero `ip neigh` (tabla de vecinos del kernel — funciona en
///     la mayoría de los Android sin root; `/proc/net/arp` está bloqueado
///     desde Android 10), y si no, SNMP v1 GETNEXT sobre `ifPhysAddress`
///     (UDP 161, community `public`) que las térmicas de red típicas
///     (Epson, 3nStar, Xprinter, Bixolon) responden.
///   - [resolveIpByMac]: barre el /24 de cada interfaz local sondando el
///     puerto de impresión y compara el MAC de los candidatos que aceptan
///     conexión contra el MAC guardado. Devuelve la IP nueva si aparece.
///
/// Solo se activa en Android ([isSupported]); en el resto de plataformas el
/// caller sigue con el agente como hasta ahora. Sin dependencias nuevas.
class LanMacRecovery {
  LanMacRecovery._();

  /// Plataformas donde la app puede resolver MAC por su cuenta.
  ///
  /// Antes era solo Android, asumiendo que en escritorio siempre habria
  /// agente. En la practica una caja Windows con el agente detenido (o
  /// instalado sin el componente Agent) se quedaba SIN MAC para siempre: no
  /// se capturaba al agregar, ni tras imprimir, ni con "Probar impresion", y
  /// entonces el recovery por MAC nunca podia dispararse. Ahora el
  /// capturador nativo cubre tambien Windows/macOS/Linux via `arp`, y el
  /// agente queda como via preferente, no como unica.
  ///
  /// iOS queda fuera: no expone la tabla de vecinos a apps de terceros.
  static bool get isSupported =>
      !kIsWeb &&
      (Platform.isAndroid ||
          Platform.isWindows ||
          Platform.isMacOS ||
          Platform.isLinux);

  /// ifPhysAddress (1.3.6.1.2.1.2.2.1.6) — MAC por interfaz en MIB-2.
  static const List<int> _ifPhysAddressOid = [1, 3, 6, 1, 2, 1, 2, 2, 1, 6];

  // =========================================================================
  // Captura de MAC para una IP conocida
  // =========================================================================

  /// Devuelve el MAC (normalizado `aa:bb:cc:dd:ee:ff`) del dispositivo que
  /// vive en [ip], o null si no se pudo resolver. No lanza.
  static Future<String?> captureMacForIp(
    String ip, {
    int tcpPort = 9100,
  }) async {
    if (!isSupported) return null;
    final target = ip.trim();
    if (target.isEmpty) return null;

    // Tocar la IP por TCP primero: puebla/refresca la entrada del vecino en
    // el kernel para que `ip neigh` tenga algo que decir. Si el caller viene
    // de un print exitoso la entrada ya está caliente y esto es un no-op
    // rápido; si falla la conexión igual seguimos (SNMP no la necesita).
    try {
      final socket = await Socket.connect(
        target,
        tcpPort,
        timeout: const Duration(milliseconds: 700),
      );
      socket.destroy();
    } catch (_) {}

    final viaTable = await _macFromNeighborTable(target);
    if (viaTable != null) return viaTable;
    return _macViaSnmp(target);
  }

  /// Tabla de vecinos del sistema, con el comando que corresponda a cada
  /// plataforma. `ip neigh` en Android/Linux (en Android 10+ `/proc/net/arp`
  /// esta bloqueado, pero `ip` sigue funcionando sin root) y `arp` en
  /// Windows/macOS. Si el binario no existe o falla, devuelve null y el
  /// caller cae a SNMP.
  static Future<String?> _macFromNeighborTable(String ip) async {
    if (Platform.isAndroid || Platform.isLinux) {
      final viaNeigh = await _macFromIpNeigh(ip);
      if (viaNeigh != null) return viaNeigh;
    }
    return _macFromArp(ip);
  }

  /// `arp -a <ip>` (Windows) / `arp -n <ip>` (macOS, Linux).
  static Future<String?> _macFromArp(String ip) async {
    final args = Platform.isWindows ? ['-a', ip] : ['-n', ip];
    try {
      final result =
          await Process.run('arp', args).timeout(const Duration(seconds: 2));
      // En Windows `arp -a` de una IP sin entrada devuelve exitCode != 0; en
      // macOS imprime "no entry". Ambos casos caen a null via el parser.
      return parseArpOutput(result.stdout?.toString() ?? '', ip);
    } catch (_) {
      return null;
    }
  }

  /// Extrae el MAC de la linea de [ip] en la salida de `arp`. Publico para
  /// tests porque el formato cambia por plataforma e idioma del sistema:
  ///
  ///   Windows es:  `  192.168.1.50          00-11-22-33-44-55     dinamico`
  ///   macOS:       `? (192.168.1.50) at 0:11:22:33:44:55 on en0 ifscope`
  ///   Linux:       `192.168.1.50  ether  00:11:22:33:44:55  C  eth0`
  ///
  /// macOS omite el cero a la izquierda de cada grupo, asi que hay que
  /// rellenarlos antes de normalizar (si no, quedan 11 digitos y se
  /// descarta un MAC valido).
  @visibleForTesting
  static String? parseArpOutput(String output, String ip) {
    // Delimitar por la IP EXACTA: sin esto, buscar 192.168.1.5 casaba con la
    // linea de 192.168.1.50 y se guardaba el MAC de otro equipo.
    final ipPattern = RegExp(
      '(^|[^0-9.])${RegExp.escape(ip)}([^0-9.]|\$)',
    );
    final macPattern =
        RegExp(r'([0-9a-fA-F]{1,2}[:-]){5}[0-9a-fA-F]{1,2}');

    for (final line in const LineSplitter().convert(output)) {
      if (!ipPattern.hasMatch(line)) continue;
      final match = macPattern.firstMatch(line);
      if (match == null) continue;
      final groups = match.group(0)!.split(RegExp('[:-]'));
      final padded = groups.map((g) => g.padLeft(2, '0')).join(':');
      final normalized = normalizeMac(padded);
      if (normalized != null) return normalized;
    }
    return null;
  }

  /// Lee la tabla de vecinos del kernel vía `ip neigh show <ip>`.
  static Future<String?> _macFromIpNeigh(String ip) async {
    try {
      final result = await Process.run('ip', ['neigh', 'show', ip])
          .timeout(const Duration(seconds: 2));
      if (result.exitCode != 0) return null;
      return parseIpNeighOutput(result.stdout?.toString() ?? '');
    } catch (_) {
      // Binario ausente, permiso denegado, timeout — da igual: fallback SNMP.
      return null;
    }
  }

  /// Extrae el `lladdr` de la salida de `ip neigh show`. Público para tests.
  @visibleForTesting
  static String? parseIpNeighOutput(String output) {
    final match =
        RegExp(r'lladdr\s+([0-9a-fA-F:]{17})').firstMatch(output);
    if (match == null) return null;
    return normalizeMac(match.group(1));
  }

  // =========================================================================
  // Escaneo de la subred buscando un MAC
  // =========================================================================

  /// Barre los /24 de las interfaces locales buscando el dispositivo con
  /// [mac] escuchando en [tcpPort]. Devuelve su IP actual o null. No lanza.
  ///
  /// Coste típico: ~3s (sonda TCP de 254 hosts en lotes de 32) + un chequeo
  /// de MAC por candidato (los hosts con 9100 abierto suelen ser 1-3).
  static Future<String?> resolveIpByMac({
    required String mac,
    int tcpPort = 9100,
    String? excludeIp,
  }) async {
    if (!isSupported) return null;
    final wanted = normalizeMac(mac);
    if (wanted == null) return null;

    for (final subnetBase in await _localSubnetBases()) {
      final candidates = await _sweepOpenPort(
        subnetBase,
        tcpPort,
        excludeIp: excludeIp?.trim(),
      );
      for (final candidate in candidates) {
        final found = await _macFromNeighborTable(candidate) ??
            await _macViaSnmp(candidate);
        if (found == wanted) {
          debugPrint(
            '[LanMacRecovery] $wanted encontrado en $candidate',
          );
          return candidate;
        }
      }
    }
    return null;
  }

  /// Bases `/24` ("192.168.1.") de las interfaces IPv4 locales, sin
  /// loopback ni link-local. Normalmente una sola (wlan0).
  static Future<List<String>> _localSubnetBases() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      final bases = <String>{};
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (ip.startsWith('169.254.')) continue; // link-local, sin DHCP
          final lastDot = ip.lastIndexOf('.');
          if (lastDot <= 0) continue;
          bases.add(ip.substring(0, lastDot + 1));
        }
      }
      return bases.toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  /// Sondea `base1..254:port` por TCP en lotes y devuelve las IPs que
  /// aceptaron el handshake.
  static Future<List<String>> _sweepOpenPort(
    String base,
    int port, {
    String? excludeIp,
    int batchSize = 32,
    Duration timeout = const Duration(milliseconds: 350),
  }) async {
    final open = <String>[];
    final hosts = [
      for (var i = 1; i <= 254; i++)
        if ('$base$i' != excludeIp) '$base$i',
    ];
    for (var start = 0; start < hosts.length; start += batchSize) {
      final batch = hosts.sublist(start, min(start + batchSize, hosts.length));
      final results = await Future.wait(batch.map((ip) async {
        try {
          final socket = await Socket.connect(ip, port, timeout: timeout);
          socket.destroy();
          return ip;
        } catch (_) {
          return null;
        }
      }));
      open.addAll(results.whereType<String>());
    }
    return open;
  }

  // =========================================================================
  // SNMP v1 mínimo (solo GETNEXT de ifPhysAddress) — sin dependencias
  // =========================================================================

  /// Camina `ifPhysAddress.*` por GETNEXT hasta encontrar un MAC de 6 bytes
  /// no nulo. Las impresoras suelen tener 1-2 interfaces, así que esto
  /// resuelve en 1-2 requests.
  static Future<String?> _macViaSnmp(
    String ip, {
    Duration timeout = const Duration(milliseconds: 900),
  }) async {
    var oid = List<int>.of(_ifPhysAddressOid);
    for (var step = 0; step < 8; step++) {
      final reply = await _snmpGetNext(ip, oid, timeout: timeout);
      if (reply == null) return null;
      final (nextOid, value) = reply;
      // Fin del subárbol ifPhysAddress → no hay MAC que sacar.
      if (!_oidHasPrefix(nextOid, _ifPhysAddressOid)) return null;
      if (value != null && value.length == 6 && value.any((b) => b != 0)) {
        return normalizeMac(
          value.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':'),
        );
      }
      oid = nextOid; // interfaz sin MAC (loopback/ppp) — seguir caminando
    }
    return null;
  }

  static bool _oidHasPrefix(List<int> oid, List<int> prefix) {
    if (oid.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (oid[i] != prefix[i]) return false;
    }
    return true;
  }

  /// Un GETNEXT SNMPv1: devuelve (oid, valorOctetString?) del primer
  /// varbind de la respuesta, o null ante timeout/error/formato raro.
  static Future<(List<int>, Uint8List?)?> _snmpGetNext(
    String ip,
    List<int> oid, {
    required Duration timeout,
    String community = 'public',
    int port = 161,
  }) async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final requestId = Random().nextInt(0x7fffffff);
      final request = _encodeGetNext(requestId, community, oid);
      socket.send(request, InternetAddress(ip), port);

      final completer = Completer<Datagram?>();
      final sub = socket.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = socket!.receive();
          if (dg != null && !completer.isCompleted) completer.complete(dg);
        }
      });
      final datagram = await completer.future
          .timeout(timeout, onTimeout: () => null);
      await sub.cancel();
      if (datagram == null) return null;
      return _decodeGetResponse(datagram.data, requestId);
    } catch (_) {
      return null;
    } finally {
      socket?.close();
    }
  }

  // --- BER encode -----------------------------------------------------------

  static Uint8List _encodeGetNext(
    int requestId,
    String community,
    List<int> oid,
  ) {
    final varbind = _tlv(0x30, [
      ..._tlv(0x06, _encodeOidBody(oid)),
      ..._tlv(0x05, const []), // NULL
    ]);
    final pdu = _tlv(0xA1, [
      // GetNextRequest-PDU
      ..._encodeInt(requestId),
      ..._encodeInt(0), // error-status
      ..._encodeInt(0), // error-index
      ..._tlv(0x30, varbind),
    ]);
    return Uint8List.fromList(_tlv(0x30, [
      ..._encodeInt(0), // version = SNMPv1
      ..._tlv(0x04, community.codeUnits),
      ...pdu,
    ]));
  }

  static List<int> _tlv(int tag, List<int> content) =>
      [tag, ..._encodeLength(content.length), ...content];

  static List<int> _encodeLength(int length) {
    if (length < 0x80) return [length];
    final bytes = <int>[];
    var value = length;
    while (value > 0) {
      bytes.insert(0, value & 0xff);
      value >>= 8;
    }
    return [0x80 | bytes.length, ...bytes];
  }

  static List<int> _encodeInt(int value) {
    // Solo enteros no negativos (request-id, error fields, version).
    var bytes = <int>[];
    var v = value;
    do {
      bytes.insert(0, v & 0xff);
      v >>= 8;
    } while (v > 0);
    if (bytes.first & 0x80 != 0) bytes.insert(0, 0); // mantener positivo
    return _tlv(0x02, bytes);
  }

  static List<int> _encodeOidBody(List<int> oid) {
    final body = <int>[40 * oid[0] + oid[1]];
    for (final sub in oid.skip(2)) {
      if (sub < 0x80) {
        body.add(sub);
      } else {
        final chunk = <int>[];
        var v = sub;
        while (v > 0) {
          chunk.insert(0, (v & 0x7f) | 0x80);
          v >>= 7;
        }
        chunk[chunk.length - 1] &= 0x7f;
        body.addAll(chunk);
      }
    }
    return body;
  }

  // --- BER decode -----------------------------------------------------------

  /// Extrae (oid, valor) del primer varbind de un GetResponse. Devuelve null
  /// si el paquete no parsea, el request-id no coincide o viene con error.
  static (List<int>, Uint8List?)? _decodeGetResponse(
    Uint8List data,
    int expectedRequestId,
  ) {
    try {
      final msg = _BerReader(data).readSequence(0x30);
      msg.readInt(); // version
      msg.readBytes(0x04); // community
      final pdu = msg.readSequence(0xA2); // GetResponse-PDU
      final requestId = pdu.readInt();
      if (requestId != expectedRequestId) return null;
      final errorStatus = pdu.readInt();
      pdu.readInt(); // error-index
      if (errorStatus != 0) return null;
      final varbinds = pdu.readSequence(0x30);
      final first = varbinds.readSequence(0x30);
      final oid = _decodeOidBody(first.readBytes(0x06));
      final valueTag = first.peekTag();
      Uint8List? value;
      if (valueTag == 0x04) {
        value = first.readBytes(0x04);
      }
      return (oid, value);
    } catch (_) {
      return null;
    }
  }

  static List<int> _decodeOidBody(Uint8List body) {
    if (body.isEmpty) return const [];
    final oid = <int>[body[0] ~/ 40, body[0] % 40];
    var value = 0;
    for (var i = 1; i < body.length; i++) {
      value = (value << 7) | (body[i] & 0x7f);
      if (body[i] & 0x80 == 0) {
        oid.add(value);
        value = 0;
      }
    }
    return oid;
  }

  // =========================================================================
  // Utilidades
  // =========================================================================

  /// Normaliza cualquier formato de MAC (`AA-BB-..`, `aabb.ccdd.eeff`,
  /// `aa:bb:..`) a `aa:bb:cc:dd:ee:ff`. Null si no son 12 hex o es todo cero.
  static String? normalizeMac(String? raw) {
    if (raw == null) return null;
    final hex = raw.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toLowerCase();
    if (hex.length != 12) return null;
    if (hex == '000000000000') return null;
    final parts = <String>[
      for (var i = 0; i < 12; i += 2) hex.substring(i, i + 2),
    ];
    return parts.join(':');
  }
}

/// Cursor mínimo para leer estructuras BER (tag, longitud, contenido).
class _BerReader {
  _BerReader(this._data) : _offset = 0;

  final Uint8List _data;
  int _offset;

  int peekTag() => _data[_offset];

  _BerReader readSequence(int expectedTag) =>
      _BerReader(readBytes(expectedTag));

  int readInt() {
    final bytes = readBytes(0x02);
    var value = 0;
    for (final b in bytes) {
      value = (value << 8) | b;
    }
    return value;
  }

  Uint8List readBytes(int expectedTag) {
    final tag = _data[_offset];
    if (tag != expectedTag) {
      throw FormatException('BER: tag $tag, esperaba $expectedTag');
    }
    _offset++;
    var length = _data[_offset++];
    if (length & 0x80 != 0) {
      final count = length & 0x7f;
      length = 0;
      for (var i = 0; i < count; i++) {
        length = (length << 8) | _data[_offset++];
      }
    }
    final slice = Uint8List.sublistView(_data, _offset, _offset + length);
    _offset += length;
    return slice;
  }
}

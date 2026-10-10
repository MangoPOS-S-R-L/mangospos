import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// Injectable network operations. Production operations only open a TCP
/// connection, read neighbor entries, and read SNMP interface addresses;
/// they never send print data or change the printer/network configuration.
@visibleForTesting
class LanMacRecoveryIo {
  const LanMacRecoveryIo({
    required this.localIpv4Addresses,
    required this.probePort,
    required this.neighborMac,
    required this.snmpMacs,
  });

  final Future<List<String>> Function(Duration timeout) localIpv4Addresses;
  final Future<bool> Function(String ip, int port, Duration timeout) probePort;
  final Future<String?> Function(String ip, Duration timeout) neighborMac;
  final Future<List<String>> Function(String ip, Duration timeout) snmpMacs;
}

/// Native LAN identity discovery, including desktops without a Node agent.
/// iOS uses SNMP because it cannot read the operating system neighbor table.
/// No DHCP result is cached: every returned endpoint has a fresh TCP probe
/// and a matching hardware identity. A reachable IP alone is insufficient.
class LanMacRecovery {
  LanMacRecovery._();

  static bool get isSupported =>
      !kIsWeb &&
      (Platform.isAndroid ||
          Platform.isWindows ||
          Platform.isMacOS ||
          Platform.isLinux ||
          Platform.isIOS);

  static const List<int> _ifPhysAddressOid = [1, 3, 6, 1, 2, 1, 2, 2, 1, 6];
  static const int _probeConcurrency = 32;
  static const int _identityConcurrency = 4;
  static const int _maximumSubnets = 4;
  static const int _maximumCandidates = 32;
  static const Duration _probeTimeout = Duration(milliseconds: 350);
  static const Duration _identityTimeout = Duration(seconds: 2);

  static final _nativeIo = LanMacRecoveryIo(
    localIpv4Addresses: _localIpv4Addresses,
    probePort: _probePort,
    neighborMac: _macFromNeighborTable,
    snmpMacs: _macsViaSnmp,
  );

  /// Captures only a valid unicast hardware address. A neighbor-table entry
  /// is usable only after a successful TCP handshake. When SNMP contradicts
  /// the neighbor entry, neither identity is accepted. [expectedMac] can
  /// identify a known printer among several SNMP interface addresses when
  /// the platform cannot read its neighbor table. A different unambiguous
  /// observed identity is returned so callers can reject the endpoint.
  static Future<String?> captureMacForIp(
    String ip, {
    int tcpPort = 9100,
    String? expectedMac,
    Duration timeout = const Duration(seconds: 2),
    @visibleForTesting LanMacRecoveryIo? io,
  }) async {
    if (io == null && !isSupported) return null;
    final target = _ipv4(ip);
    final expected = normalizeMac(expectedMac);
    if (target == null ||
        !_validPort(tcpPort) ||
        (expectedMac != null && expected == null) ||
        timeout <= Duration.zero) {
      return null;
    }
    final operations = io ?? _nativeIo;
    final budget = _RecoveryBudget(timeout);
    final reachable =
        await budget.run(
          (limit) => operations.probePort(target, tcpPort, limit),
          maximum: const Duration(milliseconds: 700),
        ) ??
        false;
    return _identityForIp(
      target,
      operations,
      _RecoveryBudget(budget.cap(const Duration(milliseconds: 1200))),
      allowNeighbor: reachable,
      expectedMac: expected,
    );
  }

  /// Searches all attached private IPv4 /24s, retaining the configured print
  /// port. Hints only prioritize attached networks; they never add arbitrary
  /// remote ranges. [previousIp] is verified like any other candidate.
  ///
  /// Returns null on conflicting MACs, duplicate matching endpoints, an
  /// incomplete/time-limited scan, or excessive candidate networks/devices.
  static Future<String?> resolveIpByMac({
    required String mac,
    int tcpPort = 9100,
    String? excludeIp,
    String? previousIp,
    Iterable<String> subnetHints = const [],
    Duration timeout = const Duration(seconds: 12),
    @visibleForTesting LanMacRecoveryIo? io,
  }) async {
    if (io == null && !isSupported) return null;
    final wanted = normalizeMac(mac);
    if (wanted == null || !_validPort(tcpPort) || timeout <= Duration.zero) {
      return null;
    }
    final operations = io ?? _nativeIo;
    final budget = _RecoveryBudget(timeout);
    final addresses = await budget.run(
      operations.localIpv4Addresses,
      maximum: const Duration(seconds: 1),
    );
    if (addresses == null) return null;
    final local = addresses.map(_ipv4).whereType<String>().toSet();
    final attached = local.where(_isPrivateIpv4).map(_subnetBase).toSet();
    if (attached.isEmpty || attached.length > _maximumSubnets) return null;

    final excluded = _ipv4(excludeIp);
    final previous = _ipv4(previousIp);
    final bases = <String>{};
    for (final hint in [?previous, ...subnetHints]) {
      final hintIp = _ipv4(hint.endsWith('.') ? '${hint}1' : hint);
      if (hintIp != null && attached.contains(_subnetBase(hintIp))) {
        bases.add(_subnetBase(hintIp));
      }
    }
    bases.addAll(attached);
    final hosts = <String>[
      if (previous != null &&
          previous != excluded &&
          attached.contains(_subnetBase(previous)) &&
          !local.contains(previous))
        previous,
      for (final base in bases)
        for (var host = 1; host <= 254; host++)
          if ('$base$host' != excluded &&
              '$base$host' != previous &&
              !local.contains('$base$host'))
            '$base$host',
    ];
    final matches = <String>{};
    var candidateCount = 0;
    for (var start = 0; start < hosts.length; start += _probeConcurrency) {
      if (budget.expired) return null;
      final batch = hosts.sublist(
        start,
        min(start + _probeConcurrency, hosts.length),
      );
      final probes = await Future.wait(
        batch.map((ip) async {
          final open = await budget.run(
            (limit) => operations.probePort(ip, tcpPort, limit),
            maximum: _probeTimeout,
          );
          return open == true ? ip : null;
        }),
      );
      if (budget.expired) return null;
      final candidates = probes.whereType<String>().toList();
      candidateCount += candidates.length;
      if (candidateCount > _maximumCandidates) return null;
      for (
        var offset = 0;
        offset < candidates.length;
        offset += _identityConcurrency
      ) {
        final group = candidates.sublist(
          offset,
          min(offset + _identityConcurrency, candidates.length),
        );
        final identities = await Future.wait(
          group.map((ip) async {
            final identity = await _identityForIp(
              ip,
              operations,
              _RecoveryBudget(budget.cap(_identityTimeout)),
              allowNeighbor: true,
              expectedMac: wanted,
            );
            return identity == wanted ? ip : null;
          }),
        );
        matches.addAll(identities.whereType<String>());
        if (matches.length > 1 || budget.expired) return null;
      }
    }
    return matches.length == 1 ? matches.single : null;
  }

  static Future<String?> _identityForIp(
    String ip,
    LanMacRecoveryIo io,
    _RecoveryBudget budget, {
    required bool allowNeighbor,
    String? expectedMac,
  }) async {
    if (budget.expired) return null;
    final results = await Future.wait<Object?>([
      if (allowNeighbor)
        budget.run<String?>(
          (limit) => io.neighborMac(ip, limit),
          maximum: _identityTimeout,
        )
      else
        Future<String?>.value(null),
      budget.run<List<String>>(
        (limit) => io.snmpMacs(ip, limit),
        maximum: _identityTimeout,
      ),
    ]);
    final neighbor = normalizeMac(results[0] as String?);
    final reported = (results[1] as List<String>? ?? const <String>[])
        .map(normalizeMac)
        .whereType<String>()
        .toSet();
    if (neighbor != null) {
      if (reported.isNotEmpty && !reported.contains(neighbor)) return null;
      return neighbor;
    }
    if (expectedMac != null && reported.contains(expectedMac)) {
      return expectedMac;
    }
    return reported.length == 1 ? reported.single : null;
  }

  static Future<bool> _probePort(String ip, int port, Duration timeout) async {
    Socket? socket;
    try {
      socket = await Socket.connect(ip, port, timeout: timeout);
      return true;
    } catch (_) {
      return false;
    } finally {
      socket?.destroy();
    }
  }

  static Future<List<String>> _localIpv4Addresses(Duration timeout) async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      ).timeout(timeout);
      return [
        for (final iface in interfaces)
          ...iface.addresses.map((a) => a.address),
      ];
    } catch (_) {
      return const [];
    }
  }

  static Future<String?> _macFromNeighborTable(
    String ip,
    Duration timeout,
  ) async {
    if (Platform.isIOS) return null;
    final budget = _RecoveryBudget(timeout);
    if (Platform.isAndroid || Platform.isLinux) {
      final output = await _runCommand('ip', [
        'neigh',
        'show',
        ip,
      ], budget.remaining);
      final viaNeigh = parseIpNeighOutput(output ?? '', ip: ip);
      if (viaNeigh != null) return viaNeigh;
    }
    if (budget.expired) return null;
    final output = await _runCommand(
      'arp',
      Platform.isWindows ? ['-a', ip] : ['-n', ip],
      budget.remaining,
    );
    return parseArpOutput(output ?? '', ip);
  }

  /// Kill timed-out subprocesses; Future.timeout alone leaves Process.run
  /// running in the background on every repeated discovery attempt.
  static Future<String?> _runCommand(
    String command,
    List<String> arguments,
    Duration timeout,
  ) async {
    if (timeout <= Duration.zero) return null;
    final budget = _RecoveryBudget(timeout);
    Process? process;
    var finished = false;
    try {
      final started = Process.start(command, arguments);
      unawaited(
        started.then((value) {
          if (finished) value.kill();
        }, onError: (Object _) {}),
      );
      process = await started.timeout(budget.remaining);
      final output = await Future.wait<Object>([
        process.stdout.transform(systemEncoding.decoder).join(),
        process.stderr.drain<void>().then<Object>((_) => ''),
        process.exitCode,
      ]).timeout(budget.remaining);
      if (output[2] != 0) return null;
      return output[0] as String;
    } catch (_) {
      return null;
    } finally {
      finished = true;
      process?.kill();
    }
  }

  @visibleForTesting
  static String? parseArpOutput(String output, String ip) {
    final target = _ipv4(ip);
    if (target == null) return null;
    return _parseNeighborLines(output, ip: target, requireLladdr: false);
  }

  @visibleForTesting
  static String? parseIpNeighOutput(String output, {String? ip}) {
    final target = _ipv4(ip);
    if (ip != null && target == null) return null;
    return _parseNeighborLines(output, ip: target, requireLladdr: true);
  }

  static String? _parseNeighborLines(
    String output, {
    String? ip,
    required bool requireLladdr,
  }) {
    final ipPattern = ip == null
        ? null
        : RegExp('(^|[^0-9.])${RegExp.escape(ip)}([^0-9.]|\$)');
    final macPattern = RegExp(
      r'(^|[^0-9a-fA-F:.-])((?:[0-9a-fA-F]{1,2}[:-]){5}[0-9a-fA-F]{1,2})($|[^0-9a-fA-F:.-])',
    );
    final identities = <String>{};
    for (final line in const LineSplitter().convert(output)) {
      if (ipPattern != null && !ipPattern.hasMatch(line)) continue;
      if (RegExp(
        r'\b(FAILED|INCOMPLETE|STALE|DELAY|PROBE)\b',
        caseSensitive: false,
      ).hasMatch(line)) {
        continue;
      }
      final input = requireLladdr
          ? RegExp(
              r'\blladdr\s+(.+)',
              caseSensitive: false,
            ).firstMatch(line)?.group(1)
          : line;
      if (input == null) continue;
      final match = macPattern.firstMatch(input);
      if (match == null) continue;
      if (match.group(2)!.contains(':') && match.group(2)!.contains('-')) {
        continue;
      }
      final padded = match
          .group(2)!
          .split(RegExp('[:-]'))
          .map((group) => group.padLeft(2, '0'))
          .join(':');
      final normalized = normalizeMac(padded);
      if (normalized != null) identities.add(normalized);
    }
    return identities.length == 1 ? identities.single : null;
  }

  // SNMP v1, read-only GETNEXT of the MIB-2 interface hardware addresses.
  static Future<List<String>> _macsViaSnmp(String ip, Duration timeout) async {
    final budget = _RecoveryBudget(timeout);
    var oid = List<int>.of(_ifPhysAddressOid);
    final addresses = <String>{};
    for (var step = 0; step < 8 && !budget.expired; step++) {
      final reply = await _snmpGetNext(
        ip,
        oid,
        timeout: budget.cap(const Duration(milliseconds: 900)),
      );
      if (reply == null) break;
      final (nextOid, value) = reply;
      if (!_oidHasPrefix(nextOid, _ifPhysAddressOid)) break;
      if (_compareOid(nextOid, oid) <= 0) return const [];
      if (value != null && value.length == 6) {
        final mac = normalizeMac(
          value.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':'),
        );
        if (mac != null) addresses.add(mac);
      }
      oid = nextOid;
    }
    return addresses.toList(growable: false);
  }

  static bool _oidHasPrefix(List<int> oid, List<int> prefix) {
    if (oid.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (oid[i] != prefix[i]) return false;
    }
    return true;
  }

  static int _compareOid(List<int> a, List<int> b) {
    for (var i = 0; i < min(a.length, b.length); i++) {
      if (a[i] != b[i]) return a[i].compareTo(b[i]);
    }
    return a.length.compareTo(b.length);
  }

  static Future<(List<int>, Uint8List?)?> _snmpGetNext(
    String ip,
    List<int> oid, {
    required Duration timeout,
    String community = 'public',
    int port = 161,
  }) async {
    if (timeout <= Duration.zero) return null;
    final budget = _RecoveryBudget(timeout);
    RawDatagramSocket? socket;
    StreamSubscription<RawSocketEvent>? subscription;
    var finished = false;
    try {
      final binding = RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      unawaited(
        binding.then((value) {
          if (finished) value.close();
        }, onError: (Object _) {}),
      );
      socket = await binding.timeout(budget.remaining);
      final requestId = Random.secure().nextInt(0x7fffffff);
      final completer = Completer<(List<int>, Uint8List?)?>();
      subscription = socket.listen(
        (event) {
          if (event != RawSocketEvent.read) return;
          Datagram? datagram;
          while ((datagram = socket!.receive()) != null) {
            final reply = datagram!;
            if (reply.address.address != ip || reply.port != port) continue;
            final decoded = decodeSnmpGetResponse(
              reply.data,
              requestId,
              community: community,
            );
            if (decoded != null && !completer.isCompleted) {
              completer.complete(decoded);
            }
          }
        },
        onError: (Object _) {
          if (!completer.isCompleted) completer.complete(null);
        },
      );
      socket.send(
        _encodeGetNext(requestId, community, oid),
        InternetAddress(ip),
        port,
      );
      return await completer.future.timeout(
        budget.remaining,
        onTimeout: () => null,
      );
    } catch (_) {
      return null;
    } finally {
      finished = true;
      socket?.close();
      await subscription?.cancel();
    }
  }

  static Uint8List _encodeGetNext(
    int requestId,
    String community,
    List<int> oid,
  ) {
    final varbind = _tlv(0x30, [
      ..._tlv(0x06, _encodeOidBody(oid)),
      ..._tlv(0x05, const []),
    ]);
    final pdu = _tlv(0xA1, [
      ..._encodeInt(requestId),
      ..._encodeInt(0),
      ..._encodeInt(0),
      ..._tlv(0x30, varbind),
    ]);
    return Uint8List.fromList(
      _tlv(0x30, [
        ..._encodeInt(0),
        ..._tlv(0x04, community.codeUnits),
        ...pdu,
      ]),
    );
  }

  static List<int> _tlv(int tag, List<int> content) => [
    tag,
    ..._encodeLength(content.length),
    ...content,
  ];

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
    final bytes = <int>[];
    var v = value;
    do {
      bytes.insert(0, v & 0xff);
      v >>= 8;
    } while (v > 0);
    if (bytes.first & 0x80 != 0) bytes.insert(0, 0);
    return _tlv(0x02, bytes);
  }

  static List<int> _encodeOidBody(List<int> oid) {
    final body = <int>[40 * oid[0] + oid[1]];
    for (final sub in oid.skip(2)) {
      final chunk = <int>[sub & 0x7f];
      var v = sub >> 7;
      while (v > 0) {
        chunk.insert(0, (v & 0x7f) | 0x80);
        v >>= 7;
      }
      body.addAll(chunk);
    }
    return body;
  }

  @visibleForTesting
  static (List<int>, Uint8List?)? decodeSnmpGetResponse(
    Uint8List data,
    int expectedRequestId, {
    String community = 'public',
  }) {
    try {
      final envelope = _BerReader(data);
      final msg = envelope.readSequence(0x30);
      if (!envelope.atEnd || msg.readInt() != 0) return null;
      if (!listEquals(msg.readBytes(0x04), community.codeUnits)) return null;
      final pdu = msg.readSequence(0xA2);
      if (!msg.atEnd || pdu.readInt() != expectedRequestId) return null;
      final errorStatus = pdu.readInt();
      final errorIndex = pdu.readInt();
      if (errorStatus != 0 || errorIndex != 0) return null;
      final varbinds = pdu.readSequence(0x30);
      if (!pdu.atEnd) return null;
      final first = varbinds.readSequence(0x30);
      final oid = _decodeOidBody(first.readBytes(0x06));
      Uint8List? value;
      if (first.peekTag() == 0x04) {
        value = first.readBytes(0x04);
      } else {
        first.readBytes(first.peekTag());
      }
      if (!first.atEnd || !varbinds.atEnd) return null;
      return (oid, value);
    } catch (_) {
      return null;
    }
  }

  static List<int> _decodeOidBody(Uint8List body) {
    if (body.isEmpty) throw const FormatException('Empty OID');
    final first = body[0];
    final oid = <int>[
      min(first ~/ 40, 2),
      first < 80 ? first % 40 : first - 80,
    ];
    var value = 0;
    var unfinished = false;
    for (final byte in body.skip(1)) {
      value = (value << 7) | (byte & 0x7f);
      if (value > 0xffffffff) throw const FormatException('OID overflow');
      unfinished = byte & 0x80 != 0;
      if (!unfinished) {
        oid.add(value);
        value = 0;
      }
    }
    if (unfinished) throw const FormatException('Truncated OID');
    return oid;
  }

  /// Accepts six octets, Cisco notation, or exactly twelve hex digits.
  /// Rejects broadcast, multicast, all-zero, and embedded garbage; locally
  /// administered unicast addresses remain valid hardware identities.
  static String? normalizeMac(String? raw) {
    if (raw == null) return null;
    final input = raw.trim();
    final valid =
        RegExp(r'^(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$').hasMatch(input) ||
        RegExp(r'^(?:[0-9a-fA-F]{2}-){5}[0-9a-fA-F]{2}$').hasMatch(input) ||
        RegExp(r'^[0-9a-fA-F]{4}(?:\.[0-9a-fA-F]{4}){2}$').hasMatch(input) ||
        RegExp(r'^[0-9a-fA-F]{12}$').hasMatch(input);
    if (!valid) return null;
    final hex = input.replaceAll(RegExp(r'[:.-]'), '').toLowerCase();
    if (hex == '000000000000' ||
        (int.parse(hex.substring(0, 2), radix: 16) & 1) != 0) {
      return null;
    }
    return [for (var i = 0; i < 12; i += 2) hex.substring(i, i + 2)].join(':');
  }

  static bool _validPort(int port) => port > 0 && port <= 65535;

  static String? _ipv4(String? raw) {
    if (raw == null) return null;
    final input = raw.trim();
    if (!RegExp(r'^(?:\d{1,3}\.){3}\d{1,3}$').hasMatch(input)) return null;
    final octets = input.split('.').map(int.parse).toList();
    if (octets.any((value) => value > 255) ||
        octets.first == 0 ||
        octets.first == 127 ||
        octets.first >= 224) {
      return null;
    }
    return octets.join('.');
  }

  static bool _isPrivateIpv4(String ip) {
    final parts = ip.split('.').map(int.parse).toList();
    return parts[0] == 10 ||
        (parts[0] == 172 && parts[1] >= 16 && parts[1] <= 31) ||
        (parts[0] == 192 && parts[1] == 168);
  }

  static String _subnetBase(String ip) =>
      ip.substring(0, ip.lastIndexOf('.') + 1);
}

class _RecoveryBudget {
  _RecoveryBudget(this.duration) : _watch = Stopwatch()..start();
  final Duration duration;
  final Stopwatch _watch;
  Duration get remaining {
    final left = duration - _watch.elapsed;
    return left > Duration.zero ? left : Duration.zero;
  }

  bool get expired => remaining <= Duration.zero;
  Duration cap(Duration maximum) => remaining < maximum ? remaining : maximum;
  Future<T?> run<T>(
    Future<T> Function(Duration) operation, {
    required Duration maximum,
  }) async {
    final limit = cap(maximum);
    if (limit <= Duration.zero) return null;
    try {
      return await operation(limit).timeout(limit);
    } catch (_) {
      return null;
    }
  }
}

class _BerReader {
  _BerReader(this._data);
  final Uint8List _data;
  int _offset = 0;
  bool get atEnd => _offset == _data.length;
  int peekTag() => _data[_offset];
  _BerReader readSequence(int expectedTag) =>
      _BerReader(readBytes(expectedTag));

  int readInt() {
    final bytes = readBytes(0x02);
    if (bytes.isEmpty || bytes.length > 5 || bytes.first & 0x80 != 0) {
      throw const FormatException('Invalid nonnegative BER integer');
    }
    return bytes.fold(0, (value, byte) => (value << 8) | byte);
  }

  Uint8List readBytes(int expectedTag) {
    if (_data[_offset++] != expectedTag) throw const FormatException('BER tag');
    var length = _data[_offset++];
    if (length & 0x80 != 0) {
      final count = length & 0x7f;
      if (count == 0 || count > 4) throw const FormatException('BER length');
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

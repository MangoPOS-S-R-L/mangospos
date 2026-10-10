import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import '../../data/models/printing.dart';

class PrinterAddressChange {
  const PrinterAddressChange({
    required this.printerId,
    required this.businessId,
    required this.ipAddress,
    this.mac,
  });

  final String printerId;
  final String businessId;
  final String ipAddress;
  final String? mac;
}

class NetworkPrinterIdentityException implements Exception {
  const NetworkPrinterIdentityException(this.message);
  final String message;
  @override
  String toString() => message;
}

class _Address {
  const _Address(this.ip, this.mac, this.port);
  final String ip;
  final String? mac;
  final int port;

  Map<String, dynamic> toJson() => {'ip': ip, 'mac': mac, 'port': port};
}

/// Shared by receipt printing, kitchen dispatch and heartbeat. Disk entries are
/// candidates only: every use checks connectivity and the saved MAC again.
class NetworkPrinterRecoveryState {
  NetworkPrinterRecoveryState({this.persistLocally = true});
  static final shared = NetworkPrinterRecoveryState();
  final bool persistLocally;
  final _addresses = <String, _Address>{};
  final _loaded = <String>{};
  final _inFlight = <String, Future<String>>{};
  final _lastFailedScan = <String, DateTime>{};
  final _pendingSave = <String, _Address>{};
  final _remoteSaved = <String, _Address>{};
  final _lastSaveAttempt = <String, DateTime>{};
  final _generations = <String, int>{};
  final _changes = StreamController<PrinterAddressChange>.broadcast();
  Stream<PrinterAddressChange> get changes => _changes.stream;

  String _key(PrinterConfig printer) => '${printer.businessId}:${printer.id}';

  _Address? _validAddress(PrinterConfig printer) {
    final record = _addresses[_key(printer)];
    if (record == null || record.port != (printer.effectivePort ?? 9100)) {
      return null;
    }
    final expected = normalizeNetworkPrinterMac(printer.effectiveMac);
    if (expected != null && record.mac != expected) return null;
    return record;
  }

  String? knownIp(PrinterConfig printer) => _validAddress(printer)?.ip;
  String? knownMac(PrinterConfig printer) => _validAddress(printer)?.mac;

  Future<void> forgetPrinter(String printerId) async {
    bool matches(String key) => key.endsWith(':$printerId');
    for (final key in _generations.keys.where(matches)) {
      _generations[key] = _generations[key]! + 1;
    }
    _addresses.removeWhere((key, _) => matches(key));
    _loaded.removeWhere(matches);
    _pendingSave.removeWhere((key, _) => matches(key));
    _remoteSaved.removeWhere((key, _) => matches(key));
    _lastSaveAttempt.removeWhere((key, _) => matches(key));
    if (!persistLocally) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys().where(
        (key) => key.startsWith('printer_network_address_v1:') && matches(key),
      )) {
        await prefs.remove(key);
      }
    } catch (_) {}
  }

  Future<void> _load(PrinterConfig printer, int generation) async {
    final key = _key(printer);
    if (!persistLocally || !_loaded.add(key)) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString('printer_network_address_v1:$key');
      if (value == null) return;
      final json = jsonDecode(value);
      if (json is! Map || json['ip'] is! String || json['port'] is! int) return;
      final mac = normalizeNetworkPrinterMac(json['mac']?.toString());
      // A durable override without identity must never redirect a ticket.
      if (mac == null) return;
      if (_generations[key] != generation) return;
      _addresses.putIfAbsent(
        key,
        () => _Address(json['ip'], mac, json['port']),
      );
    } catch (_) {
      // Missing preferences plugin/storage does not prevent LAN printing.
    }
  }

  Future<void> _remember(
    PrinterConfig printer,
    _Address address, {
    int? generation,
  }) async {
    final key = _key(printer);
    final previous = _addresses[key];
    _addresses[key] = address;
    if (previous?.ip == address.ip && previous?.mac == address.mac) return;
    _changes.add(
      PrinterAddressChange(
        printerId: printer.id,
        businessId: printer.businessId,
        ipAddress: address.ip,
        mac: address.mac,
      ),
    );
    if (!persistLocally || address.mac == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (generation != null && _generations[key] != generation) return;
      await prefs.setString(
        'printer_network_address_v1:$key',
        jsonEncode(address.toJson()),
      );
    } catch (_) {}
  }
}

/// The I/O callbacks make DHCP changes and concurrent tickets testable without
/// scanning a real subnet or sending any print bytes.
class NetworkPrinterRecovery {
  NetworkPrinterRecovery({
    required this.probe,
    required this.captureMac,
    this.captureExpectedMac,
    required this.scan,
    required this.configuredIp,
    required this.save,
    NetworkPrinterRecoveryState? state,
    DateTime Function()? now,
  }) : state = state ?? NetworkPrinterRecoveryState.shared,
       now = now ?? DateTime.now;

  final Future<bool> Function(String ip, int port) probe;
  final Future<String?> Function(String ip, int port) captureMac;
  final Future<String?> Function(String ip, int port, String? expectedMac)?
  captureExpectedMac;
  final Future<String?> Function(
    String mac,
    String previousIp,
    int port,
    String printerId,
  )
  scan;
  final Future<String?> Function(PrinterConfig printer) configuredIp;
  final Future<void> Function(PrinterConfig printer, String ip, String? mac)
  save;
  final NetworkPrinterRecoveryState state;
  final DateTime Function() now;
  static const scanCooldown = Duration(seconds: 30);

  Future<void> rememberVerifiedAddress(
    PrinterConfig printer,
    String ip,
    String mac,
  ) async {
    final normalized = normalizeNetworkPrinterMac(mac);
    if (normalized == null) return;
    final address = _Address(ip, normalized, printer.effectivePort ?? 9100);
    await state._remember(printer, address);
    await _saveIfNeeded(printer, address);
  }

  Future<String> resolve({
    required PrinterConfig printer,
    required String cachedIp,
    bool allowScan = true,
    bool forceScan = false,
  }) {
    final identityKey = state._key(printer);
    final generation = state._generations.putIfAbsent(identityKey, () => 0);
    final key =
        '$identityKey:${printer.effectivePort ?? 9100}:${normalizeNetworkPrinterMac(printer.effectiveMac)}:$generation';
    final pending = state._inFlight[key];
    if (pending != null) return pending;
    final future = _resolve(
      printer,
      cachedIp.trim(),
      allowScan,
      forceScan,
      generation,
    );
    state._inFlight[key] = future;
    // Register both outcomes without creating an unhandled failed tail.
    future.then<void>(
      (_) {
        state._inFlight.remove(key);
      },
      onError: (Object _, StackTrace _) {
        state._inFlight.remove(key);
      },
    );
    return future;
  }

  Future<String> _resolve(
    PrinterConfig printer,
    String cachedIp,
    bool allowScan,
    bool forceScan,
    int generation,
  ) async {
    void ensureCurrent() {
      if (state._generations[state._key(printer)] != generation) {
        throw const NetworkPrinterIdentityException(
          'La configuración de la impresora cambió durante la recuperación.',
        );
      }
    }

    await state._load(printer, generation);
    ensureCurrent();
    final record = state._validAddress(printer);
    final expectedMac =
        normalizeNetworkPrinterMac(printer.effectiveMac) ?? record?.mac;
    final port = printer.effectivePort ?? 9100;
    final candidates = <String>{
      if (record != null) record.ip,
      if (cachedIp.isNotEmpty) cachedIp,
    };
    final identityConflicts = <String>{};

    Future<String?> validate(String ip) async {
      if (!await probe(ip, port)) return null;
      final actual = normalizeNetworkPrinterMac(
        await (captureExpectedMac == null
            ? captureMac(ip, port)
            : captureExpectedMac!(ip, port, expectedMac)),
      );
      if (expectedMac != null && actual != expectedMac) {
        if (actual != null) identityConflicts.add(ip);
        return null;
      }
      final address = _Address(ip, expectedMac ?? actual, port);
      ensureCurrent();
      await state._remember(printer, address, generation: generation);
      ensureCurrent();
      await _saveIfNeeded(printer, address);
      ensureCurrent();
      return ip;
    }

    if (!forceScan) {
      for (final ip in candidates) {
        final valid = await validate(ip);
        if (valid != null) return valid;
      }
      // WAN lookup is bounded by the repository. A DB address also needs MAC
      // verification; reaching a TCP port alone does not establish identity.
      final fresh = await configuredIp(printer);
      ensureCurrent();
      if (fresh != null &&
          fresh.trim().isNotEmpty &&
          candidates.add(fresh.trim())) {
        final valid = await validate(fresh.trim());
        if (valid != null) return valid;
      }
    }

    if (expectedMac != null && allowScan) {
      final scanKey = '${state._key(printer)}:$expectedMac:$port';
      final lastFailure = state._lastFailedScan[scanKey];
      if (lastFailure == null ||
          now().difference(lastFailure) >= scanCooldown) {
        // scan's implementations return only an identity-verified address.
        final found = await scan(expectedMac, cachedIp, port, printer.id);
        ensureCurrent();
        if (found != null && found.trim().isNotEmpty) {
          final valid = await validate(found.trim());
          if (valid != null) {
            state._lastFailedScan.remove(scanKey);
            return valid;
          }
        }
        state._lastFailedScan[scanKey] = now();
      }
    }

    if (expectedMac != null) {
      throw NetworkPrinterIdentityException(
        identityConflicts.isNotEmpty
            ? 'La IP guardada pertenece a otra impresora. No se encontró ${printer.name} por su MAC.'
            : 'No se pudo verificar la conexión de ${printer.name} por su MAC.',
      );
    }
    // Legacy printers without a MAC keep their normal connect/retry path.
    return cachedIp;
  }

  Future<void> _saveIfNeeded(PrinterConfig printer, _Address address) async {
    final key = state._key(printer);
    final acknowledged = state._remoteSaved[key];
    if (!state._pendingSave.containsKey(key) &&
        acknowledged?.ip == address.ip &&
        acknowledged?.mac == address.mac &&
        acknowledged?.port == address.port) {
      return;
    }
    if (address.ip != printer.effectiveIp ||
        (acknowledged != null &&
            (acknowledged.ip != address.ip ||
                acknowledged.mac != address.mac ||
                acknowledged.port != address.port)) ||
        (address.mac != null &&
            normalizeNetworkPrinterMac(printer.effectiveMac) != address.mac) ||
        state._pendingSave.containsKey(key)) {
      final priorAddress = state._pendingSave[key] ?? acknowledged;
      if (priorAddress != null && priorAddress.ip != address.ip) {
        state._lastSaveAttempt.remove(key);
      }
      state._pendingSave[key] = address;
    }
    final pending = state._pendingSave[key];
    if (pending == null) return;
    final previous = state._lastSaveAttempt[key];
    if (previous != null &&
        now().difference(previous) < const Duration(seconds: 30)) {
      return;
    }
    state._lastSaveAttempt[key] = now();
    try {
      await save(
        printer,
        pending.ip,
        pending.mac,
      ).timeout(const Duration(seconds: 2));
      state._remoteSaved[key] = pending;
      if (identical(state._pendingSave[key], pending)) {
        state._pendingSave.remove(key);
      }
    } on NetworkPrinterIdentityException {
      await state.forgetPrinter(printer.id);
      rethrow;
    } catch (_) {
      // Local address already saved; heartbeat will retry the WAN update.
    }
  }
}

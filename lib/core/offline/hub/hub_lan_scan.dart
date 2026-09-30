import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../printing/agent_discovery.dart';
import 'hub_config.dart' show kHubPortPrimary, kHubPortAlt;

/// Barrido TCP/HTTP **activo** de la LAN para encontrar el Hub Dart aunque
/// el mDNS no responda. En Mac el mDNS del
/// app dentro del sandbox suele fallar/quedar vacío, así que [AgentDiscovery]
/// solo (multicast pasivo) "no encuentra nada"; este barrido es el plan B que
/// usa la búsqueda de impresoras: conecta activamente a cada IP de la(s)
/// subred(es) locales y confirma que hay un MangoPOS detrás.
///
/// Estrategia por host (rápida): primero un `Socket.connect` con timeout corto
/// como puerta (los hosts muertos/puertos cerrados caen enseguida); solo si el
/// puerto abre se valida el JSON de `/hub/health`, no un agente de impresion.
class HubLanScanner {
  HubLanScanner({
    http.Client? httpClient,
    Duration? connectTimeout,
    Duration? httpTimeout,
    int? concurrency,
    Future<bool> Function(String, int)? portProbe,
    Future<List<String>> Function()? subnetProvider,
  }) : _http = httpClient ?? http.Client(),
       _connectTimeout = connectTimeout ?? const Duration(milliseconds: 400),
       _httpTimeout = httpTimeout ?? const Duration(milliseconds: 1200),
       _concurrency = concurrency ?? 48,
       _portProbe = portProbe,
       _subnetProvider = subnetProvider;

  final http.Client _http;
  final Duration _connectTimeout;
  final Duration _httpTimeout;
  final int _concurrency;
  final Future<bool> Function(String, int)? _portProbe;
  final Future<List<String>> Function()? _subnetProvider;

  void dispose() => _http.close();

  static const List<int> _ports = [kHubPortAlt, kHubPortPrimary];

  /// Bases /24 de las IPv4 propias del dispositivo, p. ej. `192.168.1`.
  Future<List<String>> localSubnetBases() async {
    if (_subnetProvider != null) return _subnetProvider();
    final bases = <String>{};
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final parts = addr.address.split('.');
          if (parts.length == 4) {
            bases.add('${parts[0]}.${parts[1]}.${parts[2]}');
          }
        }
      }
    } catch (e) {
      debugPrint('[HubLanScanner] no se pudieron listar interfaces: $e');
    }
    return bases.toList(growable: false);
  }

  /// Escanea la(s) subred(es) locales (más [extraSubnetBases] manuales como
  /// `192.168.100`). [onProgress] reporta (hosts revisados, total). Devuelve
  /// los equipos MangoPOS encontrados, dedupeados por IP.
  Future<List<DiscoveredAgent>> scan({
    List<String> extraSubnetBases = const [],
    void Function(int done, int total)? onProgress,
  }) async {
    final bases = <String>{
      ...await localSubnetBases(),
      ...extraSubnetBases.map((b) => b.trim()).where((b) => b.isNotEmpty),
    }.toList(growable: false);
    if (bases.isEmpty) return const [];

    final targets = <String>[
      for (final base in bases)
        for (var host = 1; host <= 254; host++) '$base.$host',
    ];

    final found = <String, DiscoveredAgent>{};
    final total = targets.length;
    var done = 0;

    // Pool cooperativo: los workers comparten un iterador. moveNext()/current
    // son síncronos (sin await entre medio) así que no hay carrera real en el
    // event loop de un solo isolate.
    final it = targets.iterator;
    Future<void> worker() async {
      while (it.moveNext()) {
        final ip = it.current;
        final agent = await _probeHost(ip);
        if (agent != null) {
          found[agent.ip ?? agent.host] = agent;
        }
        done++;
        onProgress?.call(done, total);
      }
    }

    final workerCount = _concurrency.clamp(1, total == 0 ? 1 : total);
    await Future.wait(List.generate(workerCount, (_) => worker()));
    return found.values.toList(growable: false);
  }

  Future<DiscoveredAgent?> _probeHost(String ip) async {
    for (final port in _ports) {
      if (!await _portOpen(ip, port)) continue;
      if (await _isHubEndpoint('http://$ip:$port')) {
        return DiscoveredAgent(
          name: 'Equipo $ip',
          host: ip,
          ip: ip,
          port: port,
        );
      }
    }
    return null;
  }

  Future<bool> _portOpen(String ip, int port) async {
    if (_portProbe != null) return _portProbe(ip, port);
    Socket? socket;
    try {
      socket = await Socket.connect(ip, port, timeout: _connectTimeout);
      return true;
    } catch (_) {
      return false;
    } finally {
      socket?.destroy();
    }
  }

  /// A print agent or an unrelated HTTP 200 is not evidence of a Hub.
  /// Business and authority are validated by HubClient before connecting.
  Future<bool> _isHubEndpoint(String baseUrl) async {
    try {
      final resp = await _http
          .get(Uri.parse('$baseUrl/hub/health'))
          .timeout(_httpTimeout);
      if (resp.statusCode != 200) return false;
      final body = jsonDecode(resp.body);
      return body is Map &&
          body['status'] == 'ok' &&
          const ['hub', 'hub_backup', 'pos'].contains(body['role']);
    } catch (_) {
      return false;
    }
  }
}

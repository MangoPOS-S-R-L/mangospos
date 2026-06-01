import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../printing/agent_discovery.dart';

/// Cliente del Hub Local (F3). En F3a solo hace el *handshake*: localizar un
/// Hub alcanzable en la LAN y confirmar que responde `/hub/health`. Las
/// operaciones (POST /hub/ops) y el feed (WS) llegan en F3b/F3c.
///
/// Estrategia de localización:
///   1. Si hay una URL de Hub configurada (deployment con primario fijo),
///      se prueba primero.
///   2. Si no, se descubre vía `AgentDiscovery` (mDNS, filtrado por negocio)
///      y se prueba cada candidato.
/// Devuelve la `baseUrl` del primer Hub que responde, o null.
class HubClient {
  HubClient({AgentDiscovery? discovery, http.Client? httpClient})
      : _discovery = discovery ?? AgentDiscovery(),
        _http = httpClient ?? http.Client();

  final AgentDiscovery _discovery;
  final http.Client _http;

  static const Duration _probeTimeout = Duration(seconds: 2);
  static const Duration _discoverTimeout = Duration(seconds: 3);
  static const Duration _opTimeout = Duration(seconds: 5);

  /// Token compartido del agente. Es el mismo hardcoded que usa el agente
  /// hoy; se reemplazará por un token por-negocio (del paquete de activación
  /// de F0) cuando se endurezca la seguridad LAN.
  static const String _apiToken = 'MANGOPOS_SECURE_TOKEN_123';

  Map<String, String> get _authHeaders => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_apiToken',
      };

  String _normalize(String baseUrl) =>
      baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;

  /// Localiza un Hub alcanzable. [configuredUrl] (opcional) es la dirección
  /// del primario designado; [businessId] filtra el descubrimiento mDNS.
  Future<String?> findReachableHub({
    String? businessId,
    String? configuredUrl,
  }) async {
    // 1. Primario configurado.
    if (configuredUrl != null && configuredUrl.trim().isNotEmpty) {
      final url = configuredUrl.trim();
      if (await _isHub(url)) return url;
    }

    // 2. Descubrimiento mDNS (encuentra el agente desktop, que sí se anuncia).
    try {
      final agents = await _discovery.discover(
        timeout: _discoverTimeout,
        businessIdFilter: businessId,
      );
      for (final agent in agents) {
        if (await _isHub(agent.baseUrl)) return agent.baseUrl;
      }
    } catch (e) {
      debugPrint('[HubClient] descubrimiento falló: $e');
    }
    return null;
  }

  /// Prueba `GET <baseUrl>/hub/health` y confirma que es un Hub (role=hub).
  Future<bool> _isHub(String baseUrl) async {
    try {
      final resp = await _http
          .get(Uri.parse('${_normalize(baseUrl)}/hub/health'))
          .timeout(_probeTimeout);
      if (resp.statusCode != 200) return false;
      final body = jsonDecode(resp.body);
      return body is Map && body['role'] == 'hub';
    } catch (_) {
      return false;
    }
  }

  /// Envía una operación al Hub (`POST /hub/ops`). [op] es la acción (mismo
  /// shape que `enqueueAction`) e incluye `business_id`. Devuelve el `seq`
  /// asignado por el Hub, o null si falló (el caller cae a la cola local).
  Future<int?> postOp(String baseUrl, Map<String, dynamic> op) async {
    try {
      final resp = await _http
          .post(
            Uri.parse('${_normalize(baseUrl)}/hub/ops'),
            headers: _authHeaders,
            body: jsonEncode(op),
          )
          .timeout(_opTimeout);
      if (resp.statusCode != 200) return null;
      final body = jsonDecode(resp.body);
      return body is Map ? (body['seq'] as num?)?.toInt() : null;
    } catch (e) {
      debugPrint('[HubClient] postOp falló: $e');
      return null;
    }
  }

  /// Lee el delta del op-log del Hub desde [since] (`GET /hub/state`).
  /// Devuelve `(seq, ops)` o null si falló.
  Future<({int seq, List<Map<String, dynamic>> ops})?> getStateSince(
    String baseUrl, {
    required String businessId,
    int since = 0,
  }) async {
    try {
      final uri = Uri.parse('${_normalize(baseUrl)}/hub/state').replace(
        queryParameters: {'business_id': businessId, 'since': '$since'},
      );
      final resp = await _http.get(uri, headers: _authHeaders).timeout(_opTimeout);
      if (resp.statusCode != 200) return null;
      final body = jsonDecode(resp.body);
      if (body is! Map) return null;
      final ops = ((body['ops'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(growable: false);
      return (seq: (body['seq'] as num?)?.toInt() ?? 0, ops: ops);
    } catch (e) {
      debugPrint('[HubClient] getStateSince falló: $e');
      return null;
    }
  }

  void dispose() => _http.close();
}

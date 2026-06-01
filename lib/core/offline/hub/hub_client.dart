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
    final normalized =
        baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    try {
      final resp = await _http
          .get(Uri.parse('$normalized/hub/health'))
          .timeout(_probeTimeout);
      if (resp.statusCode != 200) return false;
      final body = jsonDecode(resp.body);
      return body is Map && body['role'] == 'hub';
    } catch (_) {
      return false;
    }
  }

  void dispose() => _http.close();
}

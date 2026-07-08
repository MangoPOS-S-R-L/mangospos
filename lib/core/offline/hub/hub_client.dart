import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../printing/agent_discovery.dart';
import '../ncf_offline_allocator.dart';
import 'hub_config.dart' show kHubPortPrimary, kHubPortAlt;

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
    // 1. Primario configurado. Probamos la URL tal cual + el mismo host en los
    //    puertos 4000/4100 (Mac vs Windows) para no depender de la plataforma.
    if (configuredUrl != null && configuredUrl.trim().isNotEmpty) {
      for (final url in _hubCandidateUrls(configuredUrl)) {
        if (await _isHub(url)) return url;
      }
    }

    // 2. Descubrimiento mDNS (encuentra el agente desktop, que sí se anuncia).
    //    Probamos cada candidato en ambos puertos: el agente que se anuncia
    //    puede ser el de impresión (4000) mientras el Hub Dart vive en 4100.
    try {
      final agents = await _discovery.discover(
        timeout: _discoverTimeout,
        businessIdFilter: businessId,
      );
      for (final agent in agents) {
        for (final url in _hubCandidateUrls(agent.baseUrl)) {
          if (await _isHub(url)) return url;
        }
      }
    } catch (e) {
      debugPrint('[HubClient] descubrimiento falló: $e');
    }
    return null;
  }

  /// Expande una dirección de Hub (URL o IP, con o sin puerto) a los candidatos
  /// a probar: la dada tal cual (si trae puerto) + el mismo host en 4000 y 4100.
  List<String> _hubCandidateUrls(String configured) {
    var raw = configured.trim();
    if (!raw.contains('://')) raw = 'http://$raw';
    Uri uri;
    try {
      uri = Uri.parse(raw);
    } catch (_) {
      return [configured.trim()];
    }
    final host = uri.host;
    if (host.isEmpty) return [configured.trim()];
    final scheme = uri.scheme.isEmpty ? 'http' : uri.scheme;
    final out = <String>[];
    if (uri.hasPort) out.add('$scheme://$host:${uri.port}');
    for (final p in const [kHubPortPrimary, kHubPortAlt]) {
      final c = '$scheme://$host:$p';
      if (!out.contains(c)) out.add(c);
    }
    return out;
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

  /// H3: lee el estado del salón del Hub (`GET /hub/salon`) — las mesas
  /// ocupadas reconstruidas del op-log. Devuelve la lista de mesas (mapas) o
  /// null si falló. Es lo que el grid de una caja lee en modo hub en vez de
  /// `v_zone_table_status`.
  Future<List<Map<String, dynamic>>?> getSalon(
    String baseUrl, {
    required String businessId,
  }) async {
    try {
      final uri = Uri.parse('${_normalize(baseUrl)}/hub/salon').replace(
        queryParameters: {'business_id': businessId},
      );
      final resp =
          await _http.get(uri, headers: _authHeaders).timeout(_opTimeout);
      if (resp.statusCode != 200) return null;
      final body = jsonDecode(resp.body);
      if (body is! Map) return null;
      return ((body['tables'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(growable: false);
    } catch (e) {
      debugPrint('[HubClient] getSalon falló: $e');
      return null;
    }
  }

  /// H3: lee el detalle de una orden del Hub por `table_id` u `order_id`
  /// (`GET /hub/order`). Devuelve el mapa de la orden o null (no encontrada o
  /// error). Es el equivalente LAN de abrir una mesa ajena sin nube.
  Future<Map<String, dynamic>?> getOrder(
    String baseUrl, {
    required String businessId,
    String? tableId,
    String? orderId,
  }) async {
    try {
      final uri = Uri.parse('${_normalize(baseUrl)}/hub/order').replace(
        queryParameters: {
          'business_id': businessId,
          if (tableId != null && tableId.isNotEmpty) 'table_id': tableId,
          if (orderId != null && orderId.isNotEmpty) 'order_id': orderId,
        },
      );
      final resp =
          await _http.get(uri, headers: _authHeaders).timeout(_opTimeout);
      if (resp.statusCode != 200) return null;
      final body = jsonDecode(resp.body);
      if (body is! Map) return null;
      return Map<String, dynamic>.from(body);
    } catch (e) {
      debugPrint('[HubClient] getOrder falló: $e');
      return null;
    }
  }

  /// Paso 2 (proxy real-time): pide al Hub que ABRA una mesa contra Supabase
  /// con SU internet y devuelva el JSON crudo de `fn_open_table_and_load`
  /// (`POST /hub/proxy/open-table`). Devuelve el mapa crudo o null si el Hub
  /// no respondió / está offline (el caller cae al respaldo local).
  Future<Map<String, dynamic>?> proxyOpenTable(
    String baseUrl, {
    required String tableId,
    String? userId,
    int peopleCount = 1,
    String? openedByEmployeeId,
  }) async {
    try {
      final resp = await _http
          .post(
            Uri.parse('${_normalize(baseUrl)}/hub/proxy/open-table'),
            headers: _authHeaders,
            body: jsonEncode({
              'table_id': tableId,
              if (userId != null) 'user_id': userId,
              'people_count': peopleCount,
              if (openedByEmployeeId != null)
                'opened_by_employee_id': openedByEmployeeId,
            }),
          )
          .timeout(_opTimeout);
      if (resp.statusCode != 200) return null;
      final body = jsonDecode(resp.body);
      if (body is! Map) return null;
      return Map<String, dynamic>.from(body);
    } catch (e) {
      debugPrint('[HubClient] proxyOpenTable falló: $e');
      return null;
    }
  }

  /// Paso 2: pide al Hub que agregue un ítem REAL a la orden contra Supabase
  /// (`POST /hub/proxy/add-item`). Devuelve el id del ítem real, o null si el
  /// Hub no respondió (el caller cae al respaldo local/op-log).
  Future<String?> proxyAddItem(
    String baseUrl, {
    required String orderId,
    required String menuItemId,
    double quantity = 1,
    int checkPosition = 1,
    bool isTakeout = false,
    String? notes,
    List<Map<String, dynamic>> modifiers = const [],
    String? employeeId,
  }) async {
    try {
      final resp = await _http
          .post(
            Uri.parse('${_normalize(baseUrl)}/hub/proxy/add-item'),
            headers: _authHeaders,
            body: jsonEncode({
              'order_id': orderId,
              'menu_item_id': menuItemId,
              'quantity': quantity,
              'check_position': checkPosition,
              'is_takeout': isTakeout,
              if (notes != null) 'notes': notes,
              if (modifiers.isNotEmpty) 'modifiers': modifiers,
              if (employeeId != null) 'employee_id': employeeId,
            }),
          )
          .timeout(_opTimeout);
      if (resp.statusCode != 200) return null;
      final body = jsonDecode(resp.body);
      if (body is! Map) return null;
      final id = body['item_id']?.toString();
      return (id != null && id.isNotEmpty) ? id : null;
    } catch (e) {
      debugPrint('[HubClient] proxyAddItem falló: $e');
      return null;
    }
  }

  /// Pide al Hub el próximo NCF de una serie (`POST /hub/ncf/next`). El Hub
  /// es el asignador único en LAN, así que el número es secuencial y sin
  /// colisión entre cajas. Devuelve null si el rango se agotó (→ recibo
  /// provisional) o si el Hub no responde.
  Future<NcfAssignment?> allocateNcf(
    String baseUrl, {
    required String businessId,
    required NcfRange range,
  }) async {
    try {
      final resp = await _http
          .post(
            Uri.parse('${_normalize(baseUrl)}/hub/ncf/next'),
            headers: _authHeaders,
            body: jsonEncode({
              'business_id': businessId,
              'ncf_type': range.ncfType,
              'serie': range.serie,
              'prefix': range.prefix,
              'range_start': range.rangeStart,
              'range_end': range.rangeEnd,
              if (range.seedCurrent != null) 'seed_current': range.seedCurrent,
            }),
          )
          .timeout(_opTimeout);
      if (resp.statusCode != 200) return null;
      final b = jsonDecode(resp.body);
      if (b is! Map || b['exhausted'] == true) return null;
      final number = (b['number'] as num?)?.toInt();
      final ncf = b['ncf']?.toString();
      if (number == null || ncf == null) return null;
      return NcfAssignment(
        ncf: ncf,
        number: number,
        ncfType: range.ncfType,
        serie: range.serie,
      );
    } catch (e) {
      debugPrint('[HubClient] allocateNcf falló: $e');
      return null;
    }
  }

  void dispose() => _http.close();
}

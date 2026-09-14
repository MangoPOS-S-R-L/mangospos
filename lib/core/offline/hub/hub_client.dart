import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../printing/agent_discovery.dart';
import '../ncf_offline_allocator.dart';
import '../../storage/storage_service.dart';
import 'hub_config.dart' show kHubPortPrimary, kHubPortAlt;
import 'hub_lan_token.dart';

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

  /// Cabeceras con el token LAN del negocio activo.
  ///
  /// Antes iba una constante compilada, la misma para todos los locales del
  /// país: quien la sacara del binario podía hablarle al Hub de cualquier
  /// negocio. Ahora sale de `business_settings.lan_token` (migración
  /// 20260907_0010), con caída al legacy mientras dure el rollout. Ver
  /// [HubLanTokenService].
  Future<Map<String, String>> _headers() async => {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer ${await _resolveToken()}',
  };

  /// Token del negocio activo de ESTE equipo. La caja siempre habla con el Hub
  /// de su propio negocio, así que no hace falta pasarlo en cada llamada.
  static Future<String> _resolveToken() async {
    try {
      final storage = await StorageService.getInstance();
      final businessId = await storage.read(StorageKeys.activeBusinessId) ?? '';
      return HubLanTokenService.instance.tokenFor(businessId);
    } catch (_) {
      return kLegacyHubLanToken;
    }
  }

  String _normalize(String baseUrl) => baseUrl.endsWith('/')
      ? baseUrl.substring(0, baseUrl.length - 1)
      : baseUrl;

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
            headers: await _headers(),
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

  /// Dirección que aceptó la última réplica, por respaldo configurado. Evita
  /// volver a sondear los candidatos de puerto en cada op.
  final Map<String, String> _replicaUrlCache = <String, String>{};

  /// Hasta cuándo no se reintenta un respaldo que no respondió en ningún
  /// candidato.
  final Map<String, DateTime> _replicaDownUntil = <String, DateTime>{};

  /// Respiro tras un respaldo que no respondió en ningún puerto. La réplica es
  /// fire-and-forget: sin esto, con el respaldo apagado cada op del local
  /// dispararía varios sondeos de 2 s que se irían apilando.
  static const Duration _replicaBackoff = Duration(seconds: 30);

  /// H7: manda una op YA APLICADA al Hub de respaldo, conservando su `seq`.
  ///
  /// Sin esto, una op que el Hub acepta vive en UN SOLO disco: el terminal se
  /// desentiende (`enqueueAction` retorna en cuanto el Hub responde) y si ese
  /// equipo se rompe antes de subir, la venta se pierde — y de todas las cajas
  /// del local.
  ///
  /// [backupAddress] es lo que el operador escribió en Ajustes: normalmente una
  /// IP pelada (`192.168.1.51`). La primera versión la usaba tal cual
  /// (`Uri.parse('192.168.1.51/hub/replica')`): sin esquema ni puerto, cada
  /// réplica tronaba, el catch la registraba como "no crítica" y devolvía
  /// `false`. La replicación NUNCA funcionó con el valor que pedía la pantalla.
  /// Ahora se resuelve igual que el primario: la dirección tal cual si trae
  /// puerto, y el mismo host en 4000 (agente Dart en Mac/tablet) y 4100
  /// (servidor dedicado en Windows/Linux).
  ///
  /// Best-effort a propósito: el respaldo es red de seguridad, no dependencia.
  /// Si no responde, el primario opera normal; se pierde la protección, no la
  /// venta.
  Future<bool> replicateOp(String backupAddress, Map<String, dynamic> op) =>
      _postToBackup(backupAddress, '/hub/replica', op);

  /// H7: le avisa al respaldo qué operaciones YA SUBIERON a Supabase.
  ///
  /// Sin esto, al promover el respaldo subiría también lo que el Hub ya había
  /// subido antes de morir: sus réplicas no saben qué se subió y la BD no tiene
  /// llave de idempotencia → venta doble. Con el ack, el respaldo marca esas
  /// operaciones como completadas y las salta.
  ///
  /// [keepOrderIds] replica la poda del Hub: si viene, el respaldo conserva solo
  /// las ops de esas órdenes (las mesas aún abiertas). Si es null, el Hub no
  /// podó en esta vuelta y el respaldo tampoco.
  ///
  /// [upToSeq] es el tope de esa poda: el respaldo solo borra ops con `seq` ≤
  /// ese valor (las réplicas guardan el seq del Hub, así que significa lo mismo
  /// en los dos discos). Sin tope el respaldo no poda: borraría réplicas que
  /// llegaron después y que el Hub todavía no sube.
  ///
  /// Queda una ventana residual: si el Hub sube y muere antes de mandar el ack
  /// (segundos), el respaldo promovido repetiría esas ops. Es raro sobre raro, y
  /// va en la dirección visible — un duplicado se ve y se corrige; una venta
  /// perdida no se entera nadie.
  Future<bool> ackReplica(
    String backupAddress, {
    required String businessId,
    required Iterable<String> completedOpIds,
    Set<String>? keepOrderIds,
    int? upToSeq,
  }) {
    final payload = <String, dynamic>{
      'business_id': businessId,
      'completed_op_ids': completedOpIds.toList(growable: false),
    };
    if (keepOrderIds != null) {
      payload['keep_order_ids'] = keepOrderIds.toList(growable: false);
    }
    if (upToSeq != null) payload['up_to_seq'] = upToSeq;
    return _postToBackup(backupAddress, '/hub/replica/ack', payload);
  }

  /// POST al respaldo resolviendo su puerto como el primario (tal cual si trae
  /// puerto, y el mismo host en 4000 y 4100), recordando el que respondió y
  /// respetando el respiro cuando no responde en ninguno. La réplica y el ack
  /// comparten cache y respiro: si el respaldo está caído, los dos lo saltan.
  Future<bool> _postToBackup(
    String backupAddress,
    String path,
    Map<String, dynamic> body,
  ) async {
    final address = backupAddress.trim();
    if (address.isEmpty) return false;

    final downUntil = _replicaDownUntil[address];
    if (downUntil != null && DateTime.now().isBefore(downUntil)) return false;

    final cached = _replicaUrlCache[address];
    if (cached != null) {
      if (await _post(cached, path, body, _opTimeout)) return true;
      // Cambió de puerto (se reinstaló) o dejó de responder: re-sondear.
      _replicaUrlCache.remove(address);
    }

    for (final url in _hubCandidateUrls(address)) {
      if (url == cached) continue; // ya se probó arriba
      if (await _post(url, path, body, _probeTimeout)) {
        _replicaUrlCache[address] = url;
        _replicaDownUntil.remove(address);
        return true;
      }
    }

    _replicaDownUntil[address] = DateTime.now().add(_replicaBackoff);
    debugPrint(
      '[HubClient] el respaldo $address no aceptó $path en ningún puerto; '
      'reintento en ${_replicaBackoff.inSeconds}s (no crítico).',
    );
    return false;
  }

  Future<bool> _post(
    String baseUrl,
    String path,
    Map<String, dynamic> body,
    Duration timeout,
  ) async {
    try {
      final resp = await _http
          .post(
            Uri.parse('${_normalize(baseUrl)}$path'),
            headers: await _headers(),
            body: jsonEncode(body),
          )
          .timeout(timeout);
      return resp.statusCode == 200;
    } catch (_) {
      return false;
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
      final resp = await _http
          .get(uri, headers: await _headers())
          .timeout(_opTimeout);
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
      final uri = Uri.parse(
        '${_normalize(baseUrl)}/hub/salon',
      ).replace(queryParameters: {'business_id': businessId});
      final resp = await _http
          .get(uri, headers: await _headers())
          .timeout(_opTimeout);
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
      final resp = await _http
          .get(uri, headers: await _headers())
          .timeout(_opTimeout);
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
            headers: await _headers(),
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
            headers: await _headers(),
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
            headers: await _headers(),
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

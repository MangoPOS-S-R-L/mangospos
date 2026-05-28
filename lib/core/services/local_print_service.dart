import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../printing/agent_discovery.dart';
import 'agent_auth.dart';

class LocalPrintService {
  // NO INCLUIR PUERTOS RAW DE IMPRESORA AQUI (9100 JetDirect, 9101-9105
  // auxiliares). Si un printer LAN responde a HTTP GET /status sobre 9100
  // imprime el header como texto plano en papel térmico. Si el agente LAN
  // necesita correr en otro puerto, agrégalo explícitamente — pero NUNCA
  // en puertos de impresora.
  static const List<String> _baseUrls = [
    'http://127.0.0.1:4000',
    'http://localhost:4000',
    'http://127.0.0.1:3000',
    'http://localhost:3000',
  ];

  static const Duration _resolvedBaseUrlTtl = Duration(minutes: 10);
  static String? _sharedResolvedBaseUrl;
  static DateTime? _sharedResolvedBaseUrlAt;

  /// Cached agent URL loaded from business_settings.agent_url.
  static String? _dbAgentUrl;
  static DateTime? _dbAgentUrlAt;

  /// Sprint 2.2 — Cache de la última lista de hubs descubiertos vía mDNS
  /// para que la UI (sprint 2.3) pueda mostrar el selector sin reescanear.
  /// Se refresca on-demand via [discoverAndPrime].
  static List<DiscoveredAgent> _lastDiscovered = const [];
  static DateTime? _lastDiscoveredAt;

  String? _resolvedBaseUrl;
  DateTime? _resolvedBaseUrlAt;
  final String? _apiToken;

  LocalPrintService({String? apiToken}) : _apiToken = apiToken;

  /// Publish the agent URL to the DB so remote devices (tablets) can find it.
  static Future<void> publishAgentUrl(String agentUrl, String businessId) async {
    try {
      await Supabase.instance.client
          .from('business_settings')
          .update({'agent_url': agentUrl})
          .eq('business_id', businessId);
      _dbAgentUrl = agentUrl;
      _dbAgentUrlAt = DateTime.now();
      debugPrint('[LocalPrintService] Published agent URL: $agentUrl');
    } catch (e) {
      debugPrint('[LocalPrintService] Failed to publish agent URL: $e');
    }
  }

  /// Fetch the agent URL from business_settings (cached 5 min).
  static Future<String?> _fetchDbAgentUrl() async {
    if (_dbAgentUrl != null &&
        _dbAgentUrlAt != null &&
        DateTime.now().difference(_dbAgentUrlAt!) < const Duration(minutes: 5)) {
      return _dbAgentUrl;
    }
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return null;
      // Get business_id from user's active membership
      final membership = await Supabase.instance.client
          .from('user_businesses')
          .select('business_id')
          .eq('user_id', user.id)
          .limit(1)
          .maybeSingle();
      if (membership == null) return null;
      final businessId = membership['business_id']?.toString();
      if (businessId == null || businessId.isEmpty) return null;

      final row = await Supabase.instance.client
          .from('business_settings')
          .select('agent_url')
          .eq('business_id', businessId)
          .maybeSingle();
      final url = row?['agent_url']?.toString().trim();
      if (url != null && url.isNotEmpty) {
        _dbAgentUrl = url;
        _dbAgentUrlAt = DateTime.now();
        return url;
      }
    } catch (e) {
      debugPrint('[LocalPrintService] Failed to fetch agent URL from DB: $e');
    }
    return null;
  }

  Map<String, String> _headers({bool auth = true}) {
    if (!auth) return {'Content-Type': 'application/json'};
    final token = resolveAgentBearerToken(explicitToken: _apiToken);
    return {
      'Content-Type': 'application/json',
      if (token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  String _normalizePrinterId(String ip, [int port = 9100]) => '$ip:$port';

  String? _resolvePrinterId(Map<String, dynamic>? printer) {
    if (printer == null) return null;

    final explicitId = printer['id']?.toString().trim();
    if (explicitId != null && explicitId.isNotEmpty) {
      return explicitId;
    }

    final ip = printer['ip']?.toString().trim();
    if (ip != null && ip.isNotEmpty) {
      return _normalizePrinterId(
        ip,
        (printer['port'] as num?)?.toInt() ?? 9100,
      );
    }

    final devicePath = printer['device_path']?.toString().trim();
    if (devicePath != null && devicePath.isNotEmpty) {
      return devicePath;
    }

    final mac = printer['mac']?.toString().trim();
    if (mac != null && mac.isNotEmpty) {
      return mac;
    }

    return null;
  }

  bool _isLegacyAgentBaseUrl(String baseUrl) =>
      baseUrl.endsWith(':4000') || baseUrl.endsWith(':3000');

  void _log(String message) {
    debugPrint('[LocalPrintService] $message');
  }

  /// Cache key compartido con `PrintAgentDetector` (lib/services/
  /// print_agent_detector.dart). Hardcoded en ambos lados a proposito —
  /// son dos servicios de niveles distintos y no queremos un import
  /// cruzado solo por la constante. Si se cambia, cambiar tambien alla.
  static const String _agentUrlPrefsKey = 'print_agent_url';

  static void primeBaseUrl(String baseUrl) {
    final normalized = baseUrl.trim();
    if (normalized.isEmpty) return;
    _sharedResolvedBaseUrl = normalized;
    _sharedResolvedBaseUrlAt = DateTime.now();

    // Espejear al cache de SharedPrefs que `PrintAgentDetector` lee
    // como fast-path en `scanLocalFirst`. Sin esto, despues de un
    // update el `PrinterHeartbeatScheduler` escaneaba 4 puertos antes
    // de caer al cache que main.dart ya habia poblado en memoria.
    // Fire-and-forget: si la escritura no completa antes del primer
    // tick, peor caso es un escaneo en ese tick — los siguientes ya
    // ven el cache.
    unawaited(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_agentUrlPrefsKey, normalized);
        await prefs.setInt(
          '$_agentUrlPrefsKey:ts',
          DateTime.now().millisecondsSinceEpoch ~/ 1000,
        );
      } catch (e) {
        debugPrint('[LocalPrintService] mirror primeBaseUrl to prefs: $e');
      }
    }());
  }

  /// Sprint 2.2 — Lista del último scan mDNS (vacía si nunca se escaneó
  /// o si ningún hub respondió). La UI de selección (Sprint 2.3) la
  /// consume para mostrar opciones al cajero.
  static List<DiscoveredAgent> get lastDiscoveredAgents => _lastDiscovered;

  /// Sprint 2.2 — Timestamp del último scan mDNS. La UI lo usa para
  /// mostrar "última detección hace Xs" y para decidir si re-escanear.
  static DateTime? get lastDiscoveredAt => _lastDiscoveredAt;

  /// Sprint 2.2 — Escanea la LAN buscando print agents vía mDNS y, si
  /// encuentra exactamente uno (o uno del [businessIdFilter]), lo prima
  /// como baseUrl para que las próximas impresiones vayan directo sin
  /// volver a probar localhost. Si hay varios, NO prima — deja que la
  /// UI (Sprint 2.3) elija cuál usar.
  ///
  /// Retorna la lista descubierta. Resiliente: si mDNS falla, retorna
  /// `[]` y el flujo legacy de [_resolveBaseUrl] (DB / localhost) sigue
  /// funcionando.
  static Future<List<DiscoveredAgent>> discoverAndPrime({
    String? businessIdFilter,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    try {
      final agents = await AgentDiscovery().discover(
        timeout: timeout,
        businessIdFilter: businessIdFilter,
      );
      _lastDiscovered = agents;
      _lastDiscoveredAt = DateTime.now();

      if (agents.length == 1) {
        // Un solo hub en la LAN: auto-configurarse sin preguntar al cajero.
        primeBaseUrl(agents.first.baseUrl);
        debugPrint(
          '[LocalPrintService] mDNS auto-prime -> ${agents.first.baseUrl} '
          '(${agents.first.name})',
        );
      } else if (agents.isEmpty) {
        debugPrint(
          '[LocalPrintService] mDNS no encontró hubs. Cayendo a flujo legacy.',
        );
      } else {
        debugPrint(
          '[LocalPrintService] mDNS encontró ${agents.length} hubs. '
          'Esperando selección manual (Sprint 2.3).',
        );
      }
      return agents;
    } catch (e) {
      debugPrint('[LocalPrintService] discoverAndPrime falló: $e');
      return const [];
    }
  }

  static void clearPrimedBaseUrl() {
    _sharedResolvedBaseUrl = null;
    _sharedResolvedBaseUrlAt = null;
    unawaited(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_agentUrlPrefsKey);
        await prefs.remove('$_agentUrlPrefsKey:ts');
      } catch (_) {}
    }());
  }

  bool _isFreshResolvedUrl(String? baseUrl, DateTime? resolvedAt) {
    if (baseUrl == null || resolvedAt == null) return false;
    return DateTime.now().difference(resolvedAt) < _resolvedBaseUrlTtl;
  }

  void _rememberResolvedBaseUrl(String baseUrl) {
    final now = DateTime.now();
    _resolvedBaseUrl = baseUrl;
    _resolvedBaseUrlAt = now;
    _sharedResolvedBaseUrl = baseUrl;
    _sharedResolvedBaseUrlAt = now;
  }

  void _forgetResolvedBaseUrl(String? baseUrl) {
    if (_resolvedBaseUrl == baseUrl) {
      _resolvedBaseUrl = null;
      _resolvedBaseUrlAt = null;
    }
    if (_sharedResolvedBaseUrl == baseUrl) {
      clearPrimedBaseUrl();
    }
  }

  Future<void> warmup() async {
    await _resolveBaseUrl();
  }

  Future<String?> _resolveBaseUrl() async {
    final cached = _resolvedBaseUrl;
    if (_isFreshResolvedUrl(cached, _resolvedBaseUrlAt)) {
      return cached;
    }

    final sharedCached = _sharedResolvedBaseUrl;
    if (_isFreshResolvedUrl(sharedCached, _sharedResolvedBaseUrlAt)) {
      _resolvedBaseUrl = sharedCached;
      _resolvedBaseUrlAt = _sharedResolvedBaseUrlAt;
      return sharedCached;
    }

    // Try DB-stored agent URL first (enables tablets to find remote agent)
    final dbUrl = await _fetchDbAgentUrl();

    final candidates = <String>[
      if (cached != null && cached.isNotEmpty) cached,
      if (sharedCached != null &&
          sharedCached.isNotEmpty &&
          sharedCached != cached)
        sharedCached,
      // DB URL before localhost — critical for tablets that aren't on the same machine
      if (dbUrl != null &&
          dbUrl.isNotEmpty &&
          dbUrl != cached &&
          dbUrl != sharedCached)
        dbUrl,
      ..._baseUrls.where(
        (candidate) =>
            candidate != cached &&
            candidate != sharedCached &&
            candidate != dbUrl,
      ),
    ];

    for (final candidate in candidates) {
      if (await _isHealthy(candidate)) {
        _rememberResolvedBaseUrl(candidate);
        return candidate;
      }
    }
    _forgetResolvedBaseUrl(cached);
    _forgetResolvedBaseUrl(sharedCached);
    return null;
  }

  Future<bool> _isHealthy(String baseUrl) async {
    try {
      final statusResponse = await http
          .get(Uri.parse('$baseUrl/status'))
          .timeout(const Duration(seconds: 2));
      if (statusResponse.statusCode == 200) {
        return true;
      }
    } catch (_) {}

    try {
      final healthResponse = await http
          .get(Uri.parse('$baseUrl/health'))
          .timeout(const Duration(seconds: 2));
      if (healthResponse.statusCode != 200) return false;

      final data = json.decode(healthResponse.body);
      return data['status'] == 'ok' || data['status'] == 'online';
    } catch (_) {
      return false;
    }
  }

  /// Verificar si el agente local está corriendo
  Future<bool> isAgentAvailable() async {
    final baseUrl = await _resolveBaseUrl();
    final available = baseUrl != null;
    if (!available) {
      _log(
        'Local Agent not available on known local ports: ${_baseUrls.join(', ')}',
      );
    } else {
      _log('Local Agent detected at $_resolvedBaseUrl');
    }
    return available;
  }

  /// Verificar salud de múltiples impresoras
  /// NOTA: El agente actual no tiene endpoint de check masivo.
  /// Retornamos mapa vacío para no romper la UI.
  Future<Map<String, bool>> checkConnectivity(
    List<Map<String, dynamic>> printers,
  ) async {
    try {
      final baseUrl = await _resolveBaseUrl();
      if (baseUrl == null) return <String, bool>{};

      final response = await http.post(
        Uri.parse('$baseUrl/check-connectivity'),
        headers: _headers(),
        body: json.encode({'printers': printers}),
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final results = Map<String, bool>.from(data['results']);
        return results;
      }
      return {};
    } catch (e) {
      debugPrint('Error checking connectivity: $e');
      return {};
    }
  }

  /// Enviar trabajo de impresión al agente local actual.
  /// Normaliza payloads viejos/nuevos al contrato real del agente:
  /// POST /print { printerId, type, content }
  Future<bool> printJob(Map<String, dynamic> jobData) async {
    final baseUrl = await _resolveBaseUrl();
    if (baseUrl == null) {
      throw Exception(
        'No se puede conectar con el Agente Local. Asegurate de que esté ejecutándose.',
      );
    }

    try {
      final printer = jobData['printer'] as Map<String, dynamic>?;
      final printerId =
          (jobData['printerId']?.toString().trim().isNotEmpty == true
                  ? jobData['printerId'].toString().trim()
                  : _resolvePrinterId(printer))
              ?.toString();

      if (printerId == null || printerId.isEmpty) {
        throw Exception('Falta identificar la impresora destino (printerId).');
      }

      final dynamic rawContent = jobData['content'];
      String type = (jobData['type'] ?? 'text').toString();
      String content;

      if (rawContent is String) {
        content = rawContent;
      } else if (rawContent is Map<String, dynamic>) {
        final rawType = rawContent['type']?.toString();

        if (rawType == 'raw_base64' && rawContent['dataBase64'] != null) {
          content = rawContent['dataBase64'].toString();
          type = 'raw';
          _log(
            'Using local assigned printer route -> printerId=$printerId mode=raw_base64',
          );
        } else {
          final lines = <String>[];
          final title = rawContent['title']?.toString();
          final body = rawContent['body']?.toString();
          final extraLines = rawContent['lines'];

          if (title != null && title.isNotEmpty) lines.add(title);
          if (body != null && body.isNotEmpty) lines.add(body);
          if (extraLines is List) {
            lines.addAll(extraLines.map((e) => e.toString()));
          }

          content = lines.join('\n');
          type = 'text';
        }
      } else {
        throw Exception('Contenido de impresión inválido.');
      }

      final normalizedPayload = {
        'printerId': printerId,
        'type': type,
        'content': content,
      };

      final legacyPayload = {
        'id': jobData['id']?.toString().trim().isNotEmpty == true
            ? jobData['id'].toString()
            : 'LOCAL-${DateTime.now().millisecondsSinceEpoch}',
        'printerId': printerId,
        if (printer != null) 'printer': Map<String, dynamic>.from(printer),
        if (jobData['meta'] != null) 'meta': jobData['meta'],
        'content': type == 'raw'
            ? {'type': 'raw_base64', 'dataBase64': content}
            : {'type': 'text', 'title': '', 'body': content},
      };

      final payload = _isLegacyAgentBaseUrl(baseUrl)
          ? legacyPayload
          : normalizedPayload;

      _log(
        'POST $baseUrl/print -> printerId=$printerId type=$type '
        'contentLength=${content.length} legacy=${_isLegacyAgentBaseUrl(baseUrl)}',
      );

      final response = await http.post(
        Uri.parse('$baseUrl/print'),
        headers: _headers(),
        body: json.encode(payload),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        _log('Agent accepted print job -> response=${response.body}');
        return data['success'] == true;
      }

      String errorMsg = 'Error ${response.statusCode}';
      try {
        final body = json.decode(response.body);
        if (body['error'] != null) errorMsg = body['error'].toString();
      } catch (_) {
        if (response.body.isNotEmpty) errorMsg = response.body;
      }
      _log(
        'Agent rejected print job -> status=${response.statusCode} error=$errorMsg',
      );
      throw _toUserFriendlyError(errorMsg);
    } catch (e) {
      _forgetResolvedBaseUrl(baseUrl);
      _log('Error printing job: $e');
      if (e is Exception) rethrow;
      throw _toUserFriendlyError(e.toString());
    }
  }

  Future<bool> testPrint({required String ip, int port = 9100}) async {
    try {
      final baseUrl = await _resolveBaseUrl();
      if (baseUrl == null) return false;

      final printerId = _normalizePrinterId(ip, port);
      _log('POST $baseUrl/test-print -> printerId=$printerId');

      final response = await http.post(
        Uri.parse('$baseUrl/test-print'),
        headers: _headers(),
        body: json.encode({'printerId': printerId}),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        _log('Agent accepted test print -> response=${response.body}');
        return data['success'] == true;
      }

      String errorMsg = 'Error ${response.statusCode}';
      try {
        final body = json.decode(response.body);
        if (body['error'] != null) errorMsg = body['error'].toString();
      } catch (_) {
        if (response.body.isNotEmpty) errorMsg = response.body;
      }
      _log(
        'Agent rejected test print -> status=${response.statusCode} error=$errorMsg',
      );
      throw _toUserFriendlyError(errorMsg);
    } catch (e) {
      _forgetResolvedBaseUrl(_resolvedBaseUrl);
      _log('Error testing print: $e');
      if (e is Exception) rethrow;
      throw _toUserFriendlyError(e.toString());
    }
  }

  Future<void> printRawToAssignedPrinter({
    required Map<String, dynamic> printer,
    required List<int> data,
    String? jobId,
    Map<String, dynamic>? meta,
  }) async {
    final printerId = _resolvePrinterId(printer);
    if (printerId == null || printerId.isEmpty) {
      throw Exception(
        'La impresora USB/local no tiene un identificador utilizable para el Agente Local.',
      );
    }

    final success = await printJob({
      'id': jobId?.trim().isNotEmpty == true
          ? jobId!.trim()
          : 'RAW-${DateTime.now().millisecondsSinceEpoch}',
      'printerId': printerId,
      'printer': Map<String, dynamic>.from(printer),
      if (meta != null) 'meta': meta,
      'content': {'type': 'raw_base64', 'dataBase64': base64Encode(data)},
    });

    if (!success) {
      throw Exception('El agente local rechazó los datos RAW.');
    }
  }

  Future<bool> printRawData({
    required String ip,
    int port = 9100,
    required List<int> data,
  }) async {
    try {
      final baseUrl = await _resolveBaseUrl();
      if (baseUrl == null) {
        throw Exception(
          'No se puede conectar con el Agente Local. Asegurate de que esté ejecutándose.',
        );
      }

      final printerId = _normalizePrinterId(ip, port);
      final rawContent = base64Encode(data);
      final payload = _isLegacyAgentBaseUrl(baseUrl)
          ? {
              'id': 'RAW-${DateTime.now().millisecondsSinceEpoch}',
              'printerId': printerId,
              'printer': {
                'id': printerId,
                'type': 'network',
                'ip': ip,
                'port': port,
              },
              'content': {'type': 'raw_base64', 'dataBase64': rawContent},
            }
          : {'printerId': printerId, 'type': 'raw', 'content': rawContent};

      _log(
        'POST $baseUrl/print (raw) -> printerId=$printerId '
        'bytes=${data.length} legacy=${_isLegacyAgentBaseUrl(baseUrl)}',
      );

      final response = await http.post(
        Uri.parse('$baseUrl/print'),
        headers: _headers(),
        body: json.encode(payload),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        _log('Agent accepted raw print -> response=${response.body}');
        return data['success'] == true;
      } else {
        String errorMsg = 'Error ${response.statusCode}';
        try {
          final body = json.decode(response.body);
          if (body['error'] != null) {
            errorMsg = body['error'].toString();
          }
        } catch (_) {
          errorMsg = response.body.isNotEmpty ? response.body : errorMsg;
        }

        _log(
          'Agent rejected raw print -> status=${response.statusCode} error=$errorMsg',
        );
        throw _toUserFriendlyError(errorMsg);
      }
    } catch (e) {
      _forgetResolvedBaseUrl(_resolvedBaseUrl);
      _log('Error sending raw data: $e');

      if (e.toString().contains('SocketException') ||
          e.toString().contains('ClientException')) {
        throw Exception(
          'No se puede conectar con el Agente Local. Asegúrate de que esté ejecutándose.',
        );
      }
      if (e is Exception) rethrow;
      throw _toUserFriendlyError(e.toString());
    }
  }

  Exception _toUserFriendlyError(String errorMsg) {
    if (errorMsg.contains('ETIMEDOUT')) {
      return Exception(
        'No se pudo conectar a la impresora (Tiempo de espera agotado). Verifica que esté encendida y en la misma red.',
      );
    } else if (errorMsg.contains('ECONNREFUSED')) {
      return Exception(
        'La impresora rechazó la conexión. Verifica que la dirección IP sea correcta y que la impresora permita conexiones en el puerto 9100.',
      );
    } else if (errorMsg.contains('EHOSTUNREACH')) {
      return Exception(
        'La impresora es inalcanzable. Verifica que esté en la misma red Wi-Fi y que la IP sea correcta.',
      );
    } else if (errorMsg.contains('socket_error') ||
        errorMsg.contains('connect_error')) {
      return Exception(
        'Error de conexión con la impresora. Verifica el cable de red o la señal Wi-Fi.',
      );
    }

    // Limpiar mensajes redundantes del agente
    final cleanMsg = errorMsg
        .replaceFirst('Exception: ', '')
        .replaceFirst('Error: ', '')
        .trim();

    if (cleanMsg.contains('No se pudo abrir la impresora')) {
      return Exception(cleanMsg);
    }

    return Exception('Fallo la impresión: $cleanMsg');
  }

  /// Descubrir impresoras en la red
  Future<List<dynamic>> discoverPrinters() async {
    try {
      final baseUrl = await _resolveBaseUrl();
      if (baseUrl == null) return [];

      _log('GET $baseUrl/printers');
      final response = await http
          .get(Uri.parse('$baseUrl/printers'), headers: _headers())
          .timeout(const Duration(seconds: 12));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data is Map<String, dynamic> && data['items'] is List) {
          return data['items'] as List<dynamic>;
        }
        if (data is Map<String, dynamic> && data['discovered'] is List) {
          return data['discovered'] as List<dynamic>;
        }
        if (data is List) {
          return data;
        }
      }
      _log(
        'Agent rejected discover printers -> status=${response.statusCode} body=${response.body}',
      );
      return [];
    } catch (e) {
      _forgetResolvedBaseUrl(_resolvedBaseUrl);
      _log('Error discovering printers: $e');
      return [];
    }
  }

  // ===========================================================================
  // Printer auto-recovery via MAC (cuando la impresora cambia de IP por DHCP)
  // ===========================================================================

  /// POST /api/printers/mac-for-ip — captura el MAC de la impresora que está
  /// en la IP dada. Llamar UNA VEZ tras un print exitoso, si todavía no
  /// guardamos el MAC para esa impresora.
  ///
  /// Devuelve la MAC normalizada (lowercase, `:`) o null si el agente no
  /// está disponible / no pudo resolver.
  Future<String?> captureMacForIp(String ip) async {
    final baseUrl = await _resolveBaseUrl();
    if (baseUrl == null) return null;
    try {
      final res = await http
          .post(
            Uri.parse('$baseUrl/api/printers/mac-for-ip'),
            headers: _headers(),
            body: jsonEncode({'ip': ip}),
          )
          .timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        if (body is Map && body['mac'] is String) {
          return (body['mac'] as String).toLowerCase();
        }
      }
      _log('captureMacForIp $ip → status=${res.statusCode} body=${res.body}');
      return null;
    } catch (e) {
      _log('captureMacForIp $ip threw: $e');
      return null;
    }
  }

  /// POST /api/printers/resolve-by-mac — el agente escanea el LAN buscando
  /// el MAC dado y devuelve la IP actual. Llamar cuando un print directo
  /// falla y la impresora tiene MAC guardado.
  ///
  /// Devuelve la nueva IP o null si nadie respondió con ese MAC.
  Future<String?> resolveIpByMac({
    required String mac,
    String? printerId,
    // Si el caller acaba de fallar imprimiendo a la IP que el resolver
    // devolvió antes, debe pasar `skipCache: true` para forzar
    // re-resolución fresca (ARP + scan) en vez de recibir el mismo
    // valor stale del cache in-memory del agente.
    bool skipCache = false,
  }) async {
    final baseUrl = await _resolveBaseUrl();
    if (baseUrl == null) return null;
    try {
      final res = await http
          .post(
            Uri.parse('$baseUrl/api/printers/resolve-by-mac'),
            headers: _headers(),
            body: jsonEncode({
              'mac': mac,
              if (printerId != null) 'printerId': printerId,
              if (skipCache) 'skipCache': true,
            }),
          )
          // El scan del /24 puede tardar ~10s en peor caso (~250 IPs × ~40ms).
          // 18s da margen para LAN saturada sin colgar al cajero indefinido.
          .timeout(const Duration(seconds: 18));
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        if (body is Map && body['ip'] is String) {
          return body['ip'] as String;
        }
      }
      _log('resolveIpByMac $mac → status=${res.statusCode} body=${res.body}');
      return null;
    } catch (e) {
      _log('resolveIpByMac $mac threw: $e');
      return null;
    }
  }

  /// POST /api/printers/invalidate-mac-cache — fuerza al agente a olvidar
  /// la entrada cacheada para este MAC. El caller invoca esto cuando un
  /// print directo falla y planea recuperar IP por MAC, para que el
  /// próximo `resolveIpByMac` no devuelva la IP stale que acabamos de
  /// confirmar que no responde.
  ///
  /// Fire-and-forget — no bloquea el flow, errores se loggean nada más.
  Future<void> invalidateMacCache({required String mac}) async {
    final baseUrl = await _resolveBaseUrl();
    if (baseUrl == null) return;
    try {
      await http
          .post(
            Uri.parse('$baseUrl/api/printers/invalidate-mac-cache'),
            headers: _headers(),
            body: jsonEncode({'mac': mac}),
          )
          .timeout(const Duration(seconds: 3));
    } catch (e) {
      _log('invalidateMacCache $mac threw: $e');
    }
  }
}

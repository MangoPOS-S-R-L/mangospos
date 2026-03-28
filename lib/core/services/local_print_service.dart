import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

class LocalPrintService {
  static const String _defaultApiToken = String.fromEnvironment(
    'MANGOPOS_AGENT_TOKEN',
    defaultValue: 'MANGOPOS_SECURE_TOKEN_123',
  );

  static const List<String> _baseUrls = [
    'http://127.0.0.1:4000',
    'http://localhost:4000',
    'http://127.0.0.1:3000',
    'http://localhost:3000',
    'http://127.0.0.1:9100',
    'http://localhost:9100',
    'http://127.0.0.1:9105',
    'http://localhost:9105',
  ];

  String? _resolvedBaseUrl;
  final String? _apiToken;

  LocalPrintService({String? apiToken}) : _apiToken = apiToken;

  Map<String, String> _headers({bool auth = true}) => {
    'Content-Type': 'application/json',
    if (auth && (_apiToken ?? _defaultApiToken).isNotEmpty)
      'Authorization': 'Bearer ${_apiToken ?? _defaultApiToken}',
  };

  String _normalizePrinterId(String ip, [int port = 9100]) => '$ip:$port';

  void _log(String message) {
    debugPrint('[LocalPrintService] $message');
  }

  Future<String?> _resolveBaseUrl() async {
    final cached = _resolvedBaseUrl;
    if (cached != null && await _isHealthy(cached)) {
      return cached;
    }

    for (final candidate in _baseUrls) {
      if (await _isHealthy(candidate)) {
        _resolvedBaseUrl = candidate;
        return candidate;
      }
    }
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
      _log('Local Agent not available on known local ports: ${_baseUrls.join(', ')}');
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
      final printerId = (jobData['printerId'] ??
              printer?['id'] ??
              (printer != null && printer['ip'] != null
                  ? _normalizePrinterId(
                      printer['ip'].toString(),
                      (printer['port'] as num?)?.toInt() ?? 9100,
                    )
                  : null))
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
          _log('Using local assigned printer route -> printerId=$printerId mode=raw_base64');
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

      _log('POST $baseUrl/print -> printerId=$printerId type=$type contentLength=${content.length}');

      final response = await http.post(
        Uri.parse('$baseUrl/print'),
        headers: _headers(),
        body: json.encode(normalizedPayload),
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
      _log('Agent rejected print job -> status=${response.statusCode} error=$errorMsg');
      throw Exception(errorMsg);
    } catch (e) {
      _log('Error printing job: $e');
      rethrow;
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
      _log('Agent rejected test print -> status=${response.statusCode} error=$errorMsg');
      throw Exception(errorMsg);
    } catch (e) {
      _log('Error testing print: $e');
      return false;
    }
  }

  /// Enviar datos RAW (base64) directo a /api/printers/raw
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
      final payload = {
        'printerId': printerId,
        'type': 'raw',
        'content': base64Encode(data),
      };

      _log('POST $baseUrl/print (raw) -> printerId=$printerId bytes=${data.length}');

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
        // Intentar parsear el error del agente
        String errorMsg = 'Error ${response.statusCode}';
        try {
          final body = json.decode(response.body);
          if (body['error'] != null) {
            errorMsg = body['error'].toString();
          }
        } catch (_) {
          errorMsg = response.body.isNotEmpty ? response.body : errorMsg;
        }

        if (errorMsg.contains('ETIMEDOUT')) {
          throw Exception(
            'No se pudo conectar a la impresora (Tiempo de espera agotado). Verifica que esté encendida y en la misma red.',
          );
        } else if (errorMsg.contains('ECONNREFUSED')) {
          throw Exception(
            'La impresora rechazó la conexión. Verifica la IP y el puerto.',
          );
        } else if (errorMsg.contains('EHOSTUNREACH')) {
          throw Exception(
            'La impresora no es inalcanzable. Verifica la IP y la red.',
          );
        }

        _log('Agent rejected raw print -> status=${response.statusCode} error=$errorMsg');
        throw Exception('El agente rechazó la impresión: $errorMsg');
      }
    } catch (e) {
      _log('Error sending raw data: $e');
      if (e.toString().contains('SocketException') ||
          e.toString().contains('ClientException')) {
        throw Exception(
          'No se puede conectar con el Agente Local. Asegúrate de que esté ejecutándose.',
        );
      }
      rethrow;
    }
  }

  /// Descubrir impresoras en la red
  Future<List<dynamic>> discoverPrinters() async {
    try {
      final baseUrl = await _resolveBaseUrl();
      if (baseUrl == null) return [];

      _log('GET $baseUrl/printers');
      final response = await http
          .get(
            Uri.parse('$baseUrl/printers'),
            headers: _headers(),
          )
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
      _log('Agent rejected discover printers -> status=${response.statusCode} body=${response.body}');
      return [];
    } catch (e) {
      _log('Error discovering printers: $e');
      return [];
    }
  }
}

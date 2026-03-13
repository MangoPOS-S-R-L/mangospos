import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

class LocalPrintService {
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
      debugPrint('Local Agent not available on known local ports.');
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
        headers: {'Content-Type': 'application/json'},
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

  /// Enviar trabajo de impresión directo
  /// NOTA: El agente nuevo usa /api/printers/raw o /api/printers/test
  Future<bool> printJob(Map<String, dynamic> jobData) async {
    final baseUrl = await _resolveBaseUrl();
    if (baseUrl == null) {
      throw Exception(
        'No se puede conectar con el Agente Local. Asegurate de que esté ejecutándose.',
      );
    }

    // Si es un test, usamos el endpoint de test
    if (jobData['id'] != null && jobData['id'].toString().startsWith('TEST-')) {
      final printer = jobData['printer'] as Map<String, dynamic>?;
      if (printer != null) {
        final ip = printer['ip'];
        final port = printer['port'] ?? 9100;
        return testPrint(ip: ip, port: port);
      }
    }

    // Para otros jobs, asumimos que deberían ir por raw o relay.
    // Como fallback, intentamos enviarlo a la ruta antigua /print
    // pero muy probablemente falle si el agente no la tiene.
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/print'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(jobData),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['success'] == true;
      }
      return false;
    } catch (e) {
      debugPrint('Error printing job (legacy): $e');
      // No lanzamos excepción para permitir fallbacks
      return false;
    }
  }

  Future<bool> testPrint({required String ip, int port = 9100}) async {
    try {
      final baseUrl = await _resolveBaseUrl();
      if (baseUrl == null) return false;
      final response = await http.post(
        Uri.parse('$baseUrl/api/printers/test'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'ip': ip, 'port': port}),
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['ok'] == true;
      }
      if (response.statusCode == 404 || response.statusCode == 405) {
        return await printJob({
          'id': 'TEST-${DateTime.now().millisecondsSinceEpoch}',
          'printer': {'type': 'network', 'ip': ip, 'port': port},
          'content': {
            'title': 'Test de Impresión',
            'body': 'Si lees esto, el Agente Local funciona correctamente.',
          },
        });
      }
      return false;
    } catch (e) {
      debugPrint('Error testing print: $e');
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

      final payload = {
        'ip': ip,
        'port': port,
        'dataBase64': base64Encode(data),
      };

      final response = await http.post(
        Uri.parse('$baseUrl/api/printers/raw'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(payload),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['ok'] == true;
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

        throw Exception('El agente rechazó la impresión: $errorMsg');
      }
    } catch (e) {
      debugPrint('Error sending raw data: $e');
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

      final response = await http
          .get(Uri.parse('$baseUrl/api/printers/discover'))
          .timeout(const Duration(seconds: 15));

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
      return [];
    } catch (e) {
      debugPrint('Error discovering printers: $e');
      return [];
    }
  }
}

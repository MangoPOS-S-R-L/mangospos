import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

class LocalPrintService {
  static const String _baseUrl = 'http://localhost:3000';

  /// Verificar si el agente local está corriendo
  Future<bool> isAgentAvailable() async {
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/health'))
          .timeout(const Duration(seconds: 2));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['status'] == 'ok';
      }
      return false;
    } catch (e) {
      debugPrint('Local Agent not available: $e');
      return false;
    }
  }

  /// Verificar salud de múltiples impresoras
  /// NOTA: El agente actual no tiene endpoint de check masivo.
  /// Retornamos mapa vacío para no romper la UI.
  Future<Map<String, bool>> checkConnectivity(
    List<Map<String, dynamic>> printers,
  ) async {
    return <String, bool>{};
    /*
    // Legacy implementation
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/check-connectivity'),
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
    */
  }

  /// Enviar trabajo de impresión directo
  /// NOTA: El agente nuevo usa /api/printers/raw o /api/printers/test
  Future<bool> printJob(Map<String, dynamic> jobData) async {
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
        Uri.parse('$_baseUrl/print'),
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
      final response = await http.post(
        Uri.parse('$_baseUrl/api/printers/test'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'ip': ip, 'port': port}),
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['ok'] == true;
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
      final payload = {
        'ip': ip,
        'port': port,
        'dataBase64': base64Encode(data),
      };

      final response = await http.post(
        Uri.parse('$_baseUrl/api/printers/raw'),
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
          'No se puede conectar con el Agente Local (Puerto 3000). Asegúrate de que esté ejecutándose.',
        );
      }
      rethrow;
    }
  }

  /// Descubrir impresoras en la red
  Future<List<dynamic>> discoverPrinters() async {
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/api/printers/discover'))
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['items'] as List<dynamic>;
      }
      return [];
    } catch (e) {
      debugPrint('Error discovering printers: $e');
      return [];
    }
  }
}

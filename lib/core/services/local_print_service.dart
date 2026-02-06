import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

class LocalPrintService {
  static const String _baseUrl = 'http://localhost:4000';

  /// Verificar si el agente local está corriendo
  Future<bool> isAgentAvailable() async {
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/status'))
          .timeout(const Duration(seconds: 2));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['status'] == 'online';
      }
      return false;
    } catch (e) {
      debugPrint('Local Agent not available: $e');
      return false;
    }
  }

  /// Verificar salud de múltiples impresoras
  Future<Map<String, bool>> checkConnectivity(
    List<Map<String, dynamic>> printers,
  ) async {
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
  }

  /// Enviar trabajo de impresión directo
  Future<bool> printJob(Map<String, dynamic> jobData) async {
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
      debugPrint('Error printing job: $e');
      throw Exception('Failed to communicate with Local Agent');
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
      }
      return false;
    } catch (e) {
      debugPrint('Error sending raw data: $e');
      throw Exception('Failed to communicate with Local Agent');
    }
  }
}

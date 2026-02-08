import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import '../../core/printing/print_driver.dart';
import '../../core/printing/print_job.dart';

/// Driver that communicates with the MangoPOS LAN Print Agent
class AgentPrintDriver implements PrintDriver {
  static const String _defaultUrl =
      'http://localhost:9100'; // Default Agent Port
  final String agentUrl;
  final String? apiToken;

  AgentPrintDriver({this.agentUrl = _defaultUrl, this.apiToken});

  @override
  String get id => 'agent';

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    if (apiToken != null) 'Authorization': 'Bearer $apiToken',
  };

  @override
  Future<bool> isAvailable() async {
    try {
      final response = await http
          .get(Uri.parse('$agentUrl/status'), headers: _headers)
          .timeout(const Duration(seconds: 2));

      return response.statusCode == 200;
    } catch (e) {
      debugPrint('Agent check failed: $e');
      return false;
    }
  }

  @override
  Future<List<Map<String, dynamic>>> discoverPrinters() async {
    try {
      final response = await http
          .get(Uri.parse('$agentUrl/printers'), headers: _headers)
          .timeout(const Duration(seconds: 15)); // Discovery is slow

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        // Combine configured + discovered
        final configured = body['configured'] as List?;
        final discovered = body['discovered'] as List?;

        // Normalize
        final List<Map<String, dynamic>> result = [];
        if (configured != null) {
          result.addAll(configured.map((e) => Map<String, dynamic>.from(e)));
        }
        if (discovered != null) {
          // Add if not already present (simplededup by IP/ID)
          for (var d in discovered) {
            final exists = result.any(
              (c) => c['endpoint'] == d['address'] || c['id'] == d['id'],
            );
            if (!exists) {
              result.add(Map<String, dynamic>.from(d));
            }
          }
        }
        return result;
      }
      return [];
    } catch (e) {
      debugPrint('Agent discovery failed: $e');
      throw Exception('Could not fetch printers from agent: $e');
    }
  }

  @override
  Future<void> print(PrintJob job) async {
    try {
      final response = await http
          .post(
            Uri.parse('$agentUrl/print'),
            headers: _headers,
            body: jsonEncode({
              'printerId': job.printerId,
              'type': job.isRaw ? 'raw' : 'text',
              'content': job.content,
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        final body = jsonDecode(response.body);
        throw Exception(body['error'] ?? 'Agent rejected print job');
      }
    } catch (e) {
      debugPrint('Agent print failed: $e');
      throw Exception('Failed to send print job to agent: $e');
    }
  }

  @override
  Future<bool> checkPrinterStatus(String printerId) async {
    // Agent doesn't have per-printer status yet, assume OK if Agent is UP
    return await isAvailable();
  }
}

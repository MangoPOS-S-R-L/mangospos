import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class AgentStatus {
  final String baseUrl;
  final bool ok;
  final List<dynamic> printers;
  AgentStatus({
    required this.baseUrl,
    required this.ok,
    this.printers = const [],
  });
}

/// Detecta el Print Agent priorizando 127.0.0.1, cachea 5 min y luego escanea la LAN.
class PrintAgentDetector {
  static const _cacheKey = 'print_agent_url';
  static const _cacheTtlSeconds = 300;
  static const _candidatePorts = [4000, 3000, 9100, 9105];

  Future<String?> _getCached() async {
    final prefs = await SharedPreferences.getInstance();
    final ts = prefs.getInt('$_cacheKey:ts');
    final url = prefs.getString(_cacheKey);
    if (ts == null || url == null) return null;
    final age = DateTime.now().millisecondsSinceEpoch ~/ 1000 - ts;
    if (age < _cacheTtlSeconds) return url;
    return null;
  }

  Future<void> _setCached(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cacheKey, url);
    await prefs.setInt('$_cacheKey:ts', DateTime.now().millisecondsSinceEpoch ~/ 1000);
  }

  Future<AgentStatus> testAgent(String baseUrl) async {
    try {
      final statusRes = await _probe(baseUrl, '/status');
      final healthRes = statusRes ?? await _probe(baseUrl, '/health');
      if (healthRes == null || healthRes.statusCode != 200) {
        return AgentStatus(baseUrl: baseUrl, ok: false);
      }

      final printersRes =
          await _probe(baseUrl, '/api/printers/discover') ??
          await _probe(baseUrl, '/printers');

      final printers = printersRes == null
          ? const []
          : _extractPrinters(printersRes.body);
      return AgentStatus(baseUrl: baseUrl, ok: true, printers: printers);
    } catch (_) {
      return AgentStatus(baseUrl: baseUrl, ok: false);
    }
  }

  Future<http.Response?> _probe(String baseUrl, String path) async {
    try {
      return await http
          .get(Uri.parse('$baseUrl$path'))
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      return null;
    }
  }

  List<dynamic> _extractPrinters(String body) {
    final decoded = jsonDecode(body);
    if (decoded is List) return decoded;
    if (decoded is Map<String, dynamic>) {
      if (decoded['items'] is List) return decoded['items'] as List<dynamic>;
      if (decoded['discovered'] is List) {
        return decoded['discovered'] as List<dynamic>;
      }
      if (decoded['printers'] is List) {
        return decoded['printers'] as List<dynamic>;
      }
    }
    return const [];
  }

  /// 1) localhost en puertos conocidos 2) cache 3) escaneo LAN
  Future<String?> scanLocalFirst() async {
    for (final port in _candidatePorts) {
      final local = await testAgent('http://127.0.0.1:$port');
      if (local.ok) {
        await _setCached(local.baseUrl);
        return local.baseUrl;
      }
    }

    final cached = await _getCached();
    if (cached != null) {
      final c = await testAgent(cached);
      if (c.ok) return cached;
    }

    final lan = await _scanLan();
    if (lan != null) {
      await _setCached(lan);
      return lan;
    }
    return null;
  }

  Future<String?> _scanLan() async {
    final subnet = await subnetFromConnectivity();
    if (subnet == null) return null;

    // disparamos en lotes para evitar saturar
    const batch = 40;
    final urls = <String>[];
    for (var i = 1; i <= 254; i++) {
      for (final port in _candidatePorts) {
        urls.add('http://$subnet.$i:$port');
      }
    }
    for (var i = 0; i < urls.length; i += batch) {
      final slice = urls.skip(i).take(batch);
      final results = await Future.wait(slice.map(testAgent));
      final hit = results.firstWhere(
        (r) => r.ok,
        orElse: () => AgentStatus(baseUrl: '', ok: false),
      );
      if (hit.ok) return hit.baseUrl;
    }
    return null;
  }

  /// Deriva subnet IPv4 (192/10/172) desde adaptadores activos
  Future<String?> subnetFromConnectivity() async {
    final connectivityResults = await Connectivity().checkConnectivity();
    final hasLanConnectivity =
        connectivityResults.contains(ConnectivityResult.wifi) ||
        connectivityResults.contains(ConnectivityResult.ethernet);

    if (hasLanConnectivity) {
      final ifaces = await NetworkInterface.list();
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (addr.type == InternetAddressType.IPv4 &&
              (ip.startsWith('192.') ||
                  ip.startsWith('10.') ||
                  ip.startsWith('172.'))) {
            final parts = ip.split('.');
            return '${parts[0]}.${parts[1]}.${parts[2]}';
          }
        }
      }
    }
    return null;
  }
}

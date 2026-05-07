// lib/services/dgii_lookup_service.dart
//
// Lookup de contribuyentes contra el registro RNC de la DGII (RD) usando
// la API pública del gobierno dominicano: api.digital.gob.do.
//
// - Endpoint: GET /v3/contribuyentes/{rnc}
// - Sin auth, sin costo, sin rate limit documentado para uso normal.
// - Retorna nombre / razón social, estado, actividad económica.
//
// El servicio se usa desde el form de cliente para autocompletar al
// crear/editar: el usuario escribe el RNC, click "Buscar en DGII", y
// si existe, los campos `name` (y `address` si vienen) se llenan solos.

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

/// Información mínima de un contribuyente devuelta por DGII.
class DgiiCompanyInfo {
  final String rnc;
  final String? nombre;
  final String? estado;
  final String? actividadEconomica;
  final String? categoria;

  const DgiiCompanyInfo({
    required this.rnc,
    this.nombre,
    this.estado,
    this.actividadEconomica,
    this.categoria,
  });

  /// `true` si el RNC está reportado como activo en DGII. Los inactivos
  /// igual se devuelven (para que el usuario sepa) pero la UI debería
  /// avisar antes de usarlos en una factura electrónica.
  bool get isActivo {
    final s = estado?.trim().toUpperCase();
    return s == 'ACTIVO';
  }

  factory DgiiCompanyInfo.fromMap(Map<String, dynamic> map) {
    String? str(String key) {
      final v = map[key];
      if (v == null) return null;
      final s = v.toString().trim();
      return s.isEmpty ? null : s;
    }

    return DgiiCompanyInfo(
      rnc: (map['rnc'] ?? '').toString().trim(),
      // La API ha tenido variaciones: 'nombre' / 'razonSocial' / 'name'.
      // Cubrimos las 3 para que cambios menores no rompan la integración.
      nombre: str('nombre') ?? str('razonSocial') ?? str('name'),
      estado: str('estado') ?? str('status'),
      actividadEconomica:
          str('actividadEconomica') ?? str('actividad_economica'),
      categoria: str('categoria') ?? str('category'),
    );
  }
}

/// Lanzada cuando el RNC no tiene formato válido. El caller la captura
/// para mostrar mensaje al usuario sin pegar la red.
class InvalidRncException implements Exception {
  final String reason;
  const InvalidRncException(this.reason);
  @override
  String toString() => reason;
}

class DgiiLookupService {
  static const String _baseUrl =
      'https://api.digital.gob.do/v3/contribuyentes';
  static const Duration _timeout = Duration(seconds: 10);

  final http.Client _client;
  DgiiLookupService({http.Client? client})
      : _client = client ?? http.Client();

  /// Busca un contribuyente por RNC. Devuelve `null` si la DGII no lo
  /// tiene registrado (HTTP 404). Lanza:
  /// - [InvalidRncException] si el formato del RNC es inválido.
  /// - [Exception] si DGII responde con error o la red falla.
  Future<DgiiCompanyInfo?> lookupByRnc(String rnc) async {
    final cleaned = _normalize(rnc);
    if (cleaned.length != 9 && cleaned.length != 11) {
      throw const InvalidRncException(
        'El RNC debe tener 9 dígitos (jurídica) o 11 (cédula).',
      );
    }

    final uri = Uri.parse('$_baseUrl/$cleaned');
    final http.Response response;
    try {
      response = await _client.get(uri).timeout(_timeout);
    } catch (e) {
      debugPrint('DgiiLookupService: red error: $e');
      throw Exception(
        'No se pudo conectar a DGII. Revisa tu conexión e intenta de nuevo.',
      );
    }

    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw Exception(
        'DGII devolvió un error (${response.statusCode}). Intenta luego.',
      );
    }

    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        final info = DgiiCompanyInfo.fromMap(decoded);
        // Algunas respuestas vacías llegan como objeto sin nombre/rnc.
        if ((info.rnc.isEmpty) && (info.nombre == null)) return null;
        return info;
      }
      // La API a veces devuelve [] cuando no hay match — tratarlo como 404.
      if (decoded is List && decoded.isEmpty) return null;
      return null;
    } catch (e) {
      debugPrint('DgiiLookupService: parse error: $e');
      throw Exception('La respuesta de DGII no se pudo procesar.');
    }
  }

  /// Limpia separadores comunes (`-`, espacios, puntos) y deja solo
  /// dígitos. RNC se almacena sin formato en DB para evitar duplicados
  /// por separadores distintos.
  static String _normalize(String rnc) {
    return rnc.replaceAll(RegExp(r'[^0-9]'), '');
  }
}

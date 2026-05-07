// lib/services/dgii_lookup_service.dart
//
// Lookup de contribuyentes contra el registro RNC de la DGII (RD).
//
// Backend: rnc.megaplus.com.do — proxy público que cachea el padrón
// oficial de la DGII y expone 3 endpoints REST sin auth:
//
//   GET /api/consulta?rnc={rnc}                — busca por RNC/cédula
//   GET /api/consulta/nombre?buscar={exact}    — match exacto por nombre
//   GET /api/consulta/nombres?buscar={partial} — búsqueda parcial paginada
//
// Ejemplo respuesta exitosa (single):
//   {"error":false,"codigo_http":200,"mensaje":"Consulta Exitosa",
//    "cedula_rnc":"101-01063-2",
//    "nombre_razon_social":"BANCO POPULAR DOMINICANO S A BANCO MULTIPLE",
//    "nombre_comercial":"BANCO POPULAR DOMINICANO",
//    "estado":"ACTIVO","actividad_economica":"BANCOS MULTIPLES",
//    "regimen_de_pagos":"NORMAL","facturador_electronico":"SI",...}
//
// Ejemplo 404:
//   {"codigo_http":404,"error":true,"mensaje":"el rnc/cedula consultado
//    no se encuentra inscrito como contribuyente.","rnc_consultado":"..."}

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

/// Datos devueltos por el padrón DGII para un contribuyente.
class DgiiCompanyInfo {
  /// RNC formateado (`101-01063-2`).
  final String rnc;

  /// Razón social registrada.
  final String? nombreRazonSocial;

  /// Nombre comercial / marca (puede estar vacío).
  final String? nombreComercial;

  /// `ACTIVO`, `DADO DE BAJA`, `SUSPENDIDO`, etc.
  final String? estado;

  /// Actividad económica primaria.
  final String? actividadEconomica;

  /// Régimen de pagos (`NORMAL`, `PST`, etc.).
  final String? regimenPagos;

  /// Categoría jurídica.
  final String? categoria;

  /// `SI` / `NO` — si el contribuyente está autorizado a emitir e-CF.
  final String? facturadorElectronico;

  const DgiiCompanyInfo({
    required this.rnc,
    this.nombreRazonSocial,
    this.nombreComercial,
    this.estado,
    this.actividadEconomica,
    this.regimenPagos,
    this.categoria,
    this.facturadorElectronico,
  });

  /// `true` si el contribuyente está reportado como activo. Los demás
  /// estados (DADO DE BAJA, SUSPENDIDO) deberían avisar al usuario antes
  /// de emitir un e-CF en su nombre.
  bool get isActivo {
    return (estado ?? '').trim().toUpperCase() == 'ACTIVO';
  }

  /// `true` si DGII tiene a este contribuyente autorizado para e-CF.
  bool get esFacturadorElectronico {
    return (facturadorElectronico ?? '').trim().toUpperCase() == 'SI';
  }

  /// Mejor nombre disponible: comercial si existe, si no la razón social.
  String? get displayName {
    final c = nombreComercial?.trim();
    if (c != null && c.isNotEmpty) return c;
    return nombreRazonSocial?.trim();
  }

  factory DgiiCompanyInfo.fromMap(Map<String, dynamic> map) {
    String? str(String key) {
      final v = map[key];
      if (v == null) return null;
      final s = v.toString().trim();
      return s.isEmpty ? null : s;
    }

    return DgiiCompanyInfo(
      rnc: (map['cedula_rnc'] ?? map['rnc'] ?? '').toString().trim(),
      nombreRazonSocial: str('nombre_razon_social'),
      nombreComercial: str('nombre_comercial'),
      estado: str('estado'),
      actividadEconomica: str('actividad_economica'),
      regimenPagos: str('regimen_de_pagos'),
      categoria: str('categoria'),
      facturadorElectronico: str('facturador_electronico'),
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
  static const String _baseUrl = 'https://rnc.megaplus.com.do/api';
  static const Duration _timeout = Duration(seconds: 10);

  final http.Client _client;
  DgiiLookupService({http.Client? client})
      : _client = client ?? http.Client();

  /// Busca un contribuyente por RNC o cédula. Devuelve `null` si DGII
  /// no lo tiene registrado (HTTP 404).
  /// Lanza:
  /// - [InvalidRncException] si el formato es inválido (no son 9 ni 11
  ///   dígitos numéricos tras limpiar separadores).
  /// - [Exception] si DGII responde con error o la red falla.
  Future<DgiiCompanyInfo?> lookupByRnc(String rnc) async {
    final cleaned = _normalize(rnc);
    if (cleaned.length != 9 && cleaned.length != 11) {
      throw const InvalidRncException(
        'El RNC debe tener 9 dígitos (jurídica) o 11 (cédula).',
      );
    }

    final uri = Uri.parse('$_baseUrl/consulta?rnc=$cleaned');
    final http.Response response;
    try {
      response = await _client.get(uri).timeout(_timeout);
    } catch (e) {
      debugPrint('DgiiLookupService.lookupByRnc network: $e');
      throw Exception(
        'No se pudo conectar a DGII. Revisa tu conexión e intenta de nuevo.',
      );
    }

    // El backend distingue 200 (encontrado) y 404 (no inscrito) con un
    // body JSON estructurado. Otros 4xx/5xx → error real.
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw Exception(
        'DGII devolvió un error (${response.statusCode}). Intenta luego.',
      );
    }

    final Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('DgiiLookupService.lookupByRnc parse: $e');
      throw Exception('La respuesta de DGII no se pudo procesar.');
    }

    if (decoded['error'] == true) {
      // Algunos endpoints devuelven 200 con error=true (e.g. timeouts
      // del backend). Tratarlo como "no encontrado" si el status
      // sugiere 404, si no como error explícito.
      final code = decoded['codigo_http'];
      if (code == 404) return null;
      throw Exception(
        decoded['mensaje']?.toString() ?? 'Error desconocido de DGII.',
      );
    }

    return DgiiCompanyInfo.fromMap(decoded);
  }

  /// Búsqueda parcial por nombre o razón social. Devuelve la lista de
  /// matches (puede estar vacía). Lanza [Exception] si la red falla.
  ///
  /// Útil cuando el usuario no tiene el RNC pero sí parte del nombre del
  /// contribuyente. La API pagina los resultados; tomamos solo la
  /// primera página (suficiente para el caso UI típico).
  Future<List<DgiiCompanyInfo>> searchByName(String query) async {
    final q = query.trim();
    if (q.length < 3) return const <DgiiCompanyInfo>[];

    final uri = Uri.parse(
      '$_baseUrl/consulta/nombres?buscar=${Uri.encodeQueryComponent(q)}',
    );
    final http.Response response;
    try {
      response = await _client.get(uri).timeout(_timeout);
    } catch (e) {
      debugPrint('DgiiLookupService.searchByName network: $e');
      throw Exception(
        'No se pudo conectar a DGII. Revisa tu conexión e intenta de nuevo.',
      );
    }

    if (response.statusCode == 404) return const <DgiiCompanyInfo>[];
    if (response.statusCode != 200) {
      throw Exception(
        'DGII devolvió un error (${response.statusCode}). Intenta luego.',
      );
    }

    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return const [];
      if (decoded['error'] == true) return const [];
      final results = decoded['resultados'];
      if (results is! List) return const [];
      return results
          .whereType<Map<String, dynamic>>()
          .map(DgiiCompanyInfo.fromMap)
          .toList(growable: false);
    } catch (e) {
      debugPrint('DgiiLookupService.searchByName parse: $e');
      return const [];
    }
  }

  /// Limpia separadores comunes (`-`, espacios, puntos) y deja solo
  /// dígitos. RNC se almacena sin formato en DB para evitar duplicados
  /// por separadores distintos.
  static String _normalize(String rnc) {
    return rnc.replaceAll(RegExp(r'[^0-9]'), '');
  }
}

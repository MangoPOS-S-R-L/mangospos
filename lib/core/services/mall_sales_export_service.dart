import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:mangopos/data/repositories/mall_sales_export_repository.dart';

/// Error de exportación con mensaje apto para mostrar al usuario.
class MallSalesExportException implements Exception {
  MallSalesExportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Genera y sube por SFTP el acumulado de ventas por hora al servidor de la
/// plaza comercial (formato Ágora Santiago Center, manual sección 6.6).
///
/// El archivo del día se REGENERA COMPLETO y se SOBRESCRIBE en cada envío:
/// así la última caja que cierra sube el consolidado de todas las estaciones.
///
/// Nunca debe bloquear ni romper el cierre de caja — usar [sendOnCashClose]
/// (traga todos los errores y los deja en `last_error` para la pantalla de
/// configuración).
class MallSalesExportService {
  MallSalesExportService([SupabaseClient? client])
      : _repo = MallSalesExportRepository(client ?? Supabase.instance.client);

  final MallSalesExportRepository _repo;

  static const _connectTimeout = Duration(seconds: 12);
  static const _totalTimeout = Duration(seconds: 45);

  /// Cabecera exacta del archivo de ejemplo del manual de la plaza.
  static const csvHeader =
      'ID_TRANSACCION,NUMSERIE,FECHA,HORA,TOTALTRANSVENTA,TOTALART,TASA,'
      'TOTALBRUTO,TOTALIMPUESTOS,TOTALNETO';

  /// Nombre del archivo: `<prefijo>_<ddMMyyyy>.txt`.
  /// Con prefijo "Ventas_4_8" produce `Ventas_4_8_27032018.txt` como el
  /// ejemplo del manual.
  static String buildFileName(MallSalesExportConfig config, DateTime date) {
    final dd = date.day.toString().padLeft(2, '0');
    final mm = date.month.toString().padLeft(2, '0');
    final yyyy = date.year.toString().padLeft(4, '0');
    final prefix =
        config.filePrefix.trim().isEmpty ? 'Ventas' : config.filePrefix.trim();
    return '${prefix}_$dd$mm$yyyy.txt';
  }

  /// Construye el contenido del .txt: cabecera + una fila por hora con venta.
  /// Formatos calcados del ejemplo del manual (fila
  /// `270318,341,27/03/2018,10:23,18,22.000000,1,60885.60,10959.40`):
  ///   - ID_TRANSACCION: ddMMyy + hora (2 dígitos) → único por fila/día.
  ///   - HORA: entero 0-23 (la tabla del manual la define INT).
  ///   - TOTALART con 6 decimales, montos con 2.
  ///
  /// CONVENCIÓN DE MONTOS (confirmada por la plaza el 2026-08-13):
  ///   TOTALBRUTO      = base SIN impuesto
  ///   TOTALIMPUESTOS  = impuesto
  ///   TOTALNETO       = TOTALBRUTO + TOTALIMPUESTOS = lo que pagó el cliente
  ///
  /// Es al revés de la nomenclatura interna, donde `totalGross` es el monto
  /// cobrado y `totalNet` la base. Se verifica con el ejemplo del propio
  /// manual: 10 959.40 es exactamente el 18% de 60 885.60, así que ese primer
  /// número es la base y no el cobrado. Por eso el mapeo va cruzado:
  ///   TOTALBRUTO ← row.totalNet   ·   TOTALNETO ← row.totalGross
  static String buildCsv({
    required MallSalesExportConfig config,
    required DateTime date,
    required List<MallHourlySalesRow> rows,
  }) {
    final dd = date.day.toString().padLeft(2, '0');
    final mm = date.month.toString().padLeft(2, '0');
    final yy = (date.year % 100).toString().padLeft(2, '0');
    final yyyy = date.year.toString().padLeft(4, '0');
    final fecha = '$dd/$mm/$yyyy';
    final tasa = config.exchangeRate == config.exchangeRate.roundToDouble()
        ? config.exchangeRate.toStringAsFixed(0)
        : config.exchangeRate.toStringAsFixed(2);

    final buffer = StringBuffer()..write(csvHeader);
    for (final row in rows) {
      final hh = row.hour.toString().padLeft(2, '0');
      buffer
        ..write('\r\n')
        ..writeAll(<String>[
          '$dd$mm$yy$hh',
          config.clientCode.trim(),
          fecha,
          row.hour.toString(),
          row.txCount.toString(),
          row.totalItems.toStringAsFixed(6),
          tasa,
          row.totalNet.toStringAsFixed(2), // TOTALBRUTO = base sin impuesto
          row.totalTax.toStringAsFixed(2), // TOTALIMPUESTOS
          row.totalGross.toStringAsFixed(2), // TOTALNETO = base + impuesto
        ], ',');
    }
    buffer.write('\r\n');
    return buffer.toString();
  }

  /// Valida host/credenciales/directorio conectando y listando el directorio
  /// remoto. Lanza [MallSalesExportException] con mensaje amigable si falla.
  Future<void> testConnection(MallSalesExportConfig config) async {
    _ensureSupportedPlatform();
    _ensureComplete(config);
    await _withSftp(config, (sftp) async {
      await sftp.listdir(_normalizedDir(config));
    }).timeout(
      _totalTimeout,
      onTimeout: () => throw MallSalesExportException(
        'Tiempo de espera agotado conectando a ${config.host}.',
      ),
    );
  }

  /// Genera el archivo del día [date] y lo sube (sobrescribiendo el remoto).
  /// Registra éxito/error en la config y devuelve el nombre del archivo.
  Future<String> sendForDate({
    required String businessId,
    required DateTime date,
    MallSalesExportConfig? config,
  }) async {
    _ensureSupportedPlatform();
    final cfg = config ?? await _repo.getConfig(businessId);
    if (cfg == null) {
      throw MallSalesExportException(
        'Configura primero el servidor de la plaza comercial.',
      );
    }
    _ensureComplete(cfg);

    try {
      final rows = await _repo.fetchSalesByHour(
        businessId: businessId,
        date: date,
      );
      final fileName = buildFileName(cfg, date);
      final content = buildCsv(config: cfg, date: date, rows: rows);
      await _withSftp(cfg, (sftp) async {
        final dir = _normalizedDir(cfg);
        final path = dir == '/' ? '/$fileName' : '$dir/$fileName';
        final file = await sftp.open(
          path,
          mode: SftpFileOpenMode.create |
              SftpFileOpenMode.truncate |
              SftpFileOpenMode.write,
        );
        try {
          await file.writeBytes(
            Uint8List.fromList(utf8.encode(content)),
          );
        } finally {
          await file.close();
        }
      }).timeout(
        _totalTimeout,
        onTimeout: () => throw MallSalesExportException(
          'Tiempo de espera agotado subiendo el archivo a ${cfg.host}.',
        ),
      );
      unawaited(
        _repo
            .markSendResult(businessId: businessId, error: null)
            .catchError((_) {}),
      );
      return fileName;
    } catch (e) {
      final friendly = _friendlyError(e);
      unawaited(
        _repo
            .markSendResult(businessId: businessId, error: friendly)
            .catchError((_) {}),
      );
      throw MallSalesExportException(friendly);
    }
  }

  /// Hook post-cierre de caja: fire-and-forget. Si la exportación no está
  /// habilitada (o la plataforma no la soporta) no hace nada; si falla,
  /// solo deja el error en `last_error` — JAMÁS propaga al flujo de cierre.
  Future<void> sendOnCashClose(String businessId) async {
    if (kIsWeb) return;
    try {
      final config = await _repo.getConfig(businessId);
      if (config == null ||
          !config.enabled ||
          !config.sendOnCashClose ||
          !config.isComplete) {
        return;
      }
      await sendForDate(
        businessId: businessId,
        date: DateTime.now(),
        config: config,
      );
      debugPrint('MallSalesExport: archivo del día subido tras el cierre.');
    } catch (e) {
      // sendForDate ya registró last_error; aquí solo log.
      debugPrint('MallSalesExport: envío post-cierre falló: $e');
    }
  }

  // --- Internos -------------------------------------------------------------

  Future<T> _withSftp<T>(
    MallSalesExportConfig config,
    Future<T> Function(SftpClient sftp) action,
  ) async {
    final socket = await SSHSocket.connect(
      config.host.trim(),
      config.port,
      timeout: _connectTimeout,
    );
    final client = SSHClient(
      socket,
      username: config.username.trim(),
      onPasswordRequest: () => config.password,
    );
    try {
      final sftp = await client.sftp();
      return await action(sftp);
    } finally {
      client.close();
    }
  }

  String _normalizedDir(MallSalesExportConfig config) {
    var dir = config.remoteDir.trim();
    if (dir.isEmpty) return '/';
    if (dir.length > 1 && dir.endsWith('/')) {
      dir = dir.substring(0, dir.length - 1);
    }
    return dir;
  }

  void _ensureSupportedPlatform() {
    if (kIsWeb) {
      throw MallSalesExportException(
        'El envío por SFTP no está disponible en la versión web. '
        'Úsalo desde la app de escritorio o tablet.',
      );
    }
  }

  void _ensureComplete(MallSalesExportConfig config) {
    if (!config.isComplete) {
      throw MallSalesExportException(
        'Faltan datos de conexión: servidor, usuario y contraseña '
        'son obligatorios.',
      );
    }
  }

  String _friendlyError(Object e) {
    if (e is MallSalesExportException) return e.message;
    if (e is SSHAuthFailError || e is SSHAuthError) {
      return 'Autenticación rechazada: verifica usuario y contraseña.';
    }
    if (e is TimeoutException) {
      return 'Tiempo de espera agotado conectando al servidor.';
    }
    final msg = e.toString();
    if (msg.contains('SocketException') || msg.contains('Connection')) {
      return 'No se pudo conectar al servidor: verifica host, puerto e '
          'internet. ($msg)';
    }
    return msg;
  }
}

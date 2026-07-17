import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Configuración por negocio para exportar el acumulado de ventas por hora
/// al servidor SFTP de una plaza comercial (ej. Ágora Santiago Center).
/// Una fila por negocio en `business_sales_export_config` (RLS owner/admin).
class MallSalesExportConfig {
  const MallSalesExportConfig({
    required this.businessId,
    this.enabled = false,
    this.sendOnCashClose = true,
    this.host = '',
    this.port = 22,
    this.username = '',
    this.password = '',
    this.remoteDir = '/',
    this.clientCode = '',
    this.filePrefix = 'Ventas',
    this.exchangeRate = 1.0,
    this.lastSentAt,
    this.lastError,
  });

  final String businessId;
  final bool enabled;

  /// Además del envío manual, dispara el envío al cerrar caja.
  final bool sendOnCashClose;
  final String host;
  final int port;
  final String username;
  final String password;
  final String remoteDir;

  /// Código de cliente asignado por la plaza (campo NUMSERIE del archivo).
  final String clientCode;

  /// Prefijo del nombre del archivo, ej. "Ventas_4_8" → Ventas_4_8_27032018.txt
  final String filePrefix;

  /// Campo TASA del archivo (tasa cambiaria), manual.
  final double exchangeRate;
  final DateTime? lastSentAt;
  final String? lastError;

  bool get isComplete =>
      host.trim().isNotEmpty &&
      username.trim().isNotEmpty &&
      password.isNotEmpty;

  factory MallSalesExportConfig.fromMap(Map<String, dynamic> map) {
    return MallSalesExportConfig(
      businessId: map['business_id'] as String,
      enabled: (map['enabled'] as bool?) ?? false,
      sendOnCashClose: (map['send_on_cash_close'] as bool?) ?? true,
      host: (map['host'] as String?) ?? '',
      port: (map['port'] as num?)?.toInt() ?? 22,
      username: (map['username'] as String?) ?? '',
      password: (map['password'] as String?) ?? '',
      remoteDir: (map['remote_dir'] as String?) ?? '/',
      clientCode: (map['client_code'] as String?) ?? '',
      filePrefix: (map['file_prefix'] as String?) ?? 'Ventas',
      exchangeRate: _toDouble(map['exchange_rate']) ?? 1.0,
      lastSentAt: map['last_sent_at'] != null
          ? DateTime.tryParse(map['last_sent_at'] as String)?.toLocal()
          : null,
      lastError: map['last_error'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'business_id': businessId,
      'enabled': enabled,
      'send_on_cash_close': sendOnCashClose,
      'host': host.trim(),
      'port': port,
      'username': username.trim(),
      'password': password,
      'remote_dir': remoteDir.trim().isEmpty ? '/' : remoteDir.trim(),
      'client_code': clientCode.trim(),
      'file_prefix': filePrefix.trim().isEmpty ? 'Ventas' : filePrefix.trim(),
      'exchange_rate': exchangeRate,
    };
  }
}

/// Fila del agregado por hora que devuelve `fn_mall_sales_by_hour`.
class MallHourlySalesRow {
  const MallHourlySalesRow({
    required this.hour,
    required this.txCount,
    required this.totalItems,
    required this.totalGross,
    required this.totalTax,
    required this.totalNet,
  });

  final int hour;
  final int txCount;
  final double totalItems;
  final double totalGross;
  final double totalTax;
  final double totalNet;

  factory MallHourlySalesRow.fromMap(Map<String, dynamic> map) {
    return MallHourlySalesRow(
      hour: (map['sale_hour'] as num?)?.toInt() ?? 0,
      txCount: (map['tx_count'] as num?)?.toInt() ?? 0,
      totalItems: _toDouble(map['total_items']) ?? 0,
      totalGross: _toDouble(map['total_gross']) ?? 0,
      totalTax: _toDouble(map['total_tax']) ?? 0,
      totalNet: _toDouble(map['total_net']) ?? 0,
    );
  }
}

double? _toDouble(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString());
}

final mallSalesExportRepositoryProvider =
    Provider<MallSalesExportRepository>((ref) {
  return MallSalesExportRepository(Supabase.instance.client);
});

class MallSalesExportRepository {
  MallSalesExportRepository(this._client);

  final SupabaseClient _client;

  static const _table = 'business_sales_export_config';

  Future<MallSalesExportConfig?> getConfig(String businessId) async {
    final row = await _client
        .from(_table)
        .select()
        .eq('business_id', businessId)
        .maybeSingle();
    if (row == null) return null;
    return MallSalesExportConfig.fromMap(row);
  }

  Future<void> saveConfig(MallSalesExportConfig config) async {
    await _client
        .from(_table)
        .upsert(config.toMap(), onConflict: 'business_id');
  }

  Future<List<MallHourlySalesRow>> fetchSalesByHour({
    required String businessId,
    required DateTime date,
  }) async {
    final dateStr =
        '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    final res = await _client.rpc(
      'fn_mall_sales_by_hour',
      params: {'_business_id': businessId, '_date': dateStr},
    );
    if (res is! List) return const [];
    return res
        .whereType<Map<String, dynamic>>()
        .map(MallHourlySalesRow.fromMap)
        .toList();
  }

  /// Registra el resultado del último envío (éxito o error) para que la
  /// pantalla de configuración muestre el estado real.
  Future<void> markSendResult({
    required String businessId,
    String? error,
  }) async {
    await _client.from(_table).update(<String, dynamic>{
      if (error == null)
        'last_sent_at': DateTime.now().toUtc().toIso8601String(),
      'last_error': error,
    }).eq('business_id', businessId);
  }
}

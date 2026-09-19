import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/utils/app_time.dart';
import '../models/table_deposit_report.dart';

export '../models/table_deposit_coverage.dart';
export '../models/table_deposit_report.dart';

/// Saldo prepagado de una mesa (abono).
///
/// El cliente abona un monto a la mesa, el dinero entra a la caja en ese
/// momento, y cada factura que se cobre en esa mesa lo descuenta en vez de
/// cobrar dinero nuevo. El saldo vive en la mesa FÍSICA: sobrevive al cierre
/// de la visita y al cierre de caja, y dura hasta agotarse.
class TableDepositAccount {
  const TableDepositAccount({
    required this.tableId,
    required this.balance,
    this.accountId,
    this.tableCode,
    this.tableLabel,
    this.zoneId,
    this.holderName,
    this.totalDeposited = 0,
    this.totalConsumed = 0,
    this.lastMovementAt,
  });

  final String tableId;
  final double balance;
  final String? accountId;
  final String? tableCode;
  final String? tableLabel;
  final String? zoneId;

  /// A nombre de quién está el abono. El saldo vive en la mesa física, así que
  /// esto es lo que deja ver de quién es antes de aplicarlo.
  final String? holderName;

  final double totalDeposited;
  final double totalConsumed;
  final DateTime? lastMovementAt;

  bool get hasBalance => balance > 0.005;

  static double _toDouble(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0;
    return 0;
  }

  factory TableDepositAccount.fromRow(Map<String, dynamic> row) {
    return TableDepositAccount(
      tableId: row['table_id']?.toString() ?? '',
      balance: _toDouble(row['balance']),
      accountId: row['id']?.toString() ?? row['account_id']?.toString(),
      tableCode: row['table_code']?.toString() ?? row['code']?.toString(),
      tableLabel: row['table_label']?.toString() ?? row['label']?.toString(),
      zoneId: row['zone_id']?.toString(),
      holderName: row['holder_name']?.toString(),
      totalDeposited: _toDouble(row['total_deposited']),
      totalConsumed: _toDouble(row['total_consumed']),
      lastMovementAt: row['last_movement_at'] != null
          ? DateTime.tryParse(row['last_movement_at'].toString())
          : null,
    );
  }

  static const empty = TableDepositAccount(tableId: '', balance: 0);
}

/// Resultado de aplicar el saldo a un cobro: cuánto se descontó y con cuánto
/// quedó la mesa. Es lo que la factura imprime como "monto restante".
class TableDepositApplication {
  const TableDepositApplication({
    required this.applied,
    required this.balanceAfter,
  });

  final double applied;
  final double balanceAfter;

  factory TableDepositApplication.fromJson(Map<String, dynamic> json) {
    return TableDepositApplication(
      applied: TableDepositAccount._toDouble(json['applied']),
      balanceAfter: TableDepositAccount._toDouble(json['balance_after']),
    );
  }
}

/// Un movimiento del ledger (abono, consumo, devolución…).
class TableDepositMovement {
  const TableDepositMovement({
    required this.id,
    required this.type,
    required this.amount,
    required this.balanceAfter,
    required this.createdAt,
    this.orderId,
    this.note,
    this.reference,
  });

  final String id;

  /// deposit | consumption | reversal | refund | transfer_in | transfer_out |
  /// adjustment
  final String type;

  /// Firmado: positivo entra al saldo, negativo sale.
  final double amount;
  final double balanceAfter;
  final DateTime createdAt;
  final String? orderId;
  final String? note;
  final String? reference;

  String get typeLabel => tableDepositMovementTypeLabel(type);

  factory TableDepositMovement.fromRow(Map<String, dynamic> row) {
    return TableDepositMovement(
      id: row['id']?.toString() ?? '',
      type: row['type']?.toString() ?? '',
      amount: TableDepositAccount._toDouble(row['amount']),
      balanceAfter: TableDepositAccount._toDouble(row['balance_after']),
      createdAt:
          DateTime.tryParse(row['created_at']?.toString() ?? '') ??
          DateTime.now(),
      orderId: row['order_id']?.toString(),
      note: row['note']?.toString(),
      reference: row['reference']?.toString(),
    );
  }
}

/// Error del módulo de abonos, ya traducido a algo que el cajero entienda.
class TableDepositException implements Exception {
  const TableDepositException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => message;
}

class TableDepositRepository {
  TableDepositRepository(this._client);

  final SupabaseClient _client;

  static const _tableAccounts = 'table_deposit_accounts';
  static const _tableMovements = 'table_deposit_movements';

  /// Código del método de pago con el que se cobra contra el saldo.
  static const methodCode = 'table_deposit';

  /// Saldo de UNA mesa. Devuelve [TableDepositAccount.empty] si la mesa nunca
  /// recibió un abono, y también si la migración todavía no está aplicada: el
  /// salón tiene que abrir igual, solo que sin mostrar saldos.
  Future<TableDepositAccount> getBalance(String tableId) async {
    try {
      final row = await _client
          .from(_tableAccounts)
          .select(
            'id, table_id, balance, holder_name, total_deposited, '
            'total_consumed, last_movement_at',
          )
          .eq('table_id', tableId)
          .maybeSingle();
      if (row == null) return TableDepositAccount.empty;
      return TableDepositAccount.fromRow(Map<String, dynamic>.from(row));
    } on PostgrestException {
      return TableDepositAccount.empty;
    } catch (_) {
      return TableDepositAccount.empty;
    }
  }

  /// Saldo de la mesa a la que pertenece una orden.
  ///
  /// El modal de cobro tiene la orden pero no la mesa (`Order` solo carga
  /// `session_id`), así que esto lo resuelve en un viaje. Devuelve
  /// [TableDepositAccount.empty] para ventas sin mesa (rápida/manual) y si la
  /// migración todavía no está aplicada: el cobro tiene que abrir igual.
  Future<TableDepositAccount> getBalanceForOrder(String orderId) async {
    // Orden local: el servidor no la conoce. Y la precuenta espera esto antes
    // de imprimir, así que tampoco puede colgarse con la red caída.
    if (orderId.startsWith('local-order-')) return TableDepositAccount.empty;
    try {
      final res = await _client
          .rpc(
            'fn_table_deposit_balance_for_order',
            params: {'p_order_id': orderId},
          )
          .timeout(const Duration(seconds: 5));
      if (res == null) return TableDepositAccount.empty;
      final json = Map<String, dynamic>.from(res as Map);
      final tableId = json['table_id']?.toString();
      if (tableId == null || tableId.isEmpty) {
        return TableDepositAccount.empty;
      }
      return TableDepositAccount(
        tableId: tableId,
        balance: TableDepositAccount._toDouble(json['balance']),
        accountId: json['account_id']?.toString(),
        tableLabel: json['table_label']?.toString(),
        holderName: json['holder_name']?.toString(),
      );
    } catch (_) {
      return TableDepositAccount.empty;
    }
  }

  /// Saldos con dinero de todo el negocio, para pintar el badge en el salón
  /// sin una consulta por mesa. La clave es el `table_id`.
  Future<Map<String, TableDepositAccount>> getBalancesByTable(
    String businessId,
  ) async {
    try {
      final rows = await _client.rpc(
        'fn_table_deposit_balances',
        params: {'p_business_id': businessId},
      );
      final list = List<Map<String, dynamic>>.from(rows as List);
      return {
        for (final row in list)
          row['table_id'].toString(): TableDepositAccount.fromRow(row),
      };
    } catch (_) {
      // Migración sin aplicar o sin red: el salón se pinta sin saldos.
      return const {};
    }
  }

  /// Movimientos de una mesa, del más reciente al más viejo.
  Future<List<TableDepositMovement>> getMovements(
    String tableId, {
    int limit = 50,
  }) async {
    final rows = await _client
        .from(_tableMovements)
        .select('id, type, amount, balance_after, created_at, order_id, '
            'note, reference')
        .eq('table_id', tableId)
        .order('created_at', ascending: false)
        .limit(limit);
    return List<Map<String, dynamic>>.from(rows)
        .map(TableDepositMovement.fromRow)
        .toList();
  }

  /// Registra un abono. El dinero entra a la caja AHORA, así que exige sesión
  /// de caja abierta. No emite NCF: el abono no es una venta.
  ///
  /// Devuelve el saldo con el que quedó la mesa.
  Future<TableDepositAccount> addDeposit({
    required String tableId,
    required double amount,
    required String cashierSessionId,
    String paymentMethodCode = 'cash',
    String? reference,
    String? holderName,
    String? note,
  }) async {
    try {
      final res = await _client.rpc(
        'fn_table_deposit_add',
        params: {
          'p_table_id': tableId,
          'p_amount': amount,
          'p_payment_method_id': paymentMethodCode,
          'p_cashier_session_id': cashierSessionId,
          'p_reference': reference,
          'p_holder_name': holderName,
          'p_note': note,
        },
      );
      final json = Map<String, dynamic>.from(res as Map);
      return TableDepositAccount(
        tableId: tableId,
        balance: TableDepositAccount._toDouble(json['balance']),
        accountId: json['account_id']?.toString(),
        tableLabel: json['table_label']?.toString(),
        holderName: json['holder_name']?.toString(),
        totalDeposited: TableDepositAccount._toDouble(json['total_deposited']),
        totalConsumed: TableDepositAccount._toDouble(json['total_consumed']),
      );
    } catch (e) {
      throw TableDepositException(friendlyError(e));
    }
  }

  /// Devuelve saldo no consumido en efectivo. Saca dinero de la caja.
  Future<double> refund({
    required String tableId,
    required double amount,
    required String cashierSessionId,
    String? note,
  }) async {
    try {
      final res = await _client.rpc(
        'fn_table_deposit_refund',
        params: {
          'p_table_id': tableId,
          'p_amount': amount,
          'p_cashier_session_id': cashierSessionId,
          'p_note': note,
        },
      );
      final json = Map<String, dynamic>.from(res as Map);
      return TableDepositAccount._toDouble(json['balance']);
    } catch (e) {
      throw TableDepositException(friendlyError(e));
    }
  }

  /// Mueve saldo de una mesa a otra — el arreglo del abono cargado a la mesa
  /// equivocada.
  Future<void> transfer({
    required String fromTableId,
    required String toTableId,
    required double amount,
    String? note,
  }) async {
    try {
      await _client.rpc(
        'fn_table_deposit_transfer',
        params: {
          'p_from_table_id': fromTableId,
          'p_to_table_id': toTableId,
          'p_amount': amount,
          'p_note': note,
        },
      );
    } catch (e) {
      throw TableDepositException(friendlyError(e));
    }
  }

  /// Reporte de abonos: las mesas con saldo hoy o con movimiento en el
  /// período, y los movimientos del período. [from]/[to] en hora de pared
  /// AST, [to] exclusivo, igual que el resto de Reportes.
  Future<TableDepositReport> getReport({
    required String businessId,
    required DateTime from,
    required DateTime to,
  }) async {
    try {
      final accountRows = List<Map<String, dynamic>>.from(
        await _client
            .from(_tableAccounts)
            .select(
              'id, table_id, balance, holder_name, last_movement_at, '
              'dining_tables(code, label, zones(name))',
            )
            .eq('business_id', businessId),
      );

      // Una cuenta sin saldo que no se movió desde el inicio del período no
      // puede tener movimientos en él: no hace falta traer su historia.
      final fromUtc = AppTime.astToUtc(from);
      final toUtc = AppTime.astToUtc(to);
      final candidates = accountRows.where((row) {
        if (TableDepositAccount._toDouble(row['balance']) > 0.005) return true;
        final last = DateTime.tryParse(
          row['last_movement_at']?.toString() ?? '',
        );
        return last != null && !last.isBefore(fromUtc);
      }).toList(growable: false);
      if (candidates.isEmpty) return TableDepositReport.empty;

      final movementRows = await _movementHistory([
        for (final row in candidates) row['id'].toString(),
      ]);

      final userIds = <String>{
        for (final row in movementRows)
          if (_isBetween(row['created_at'], fromUtc, toUtc) &&
              (row['created_by']?.toString() ?? '').isNotEmpty)
            row['created_by'].toString(),
      };

      return TableDepositReport.build(
        accountRows: candidates,
        movementRows: movementRows,
        from: from,
        to: to,
        userNames: await _userNames(userIds.toList(growable: false)),
      );
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('42P01') || msg.contains('PGRST205')) {
        throw const TableDepositException(
          'El módulo de abonos no está instalado en el servidor todavía.',
        );
      }
      rethrow;
    }
  }

  /// Historia completa de las cuentas, más vieja primero. Pagina porque
  /// PostgREST corta cada respuesta en 1000 filas sin avisar, y una mesa con
  /// un abono de temporada acumula un consumo por cada factura.
  Future<List<Map<String, dynamic>>> _movementHistory(
    List<String> accountIds,
  ) async {
    const batchSize = 150; // 414 URI Too Long con listas largas en inFilter.
    const pageSize = 500;
    final rows = <Map<String, dynamic>>[];
    for (var start = 0; start < accountIds.length; start += batchSize) {
      final end = start + batchSize > accountIds.length
          ? accountIds.length
          : start + batchSize;
      final chunk = accountIds.sublist(start, end);
      for (var offset = 0; ; offset += pageSize) {
        final page = List<Map<String, dynamic>>.from(
          await _client
              .from(_tableMovements)
              .select(
                'id, account_id, type, amount, balance_after, reference, '
                'note, created_at, created_by, payment_methods(name)',
              )
              .inFilter('account_id', chunk)
              .order('created_at', ascending: true)
              .order('id', ascending: true)
              .range(offset, offset + pageSize - 1),
        );
        rows.addAll(page);
        if (page.length < pageSize) break;
      }
    }
    return rows;
  }

  /// Nombres para "Registrado por". Best-effort: sin nombres el reporte sale
  /// igual.
  Future<Map<String, String>> _userNames(List<String> userIds) async {
    if (userIds.isEmpty) return const {};
    try {
      final rows = List<Map<String, dynamic>>.from(
        await _client
            .from('profiles')
            .select('id, full_name')
            .inFilter('id', userIds),
      );
      return {
        for (final row in rows)
          if ((row['full_name']?.toString().trim() ?? '').isNotEmpty)
            row['id'].toString(): row['full_name'].toString().trim(),
      };
    } catch (_) {
      return const {};
    }
  }

  static bool _isBetween(Object? value, DateTime fromUtc, DateTime toUtc) {
    final at = DateTime.tryParse(value?.toString() ?? '');
    return at != null && !at.isBefore(fromUtc) && at.isBefore(toUtc);
  }

  /// Cuánto saldo se aplicó en un cobro y con cuánto quedó la mesa.
  ///
  /// Se lee por orden porque el ticket se arma cuando el cobro fue mixto y
  /// todavía no se conoce cada `payment_id`. Devuelve null si esa orden no
  /// tocó saldo, que es el caso normal.
  Future<TableDepositApplication?> getApplicationForOrder(
    String orderId,
  ) async {
    try {
      final res = await _client.rpc(
        'fn_table_deposit_for_order',
        params: {'p_order_id': orderId},
      );
      if (res == null) return null;
      final json = Map<String, dynamic>.from(res as Map);
      final applied = TableDepositAccount._toDouble(json['applied']);
      if (applied <= 0.005) return null;
      return TableDepositApplication.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  /// Lo mismo pero por pago, para que la reimpresión saque el saldo que había
  /// en ese momento y no el de hoy.
  Future<TableDepositApplication?> getApplicationForPayment(
    String paymentId,
  ) async {
    try {
      final res = await _client.rpc(
        'fn_table_deposit_for_payment',
        params: {'p_payment_id': paymentId},
      );
      if (res == null) return null;
      return TableDepositApplication.fromJson(
        Map<String, dynamic>.from(res as Map),
      );
    } catch (_) {
      return null;
    }
  }

  /// Traduce los códigos que levantan los RPC a algo que el cajero entienda.
  static String friendlyError(Object error) {
    final msg = error.toString();
    if (msg.contains('TABLE_DEPOSIT_INSUFFICIENT')) {
      return 'La mesa no tiene saldo suficiente para cubrir ese monto.';
    }
    if (msg.contains('TABLE_DEPOSIT_NO_TABLE')) {
      return 'El saldo de mesa solo se puede usar en una mesa. Esta venta no '
          'tiene mesa asociada.';
    }
    if (msg.contains('TABLE_DEPOSIT_NO_CHANGE')) {
      return 'El saldo de mesa no da vuelto. Cobra con el saldo solo hasta el '
          'total de la cuenta.';
    }
    if (msg.contains('TABLE_DEPOSIT_ACCOUNT_NOT_FOUND')) {
      return 'Esta mesa no tiene saldo registrado.';
    }
    if (msg.contains('CASH_SESSION_REQUIRED') ||
        msg.contains('CASH_SESSION_NOT_OPEN')) {
      return 'Necesitas una caja abierta para registrar el abono.';
    }
    if (msg.contains('DEPOSIT_INVALID_AMOUNT')) {
      return 'El monto del abono tiene que ser mayor que cero.';
    }
    if (msg.contains('DEPOSIT_METHOD_NOT_ALLOWED')) {
      return 'El abono no se puede pagar con el saldo de la propia mesa.';
    }
    if (msg.contains('DEPOSIT_SAME_TABLE')) {
      return 'La mesa de origen y la de destino son la misma.';
    }
    if (msg.contains('DEPOSIT_CROSS_BUSINESS')) {
      return 'No se puede mover saldo entre negocios distintos.';
    }
    if (msg.contains('DEPOSIT_OWNER_ADMIN_ONLY')) {
      return 'Solo el dueño o un administrador puede cargar o devolver el '
          'saldo de una mesa. Cobrar contra el saldo sí lo puede hacer la '
          'caja.';
    }
    if (msg.contains('ACCESS_DENIED')) {
      return 'No tienes acceso a esta mesa.';
    }
    if (msg.contains('TABLE_NOT_FOUND')) {
      return 'No se encontró la mesa.';
    }
    if (msg.contains('INVALID_PAYMENT_METHOD')) {
      return 'Método de pago no válido para el abono.';
    }
    if (msg.contains('42883') || msg.contains('does not exist')) {
      return 'El módulo de abonos no está instalado en el servidor todavía.';
    }
    return 'No se pudo completar la operación de abono.';
  }
}

final tableDepositRepositoryProvider = Provider<TableDepositRepository>((ref) {
  return TableDepositRepository(Supabase.instance.client);
});


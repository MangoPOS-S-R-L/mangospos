import 'package:intl/intl.dart';

import 'package:mangopos/data/models/change_history_entry.dart';

/// Cómo se lee el historial: frases («Ana editó el producto Pollo frito»),
/// nombres de campos en español y valores formateados.
///
/// MISMO ARCHIVO en el POS (lib/presentation/settings/history/) y en el
/// dashboard (lib/presentation/history/): solo cambia la ruta del import del
/// modelo. Lo escriben las migraciones 20261013_0001 y 20261013_0002.

/// Un área del filtro: etiqueta y las tablas que agrupa.
class HistoryArea {
  const HistoryArea(this.key, this.label, this.tables);

  final String key;
  final String label;
  final List<String> tables;
}

const List<HistoryArea> historyAreas = [
  HistoryArea('all', 'Todo', []),
  HistoryArea('accounts', 'Cuentas', [
    'order_items',
    'orders',
    'payments',
    'table_sessions',
    'fiscal_documents',
    'sales_notes',
  ]),
  HistoryArea('kitchen', 'Cocina', ['kitchen_rounds']),
  HistoryArea('cash', 'Caja', [
    'cash_transactions',
    'cash_register_sessions',
    'table_deposit_movements',
    'cash_registers',
    'cash_transaction_reasons',
    'payment_methods',
    'bank_accounts',
  ]),
  HistoryArea('menu', 'Productos', [
    'menu_items',
    'categories',
    'menus',
    'menu_item_links',
    'modifier_groups',
    'modifiers',
    'menu_item_groups',
    'modifier_ingredients',
    'combo_groups',
    'combo_group_items',
    'promotions',
    'coupons',
    'gift_cards',
    'loyalty_stamp_programs',
  ]),
  HistoryArea('taxes', 'Impuestos y NCF', [
    'taxes',
    'menu_item_taxes',
    'ncf_sequences',
    'fiscal_settings',
  ]),
  HistoryArea('inventory', 'Inventario', [
    'inventory_items',
    'inventory_item_presentations',
    'warehouses',
    'recipes',
    'recipe_ingredients',
    'inventory_movements',
    'stock_transfers',
    'physical_count_sessions',
    'requisitions',
    'production_orders',
    'fixed_assets',
  ]),
  HistoryArea('purchases', 'Compras', [
    'purchase_orders',
    'purchase_receptions',
    'direct_receipts',
    'suppliers',
    'supplier_items',
    'supplier_credits',
    'supplier_credit_payments',
  ]),
  HistoryArea('customers', 'Clientes y créditos', [
    'customers',
    'customer_credits',
    'credit_payments',
    'loyalty_stamp_adjustments',
  ]),
  HistoryArea('staff', 'Personal y permisos', [
    'employees',
    'employee_roles',
    'roles',
    'role_permissions',
    'user_permission_overrides',
    'user_businesses',
    'device_sessions',
  ]),
  HistoryArea('floor', 'Salón e impresoras', [
    'zones',
    'dining_tables',
    'reservations',
    'printers',
    'print_areas',
    'print_area_printers',
    'menu_item_print_areas',
    'device_printer_bindings',
  ]),
  HistoryArea('settings', 'Configuración', [
    'business_settings',
    'businesses',
    'external_api_keys',
    'accounting_accounts',
    'accounting_cost_centers',
    'order_item_removal_reasons',
  ]),
];

/// Filtro por acción: (valor en la base, etiqueta). null = todas.
const List<(String?, String)> historyActions = [
  (null, 'Todo'),
  ('create', 'Creado'),
  ('update', 'Editado'),
  ('delete', 'Borrado'),
  ('void', 'Anulado'),
];

String historyAreaLabel(String table) {
  for (final area in historyAreas) {
    if (area.tables.contains(table)) return area.label;
  }
  return '';
}

/// «3:45 p. m.»
String historyTime(DateTime t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final m = t.minute.toString().padLeft(2, '0');
  return '$h:$m ${t.hour < 12 ? 'a. m.' : 'p. m.'}';
}

const _weekdays = [
  'lunes',
  'martes',
  'miércoles',
  'jueves',
  'viernes',
  'sábado',
  'domingo',
];
const _months = [
  'enero',
  'febrero',
  'marzo',
  'abril',
  'mayo',
  'junio',
  'julio',
  'agosto',
  'septiembre',
  'octubre',
  'noviembre',
  'diciembre',
];

/// «Hoy», «Ayer», «lunes 12 de octubre».
String historyDayLabel(DateTime t, {DateTime? now}) {
  final today = now ?? DateTime.now();
  final day = DateTime(t.year, t.month, t.day);
  final diff = DateTime(
    today.year,
    today.month,
    today.day,
  ).difference(day).inDays;
  if (diff == 0) return 'Hoy';
  if (diff == 1) return 'Ayer';
  final year = t.year == today.year ? '' : ' de ${t.year}';
  return '${_weekdays[t.weekday - 1]} ${t.day} de ${_months[t.month - 1]}$year';
}

/// Una línea del detalle: campo y valor, o campo, antes y después. Sin
/// campo = un elemento de una lista (los productos de un envío a cocina).
class HistoryLine {
  const HistoryLine(this.field, this.before, [this.after]);

  final String field;
  final String before;
  final String? after;

  bool get isChange => after != null;
}

/// Frases y detalles. [money] formatea montos con la moneda del negocio.
class HistoryText {
  const HistoryText({required this.money});

  final String Function(num value) money;

  // -------------------------------------------------------------------------
  // Frase
  // -------------------------------------------------------------------------

  /// «Ana editó el producto Pollo frito».
  String sentence(ChangeHistoryEntry e) {
    final who = e.actorName.trim().isEmpty ? 'Alguien' : e.actorName.trim();
    String say(String text) =>
        '$who $text'.replaceAll(RegExp(r'\s+'), ' ').trim();
    final event = e.changes['event']?.toString();
    final byEvent = event == null ? null : _eventSentence(event, e);
    return say(byEvent ?? _tableSentence(e));
  }

  String _amount(Object? v) {
    final raw = v is List && v.isNotEmpty ? v.last : v;
    final n = raw is num ? raw : num.tryParse('${raw ?? ''}');
    return n == null ? '' : money(n.abs());
  }

  String? _eventSentence(String event, ChangeHistoryEntry e) {
    final label = e.label.trim();
    final ctx = e.context.trim();
    final c = e.changes;
    final a = e.action;
    String or(String value, String fallback) =>
        value.isEmpty ? fallback : value;

    switch (event) {
      case 'cash_deposit':
        return switch (a) {
          'create' => 'agregó ${_amount(c['amount'])} a $label',
          'delete' => 'borró una entrada de $label',
          _ => 'editó una entrada de $label',
        };
      case 'cash_withdrawal':
        return switch (a) {
          'create' => 'retiró ${_amount(c['amount'])} de $label',
          'delete' => 'borró un retiro de $label',
          _ => 'editó un retiro de $label',
        };
      case 'cash_expense':
        return switch (a) {
          'create' => 'registró un gasto de ${_amount(c['amount'])} en $label',
          'delete' => 'borró un gasto de $label',
          _ => 'editó un gasto de $label',
        };
      case 'kitchen_send':
        final n = c['items_count'];
        final count = n is num ? n.toInt() : 0;
        return count == 1
            ? 'envió 1 producto de $label a cocina'
            : 'envió $count productos de $label a cocina';
      case 'cash_open':
        return 'abrió $label con ${_amount(c['start_amount'])}';
      case 'cash_close':
        return 'cerró $label';
      case 'cash_force_close':
        return 'cerró a la fuerza $label';
      case 'cash_status':
        return 'cambió el estado de $label';
      case 'cash_recount':
        return 'recontó $label';
      case 'cash_move':
        return 'pasó $label a otro equipo';
      case 'table_transfer':
        return 'pasó la cuenta de $label a ${or(ctx, 'otra mesa')}';
      case 'items_transfer':
        final n = c['items_count'];
        if (ctx.isEmpty || n is! num) {
          return 'pasó la cuenta de $label a ${or(ctx, 'otra mesa')}';
        }
        return n == 1
            ? 'pasó 1 producto de $label a $ctx'
            : 'pasó ${n.toInt()} productos de $label a $ctx';
      case 'discount':
        if (c['courtesy'] != null) return 'dio una cortesía en $label';
        final pair = c['discount'];
        if (pair is List && pair.length == 2) {
          final before = num.tryParse('${pair[0]}') ?? 0;
          final after = num.tryParse('${pair[1]}') ?? 0;
          if (after < before) return 'quitó un descuento en $label';
          return 'aplicó un descuento de ${money(after - before)} en $label';
        }
        return 'aplicó un descuento en $label';
      case 'payment_method':
        return 'cambió el método de pago de $label';
      case 'waiter_change':
        return 'cambió el mesero de $label';
      case 'credit_note':
        return 'emitió la nota de crédito $label'
            '${ctx.isEmpty ? '' : ' para $ctx'}';
      case 'abono':
        return 'recibió un abono de ${_amount(c['amount'])}'
            '${ctx.isEmpty ? '' : ' de $ctx'}'
            '${label.isEmpty ? '' : ' ($label)'}';
      case 'credit_cancel':
        return 'canceló el crédito de ${or(label, 'un cliente')}';
      case 'payable_create':
        return 'registró una cuenta por pagar a ${or(label, 'un proveedor')}';
      case 'payable_cancel':
        return 'canceló la cuenta por pagar de ${or(label, 'un proveedor')}';
      case 'supplier_payment':
        return 'le pagó ${_amount(c['amount'])} a ${or(label, 'un proveedor')}';
      case 'deposit_deposit':
        return 'recibió un abono de ${_amount(c['amount'])} para $label';
      case 'deposit_refund':
        return 'devolvió ${_amount(c['amount'])} del abono de $label';
      case 'deposit_transfer_out':
        return 'pasó ${_amount(c['amount'])} del abono de $label a '
            '${or(ctx, 'otra mesa')}';
      case 'deposit_adjustment':
        return 'ajustó el abono de $label';
      case 'stamps_adjust':
        final n = c['stamps'] is num ? (c['stamps'] as num).toInt() : 0;
        final word = n.abs() == 1 ? 'sello' : 'sellos';
        return n >= 0
            ? 'le dio $n $word a $label'
            : 'le quitó ${-n} $word a $label';
      case 'stock_adjust':
        return 'ajustó el inventario de $label';
      case 'stock_outflow':
        return 'registró una salida de $label';
      case 'stock_initial':
        return 'cargó el inventario inicial de $label';
      case 'stock_move':
        return 'movió el inventario de $label';
      case 'asset_created':
        return 'registró el activo $label';
      case 'asset_relocated':
        return 'movió el activo $label';
      case 'asset_reassigned':
        return 'reasignó el activo $label';
      case 'asset_status_changed':
        return 'cambió el estado del activo $label';
      case 'asset_retired':
        return 'dio de baja el activo $label';
      case 'asset_reactivated':
        return 'reactivó el activo $label';
      case 'asset_updated':
        return 'editó el activo $label';
      case 'device_revoke':
        return 'cerró a distancia la sesión de $label';
    }
    return null;
  }

  String _tableSentence(ChangeHistoryEntry e) {
    final label = e.label.trim();
    final ctx = e.context.trim();
    final a = e.action;
    String or(String value, String fallback) =>
        value.isEmpty ? fallback : value;
    String link(String add, String remove, String change) => switch (a) {
      'create' => add,
      'delete' => remove,
      _ => change,
    };

    switch (e.tableName) {
      case 'order_items':
        final where = or(ctx, 'una cuenta');
        return a == 'update'
            ? 'bajó la cantidad de $label en $where'
            : 'quitó $label de $where';
      case 'orders':
        return e.changes['paid_total'] != null
            ? 'anuló la venta de $label'
            : 'anuló la cuenta de $label';
      case 'payments':
        return 'anuló un pago de $label';
      case 'sales_notes':
        return 'anuló la nota de venta $label';
      case 'business_settings':
        return 'cambió la configuración del POS';
      case 'businesses':
        return 'cambió los datos del negocio';
      case 'fiscal_settings':
        return link(
          'configuró los datos fiscales',
          'borró los datos fiscales',
          'cambió los datos fiscales',
        );
      case 'employees':
        return link(
          'agregó a $label al personal',
          'borró a $label del personal',
          'editó los datos de $label',
        );
      case 'user_businesses':
        final role = _statusNames['role']?[ctx] ?? ctx;
        return link(
          'le dio acceso a $label${role.isEmpty ? '' : ' como $role'}',
          'le quitó el acceso a $label',
          'cambió el acceso de $label',
        );
      case 'employee_roles':
        return link(
          'le asignó el rol ${or(ctx, 'nuevo')} a $label',
          'le quitó el rol ${or(ctx, 'que tenía')} a $label',
          'cambió el rol $ctx de $label',
        );
      case 'role_permissions':
        return _permissionPhrase(e, 'al rol $label');
      case 'user_permission_overrides':
        return _permissionPhrase(e, 'a $label');
      case 'menu_item_taxes':
        final tax = or(ctx, 'un impuesto');
        return a == 'delete'
            ? 'le quitó $tax a $label'
            : 'le puso $tax a $label';
      case 'menu_item_groups':
        final group = ctx.isEmpty
            ? 'un grupo de modificadores'
            : 'los modificadores «$ctx»';
        return a == 'delete'
            ? 'le quitó $group a $label'
            : 'le agregó $group a $label';
      case 'menu_item_links':
        return link(
          'agregó $label al menú $ctx',
          'quitó $label del menú $ctx',
          'cambió $label en el menú $ctx',
        );
      case 'combo_group_items':
        return link(
          'agregó $label al combo $ctx',
          'quitó $label del combo $ctx',
          'cambió $label en el combo $ctx',
        );
      case 'modifier_ingredients':
        final item = or(ctx, 'un insumo');
        return link(
          'agregó $item al modificador $label',
          'quitó $item del modificador $label',
          'cambió $item en el modificador $label',
        );
      case 'menu_item_print_areas':
        return link(
          'le asignó el área de impresión $ctx a $label',
          'le quitó el área de impresión $ctx a $label',
          'cambió el área de impresión de $label',
        );
      case 'print_area_printers':
        return link(
          'conectó la impresora $ctx al área $label',
          'desconectó la impresora $ctx del área $label',
          'cambió la impresora $ctx del área $label',
        );
      case 'device_printer_bindings':
        return link(
          'asignó la impresora $label al equipo $ctx',
          'quitó la impresora $label del equipo $ctx',
          'cambió la impresora $label del equipo $ctx',
        );
      case 'supplier_items':
        return link(
          'agregó $ctx al catálogo de $label',
          'quitó $ctx del catálogo de $label',
          'cambió $ctx en el catálogo de $label',
        );
      case 'inventory_item_presentations':
        return link(
          'creó la presentación $ctx de $label',
          'borró la presentación $ctx de $label',
          'editó la presentación $ctx de $label',
        );
      case 'recipes':
        return link(
          'creó la receta de $label',
          'borró la receta de $label',
          'editó la receta de $label',
        );
      case 'recipe_ingredients':
        final item = or(ctx, 'un insumo');
        return link(
          'agregó $item a la receta de $label',
          'quitó $item de la receta de $label',
          'cambió $item en la receta de $label',
        );
      case 'purchase_receptions':
        if (a == 'create') {
          return 'recibió mercancía $label${ctx.isEmpty ? '' : ' de $ctx'}';
        }
      case 'direct_receipts':
        if (a == 'create') return 'registró la entrada directa $label';
      case 'requisitions':
        if (a == 'create') return 'pidió la requisición $label';
    }

    final thing = _thing[e.tableName] ?? 'un registro';

    // Documentos: el cambio de estado dice qué pasó.
    final status = e.changes['status'];
    if (a == 'update' && status is List && status.length == 2) {
      final verb = _statusVerbs[e.tableName]?[status[1]];
      if (verb != null) return '$verb $thing $label';
    }

    final active = e.changes['is_active'];
    if (a == 'update' &&
        e.changes.length == 1 &&
        active is List &&
        active.length == 2) {
      if (active[1] == false) return 'desactivó $thing $label';
      if (active[1] == true) return 'activó $thing $label';
    }
    final verb = switch (a) {
      'create' => 'creó',
      'delete' => 'borró',
      'void' => 'anuló',
      _ => 'editó',
    };
    return '$verb $thing $label';
  }

  String _permissionPhrase(ChangeHistoryEntry e, String target) {
    final perm = e.context.trim().isEmpty
        ? 'un permiso'
        : 'el permiso «${e.context.trim()}»';
    if (e.action == 'delete') return 'le quitó $perm $target';
    final allow = e.changes['allow'];
    final after = allow is List && allow.length == 2 ? allow[1] : allow;
    if (after == false) {
      return e.action == 'create'
          ? 'le negó $perm $target'
          : 'le quitó $perm $target';
    }
    return 'le dio $perm $target';
  }

  // -------------------------------------------------------------------------
  // Detalle
  // -------------------------------------------------------------------------

  /// Lo que cambió (editar) o la fila (crear, borrar, anular), legible.
  List<HistoryLine> details(ChangeHistoryEntry e) {
    final out = <HistoryLine>[];
    final hidden = _hiddenFor(e.tableName);
    for (final MapEntry(:key, :value) in e.changes.entries) {
      if (hidden.contains(key) || _hiddenAlways.contains(key)) continue;

      // Lista de productos (envío a cocina, traslado): uno por línea.
      if (key == 'products' && value is List) {
        for (final item in value) {
          final text = item?.toString().trim() ?? '';
          if (text.isNotEmpty) out.add(HistoryLine('', text));
        }
        continue;
      }
      if (key == 'items_count' && e.changes['products'] is List) continue;

      // Descuento: una línea por producto.
      if (key == 'lines' && value is Map) {
        for (final line in value.values) {
          if (line is! Map) continue;
          out.add(
            HistoryLine(
              line['name']?.toString() ?? 'Producto',
              _money(line['before']) ?? money(0),
              _money(line['after']) ?? money(0),
            ),
          );
        }
        continue;
      }

      final field = _fields[key] ?? _humanize(key);
      final isPair =
          value is List &&
          value.length == 2 &&
          (e.action == 'update' || _alwaysPair.contains(key));
      if (isPair) {
        final before = _value(e.tableName, key, value[0], inPair: true);
        final after = _value(e.tableName, key, value[1], inPair: true);
        if (before == null && after == null) continue;
        out.add(HistoryLine(field, before ?? '(vacío)', after ?? '(vacío)'));
      } else {
        if (value == false) continue;
        final text = _value(e.tableName, key, value, inPair: false);
        if (text == null) continue;
        out.add(HistoryLine(field, text));
      }
    }
    return out;
  }

  String? _money(Object? v) {
    final n = v is num ? v : num.tryParse('${v ?? ''}');
    return n == null ? null : money(n);
  }

  String? _value(String table, String key, Object? v, {required bool inPair}) {
    if (v == null) return null;
    if (v is String && v.trim().isEmpty) return null;
    if (v is List && v.isEmpty) return null;
    if (v is Map && v.isEmpty) return null;
    if (v is bool) return v ? 'Sí' : 'No';

    if (_moneyKeys.contains(key)) {
      final m = _money(v);
      if (m != null) return m;
    }
    if (v is num) {
      final text = _number.format(v);
      return _percent.contains(key) ? '$text%' : text;
    }
    if (v is String) {
      // Un id que no se pudo traducir a nombre no le dice nada a nadie.
      if (_uuid.hasMatch(v)) return inPair ? '(sin nombre)' : null;
      final names = key == 'status'
          ? (table == 'payments' ? _paymentStatus : _statusNames['status'])
          : _statusNames[key];
      final named = names?[v];
      if (named != null) return named;
      if (_isoDate.hasMatch(v)) {
        final d = DateTime.tryParse(v);
        if (d != null) return DateFormat('dd/MM/yyyy').format(d);
      }
      if (_isoDateTime.hasMatch(v)) {
        final d = DateTime.tryParse(v);
        if (d != null) {
          return DateFormat('dd/MM/yyyy HH:mm').format(d.toLocal());
        }
      }
      return v;
    }
    if (v is List) {
      if (v.every((x) => x is! Map && x is! List)) {
        final parts = v
            .map((x) => _value(table, key, x, inPair: false))
            .whereType<String>()
            .toList(growable: false);
        return parts.isEmpty ? null : parts.join(', ');
      }
      return v.length == 1 ? '1 elemento' : '${v.length} elementos';
    }
    if (v is Map) {
      final text = v.entries
          .where((e) => e.value != null && e.value.toString().isNotEmpty)
          .map((e) => '${e.key}: ${e.value}')
          .join(', ');
      return text.length > 120 ? '${text.substring(0, 117)}…' : text;
    }
    return v.toString();
  }
}

// ---------------------------------------------------------------------------
// Diccionarios
// ---------------------------------------------------------------------------

final _number = NumberFormat('#,##0.##', 'en_US');

const Map<String, String> _thing = {
  'menu_items': 'el producto',
  'categories': 'la categoría',
  'menus': 'el menú',
  'modifier_groups': 'el grupo de modificadores',
  'modifiers': 'el modificador',
  'combo_groups': 'el combo',
  'promotions': 'la oferta',
  'coupons': 'el cupón',
  'gift_cards': 'la tarjeta de regalo',
  'loyalty_stamp_programs': 'la tarjeta de sellos',
  'taxes': 'el impuesto',
  'inventory_items': 'el insumo',
  'warehouses': 'el almacén',
  'roles': 'el rol',
  'customers': 'el cliente',
  'suppliers': 'el proveedor',
  'zones': 'la zona',
  'dining_tables': 'la mesa',
  'reservations': 'la reservación de',
  'printers': 'la impresora',
  'print_areas': 'el área de impresión',
  'cash_registers': 'la caja',
  'cash_transaction_reasons': 'el motivo de caja',
  'payment_methods': 'el método de pago',
  'bank_accounts': 'la cuenta de banco',
  'ncf_sequences': 'la secuencia NCF',
  'purchase_orders': 'la orden de compra',
  'purchase_receptions': 'la recepción',
  'direct_receipts': 'la entrada directa',
  'stock_transfers': 'la transferencia',
  'physical_count_sessions': 'el conteo físico',
  'requisitions': 'la requisición',
  'production_orders': 'la orden de producción',
  'external_api_keys': 'la llave de integración',
  'accounting_accounts': 'la cuenta contable',
  'accounting_cost_centers': 'el centro de costo',
  'order_item_removal_reasons': 'el motivo de eliminación',
};

/// Verbo según el estado al que pasó un documento.
const Map<String, Map<String, String>> _statusVerbs = {
  'purchase_orders': {
    'sent': 'envió',
    'partial': 'recibió una parte de',
    'received': 'recibió',
    'cancelled': 'canceló',
  },
  'purchase_receptions': {
    'complete': 'completó',
    'short_closed': 'cerró incompleta',
    'cancelled': 'anuló',
  },
  'direct_receipts': {'cancelled': 'anuló'},
  'stock_transfers': {
    'sent': 'envió',
    'received': 'recibió',
    'cancelled': 'canceló',
  },
  'physical_count_sessions': {
    'in_progress': 'empezó',
    'completed': 'terminó',
    'cancelled': 'canceló',
  },
  'requisitions': {
    'partial': 'despachó una parte de',
    'dispatched': 'despachó',
    'received': 'recibió',
    'cancelled': 'canceló',
  },
  'production_orders': {
    'in_progress': 'empezó',
    'completed': 'terminó',
    'cancelled': 'canceló',
  },
  'reservations': {
    'confirmed': 'confirmó',
    'seated': 'sentó',
    'completed': 'cerró',
    'cancelled': 'canceló',
    'no_show': 'marcó que no llegó',
  },
};

const _hiddenAlways = {
  'id',
  'event',
  'business_id',
  'created_at',
  'updated_at',
  'created_by',
  'updated_by',
  'metadata',
};

/// Siempre vienen como [antes, después], aunque la acción no sea «editar».
const _alwaysPair = {
  'status',
  'quantity',
  'payment_method',
  'waiter',
  'discount',
  'warehouse_id',
  'location_note',
  'assigned_employee_id',
};

Set<String> _hiddenFor(String table) => switch (table) {
  'menu_item_taxes' => const {'item_id', 'tax_id'},
  'menu_item_groups' => const {'menu_item_id', 'group_id'},
  'menu_item_links' => const {'menu_id', 'item_id'},
  'menu_item_print_areas' => const {'menu_item_id', 'print_area_id'},
  'combo_group_items' => const {'combo_group_id', 'menu_item_id'},
  'modifier_ingredients' => const {'modifier_id', 'inventory_item_id'},
  'print_area_printers' => const {'area_id', 'printer_id'},
  'device_printer_bindings' => const {'device_id', 'printer_id'},
  'supplier_items' => const {'supplier_id', 'inventory_item_id'},
  'inventory_item_presentations' => const {'item_id'},
  'employee_roles' => const {'employee_id', 'role_id'},
  'role_permissions' => const {'role_id', 'permission_id'},
  'user_permission_overrides' => const {'user_id', 'permission_id'},
  'user_businesses' => const {'user_id'},
  'recipes' => const {'menu_item_id', 'inventory_item_id'},
  'recipe_ingredients' => const {'recipe_id', 'inventory_item_id'},
  'reservations' => const {'customer_name'},
  'purchase_orders' => const {'order_number', 'supplier_id'},
  'purchase_receptions' => const {'reception_number', 'supplier_id'},
  'direct_receipts' => const {'receipt_number', 'supplier_id'},
  _ => const {},
};

const _moneyKeys = {
  'price',
  'cost',
  'price_delta',
  'amount',
  'total',
  'subtotal',
  'paid_total',
  'unit_price',
  'unit_cost',
  'cost_per_unit',
  'salary_base',
  'credit_limit',
  'min_purchase',
  'min_order_amount',
  'delivery_fee_min',
  'cash_movement_pin_threshold',
  'cash_variance_alert_threshold',
  'start_amount',
  'end_amount',
  'difference',
  'cash',
  'card',
  'transfer',
  'balance',
  'balance_after',
  'original_amount',
  'discount',
  'initial_balance',
  'current_balance',
  'purchase_cost',
};

const _percent = {
  'rate',
  'service_fee_rate',
  'default_tax_rate',
  'cost_variance_threshold_pct',
};

const Map<String, String> _paymentStatus = {
  'completed': 'Cobrado',
  'cancelled': 'Anulado',
  'void': 'Anulado',
  'refunded': 'Devuelto',
  'pending': 'Pendiente',
};

const Map<String, Map<String, String>> _statusNames = {
  'role': {
    'owner': 'Dueño',
    'admin': 'Administrador',
    'manager': 'Gerente',
    'cashier': 'Cajero',
    'waiter': 'Mesero',
    'cook': 'Cocinero',
    'chef': 'Chef',
    'delivery': 'Repartidor',
  },
  'status': {
    'open': 'Abierta',
    'closed': 'Cerrada',
    'draft': 'Borrador',
    'sent': 'Enviada',
    'partial': 'Parcial',
    'received': 'Recibida',
    'cancelled': 'Cancelada',
    'completed': 'Terminada',
    'complete': 'Completa',
    'short_closed': 'Cerrada incompleta',
    'in_progress': 'En proceso',
    'pending': 'Pendiente',
    'pending_approval': 'Por aprobar',
    'dispatched': 'Despachada',
    'confirmed': 'Confirmada',
    'seated': 'Sentada',
    'no_show': 'No llegó',
    'active': 'Activo',
    'inactive': 'Inactivo',
    'paid': 'Pagado',
    'overdue': 'Vencido',
    'retired': 'De baja',
  },
  'reason_code': {
    'physical_count': 'Conteo físico',
    'breakage': 'Rotura',
    'expiration': 'Vencimiento',
    'cleaning': 'Limpieza',
    'theft': 'Robo',
    'donation': 'Donación',
    'correction': 'Corrección',
    'other': 'Otro',
    'internal_use': 'Consumo interno',
  },
  'tax_mode': {
    'exclusive': 'Se suma al precio',
    'inclusive': 'Incluido en el precio',
  },
  'shape': {
    'square': 'Cuadrada',
    'round': 'Redonda',
    'rectangle': 'Rectangular',
  },
  'sold_by': {'unit': 'Unidad', 'weight': 'Peso'},
  'applies_to': {
    'deposit': 'Entrada',
    'withdrawal': 'Retiro',
    'expense': 'Gasto',
    'all': 'Todo',
  },
  'account_type': {
    'corriente': 'Corriente',
    'ahorro': 'Ahorro',
    'otro': 'Otro',
    'asset': 'Activo',
    'liability': 'Pasivo',
    'equity': 'Patrimonio',
    'income': 'Ingreso',
    'expense': 'Gasto',
  },
  'type': {'network': 'Red', 'usb': 'USB', 'bluetooth': 'Bluetooth'},
  'environment': {'sandbox': 'Pruebas', 'production': 'Producción'},
};

const Map<String, String> _fields = {
  // Generales
  'name': 'Nombre',
  'label': 'Nombre',
  'code': 'Código',
  'description': 'Descripción',
  'notes': 'Notas',
  'is_active': 'Activo',
  'address': 'Dirección',
  'phone': 'Teléfono',
  'email': 'Correo',
  'status': 'Estado',
  'type': 'Tipo',
  'kind': 'Tipo',
  'color': 'Color',
  'reason': 'Motivo',
  'detail': 'Detalle',
  'enabled': 'Activa',
  // Productos
  'price': 'Precio',
  'cost': 'Costo',
  'category_id': 'Categoría',
  'sku': 'SKU',
  'barcode': 'Código de barras',
  'tax_mode': 'Impuesto',
  'prep_minutes': 'Minutos de preparación',
  'image_url': 'Imagen',
  'image_path': 'Imagen',
  'has_variants': 'Tiene variantes',
  'has_prep': 'Lleva preparación',
  'contains_egg': 'Contiene huevo',
  'is_beverage': 'Es bebida',
  'dietary': 'Dieta',
  'sold_by': 'Se vende por',
  'inventory_item_id': 'Insumo',
  'is_inventory_tracked': 'Controla inventario',
  'allow_negative_sale': 'Se vende sin stock',
  'item_type': 'Tipo de producto',
  'presentation': 'Presentación',
  'print_area_code': 'Área de impresión',
  'menu_item_id': 'Producto',
  'menu_id': 'Menú',
  'combo_group_id': 'Combo',
  'is_default': 'Por defecto',
  'modifier_id': 'Modificador',
  // Modificadores y combos
  'min_select': 'Mínimo a elegir',
  'max_select': 'Máximo a elegir',
  'is_required': 'Obligatorio',
  'price_delta': 'Precio extra',
  'group_id': 'Grupo',
  'is_sold_out': 'Agotado',
  'default_selected': 'Marcado por defecto',
  'free_qty': 'Gratis hasta',
  'max_qty_per_option': 'Máximo por opción',
  'selection_mode': 'Modo de selección',
  'display_type': 'Cómo se muestra',
  // Impuestos
  'rate': 'Tasa',
  'item_id': 'Producto',
  'include_in_ecf': 'Va en el e-CF',
  'is_service_fee': 'Es cargo por servicio',
  'apply_on_zone': 'Aplica en el salón',
  'apply_on_takeout': 'Aplica para llevar',
  'apply_on_delivery': 'Aplica a delivery',
  'apply_on_quick': 'Aplica en venta rápida',
  'apply_on_manual': 'Aplica en venta manual',
  // Ofertas, cupones, tarjetas
  'discount_type': 'Tipo de descuento',
  'discount_value': 'Descuento',
  'min_purchase': 'Compra mínima',
  'applies_to': 'Aplica a',
  'target_ids': 'Productos de la oferta',
  'start_date': 'Desde',
  'end_date': 'Hasta',
  'days_of_week': 'Días',
  'start_time': 'Hora de inicio',
  'end_time': 'Hora de fin',
  'auto_apply': 'Se aplica sola',
  'priority': 'Prioridad',
  'promo_type': 'Tipo de oferta',
  'stackable': 'Se combina con otras',
  'buy_quantity': 'Compra',
  'pay_quantity': 'Paga',
  'reward_quantity': 'Regalo',
  'target_scope': 'Alcance',
  'count_mode': 'Cuenta por',
  'promotion_id': 'Oferta',
  'usage_limit': 'Límite de usos',
  'valid_from': 'Válido desde',
  'valid_until': 'Válido hasta',
  'initial_balance': 'Saldo inicial',
  'current_balance': 'Saldo',
  'expires_at': 'Vence',
  'stamps': 'Sellos',
  'program_id': 'Tarjeta de sellos',
  // Inventario y recetas
  'unit': 'Unidad',
  'min_stock': 'Stock mínimo',
  'max_stock': 'Stock máximo',
  'purchase_unit': 'Unidad de compra',
  'conversion_factor': 'Factor de conversión',
  'conversion_unit': 'Unidad de conversión',
  'pack_size': 'Unidades por empaque',
  'costing_method': 'Método de costo',
  'preferred_supplier_id': 'Proveedor preferido',
  'tracks_lots': 'Controla lotes',
  'item_classification': 'Clasificación',
  'contains_qty': 'Contiene',
  'contains_unit': 'Unidad contenida',
  'is_purchase_default': 'Se compra así',
  'is_main': 'Principal',
  'shows_in_pos': 'Se vende en el POS',
  'warehouse_type': 'Tipo de almacén',
  'keeper_employee_id': 'Encargado',
  'requires_requisition': 'Pide requisición',
  'yield_quantity': 'Rinde',
  'instructions': 'Preparación',
  'quantity': 'Cantidad',
  'warehouse_id': 'Almacén',
  'from_warehouse_id': 'Desde',
  'to_warehouse_id': 'Hacia',
  'source_warehouse_id': 'Almacén de origen',
  'destination_warehouse_id': 'Almacén de destino',
  'finished_item_id': 'Producto terminado',
  'planned_yield': 'Rendimiento planeado',
  'actual_yield': 'Rendimiento real',
  'reason_code': 'Motivo',
  'destination': 'Destino',
  'cost_per_unit': 'Costo unitario',
  'is_blind': 'A ciegas',
  'location_note': 'Ubicación',
  'assigned_employee_id': 'Asignado a',
  // Compras
  'expected_date': 'Fecha esperada',
  'received_date': 'Recibida el',
  'invoice_number': 'Factura',
  'subtotal': 'Subtotal',
  'unit_cost': 'Costo',
  'sent_at': 'Enviada',
  'received_at': 'Recibida',
  'cancelled_at': 'Cancelada',
  'approved_at': 'Aprobada',
  'started_at': 'Empezó',
  'completed_at': 'Terminó',
  'frozen_at': 'Congelado',
  'cancel_reason': 'Motivo',
  'cancellation_reason': 'Motivo',
  'started_by': 'Lo empezó',
  'completed_by': 'Lo terminó',
  'cancelled_by': 'Lo canceló',
  'received_by': 'Lo recibió',
  'dispatched_by': 'Lo despachó',
  'requested_by': 'Lo pidió',
  'approved_by': 'Autorizó',
  'from_business_id': 'Sucursal de origen',
  'to_business_id': 'Sucursal de destino',
  // Personal y permisos
  'first_name': 'Nombre',
  'last_name': 'Apellido',
  'national_id': 'Cédula',
  'gender': 'Género',
  'hire_date': 'Fecha de entrada',
  'contract_type': 'Contrato',
  'department': 'Departamento',
  'position': 'Puesto',
  'work_schedule': 'Horario',
  'salary_base': 'Salario',
  'pay_frequency': 'Frecuencia de pago',
  'bank_name': 'Banco',
  'bank_account': 'Cuenta de banco',
  'pin': 'PIN',
  'pin_hash': 'PIN',
  'user_id': 'Usuario',
  'user_email': 'Cuenta',
  'role': 'Rol',
  'role_id': 'Rol',
  'employee_id': 'Empleado',
  'permission_id': 'Permiso',
  'allow': 'Permitido',
  'is_system': 'Del sistema',
  // Clientes, proveedores y créditos
  'tax_id': 'RNC o cédula',
  'legal_name': 'Razón social',
  'credit_enabled': 'Crédito',
  'credit_limit': 'Límite de crédito',
  'credit_days': 'Días de crédito',
  'rnc': 'RNC',
  'contact_name': 'Contacto',
  'payment_terms': 'Condiciones de pago',
  'payment_terms_days': 'Días de pago',
  'lead_time_days': 'Días de entrega',
  'min_order_amount': 'Pedido mínimo',
  'whatsapp': 'WhatsApp',
  'customer_id': 'Cliente',
  'customer': 'Cliente',
  'supplier_id': 'Proveedor',
  'original_amount': 'Monto original',
  'balance': 'Saldo',
  'due_date': 'Vence',
  // Salón, reservas e impresoras
  'zone_id': 'Zona',
  'table_id': 'Mesa',
  'capacity': 'Personas',
  'shape': 'Forma',
  'customer_phone': 'Teléfono',
  'party_size': 'Personas',
  'reserved_for': 'Para',
  'duration_minutes': 'Duración (min)',
  'ip_address': 'IP',
  'ip': 'IP',
  'port': 'Puerto',
  'mac': 'MAC',
  'device_path': 'Ruta del equipo',
  'paper_width': 'Ancho del papel',
  'encoding': 'Codificación',
  'transport': 'Conexión',
  'purpose': 'Uso',
  'bluetooth_address': 'Bluetooth',
  'connection_config': 'Configuración de conexión',
  'fallback_printer_id': 'Impresora de respaldo',
  'host_device_id': 'Equipo',
  'device_id': 'Equipo',
  'area_id': 'Área',
  'printer_id': 'Impresora',
  'prints_orders': 'Imprime comandas',
  'prints_prebills': 'Imprime precuentas',
  'prints_receipts': 'Imprime recibos',
  'is_local_owner': 'Es del equipo',
  // Caja
  'receipt_printer_id': 'Impresora de recibos',
  'requires_pin': 'Pide PIN',
  'requires_reference': 'Pide referencia',
  'icon': 'Ícono',
  'account_number': 'Número de cuenta',
  'account_holder': 'Titular',
  'account_type': 'Tipo de cuenta',
  'currency': 'Moneda',
  'alias': 'Alias',
  'accounting_account_id': 'Cuenta contable',
  'start_amount': 'Fondo',
  'end_amount': 'Contado',
  'difference': 'Diferencia',
  'cash': 'Efectivo',
  'card': 'Tarjeta',
  'transfer': 'Transferencia',
  'balance_after': 'Saldo del abono',
  // NCF y fiscal
  'ncf_type': 'Tipo',
  'serie': 'Serie',
  'prefix': 'Prefijo',
  'range_start': 'Desde',
  'range_end': 'Hasta',
  'current_number': 'Número actual',
  'expiration_date': 'Vence',
  'authorized_by': 'Autorizado por',
  'business_legal_name': 'Razón social',
  'establishment_number': 'Establecimiento',
  'ecf_enabled': 'Factura electrónica',
  'ecf_environment': 'Ambiente e-CF',
  'default_ncf_type': 'NCF por defecto',
  'auto_print_fiscal': 'Imprimir factura fiscal',
  // Configuración del POS
  'tip_enabled': 'Propina',
  'service_fee_enabled': 'Cargo por servicio',
  'service_fee_rate': 'Cargo por servicio',
  'default_tax_rate': 'ITBIS por defecto',
  'allow_negative_stock': 'Vender sin stock',
  'auto_print_order': 'Imprimir comanda al enviar',
  'auto_print_receipt': 'Imprimir recibo al cobrar',
  'require_customer': 'Pedir cliente',
  'timezone': 'Zona horaria',
  'currency_code': 'Moneda',
  'country_code': 'País',
  'kitchen_enabled': 'Cocina',
  'multimesero_enabled': 'Multimesero',
  'cash_session_mode': 'Modo de caja',
  'cash_close_mode': 'Modo de cierre',
  'printerless_mode': 'Sin impresora',
  'open_drawer_on_cash': 'Abrir gaveta al cobrar en efectivo',
  'open_drawer_on_pay_button': 'Abrir gaveta al tocar Pagar',
  'ticket_header_blocks': 'Encabezado del ticket',
  'ticket_footer_blocks': 'Pie del ticket',
  'inventory_mode': 'Modo de inventario',
  'sales_note_enabled': 'Notas de venta',
  'invoice_print_template': 'Plantilla de factura',
  'discount_display_mode': 'Cómo se muestran los descuentos',
  'network_mode': 'Modo de red',
  'channel': 'Canal',
  'environment': 'Ambiente',
  'scopes': 'Permisos',
  'rate_limit_rpm': 'Límite por minuto',
  'key_prefix': 'Prefijo',
  'cancel_webhook_url': 'Aviso de anulación',
  'is_waste': 'Es merma',
  // Negocio
  'business_name': 'Nombre del negocio',
  'branch_name': 'Sucursal',
  'business_type': 'Tipo de negocio',
  'country': 'País',
  'fiscal_name': 'Razón social',
  'fiscal_rnc': 'RNC',
  'logo_url': 'Logo',
  'slogan': 'Eslogan',
  'ticket_footer_message': 'Mensaje al pie del ticket',
  'prefer_electronic_billing': 'Prefiere factura electrónica',
  // Cuentas (productos quitados, anulaciones, traslados, descuentos)
  'kitchen_sent': 'Ya había salido a cocina',
  'added_by': 'Lo agregó',
  'paid_total': 'Cobrado',
  'items_count': 'Productos',
  'products': 'Productos',
  'ncf': 'NCF',
  'payment_method': 'Método de pago',
  'reference': 'Referencia',
  'unit_price': 'Precio',
  'amount': 'Monto',
  'total': 'Total',
  'waiter': 'Mesero',
  'courtesy': 'Cortesía',
  'discount': 'Descuento total',
};

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);
final _isoDate = RegExp(r'^\d{4}-\d{2}-\d{2}$');
final _isoDateTime = RegExp(r'^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}');

String _humanize(String key) {
  final text = key.replaceAll('_', ' ').trim();
  if (text.isEmpty) return key;
  return text[0].toUpperCase() + text.substring(1);
}

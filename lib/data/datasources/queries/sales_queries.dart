/// 🥭 MangoPOS - Sales Queries
/// Queries SQL para el módulo de ventas
class SalesQueries {
  // ============================================================
  // 📊 VISTAS Y CONSULTAS
  // ============================================================

  /// Vista completa de orden con todos sus detalles
  static const String orderDetailView = '''
    SELECT 
      o.id as order_id,
      o.status_ext as order_status,
      o.subtotal,
      o.tax,
      o.total,
      o.created_at,
      ts.id as session_id,
      ts.origin,
      ts.people_count,
      ts.customer_name,
      dt.id as table_id,
      dt.code as table_code,
      dt.label as table_label,
      z.name as zone_name,
      oi.id as item_id,
      oi.product_name,
      oi.quantity,
      oi.unit_price,
      oi.subtotal as item_subtotal,
      oi.tax as item_tax,
      oi.total as item_total,
      oi.notes,
      oi.status as item_status,
      oi.is_takeout,
      oi.check_id,
      oc.label as check_label,
      oc.position as check_position
    FROM orders o
    JOIN table_sessions ts ON o.session_id = ts.id
    LEFT JOIN dining_tables dt ON ts.table_id = dt.id
    LEFT JOIN zones z ON dt.zone_id = z.id
    LEFT JOIN order_items oi ON o.id = oi.order_id
    LEFT JOIN order_checks oc ON oi.check_id = oc.id
    WHERE o.id = :order_id
    ORDER BY oc.position, oi.created_at;
  ''';

  /// Obtener sesiones activas por negocio
  static const String activeSessionsByBusiness = '''
    SELECT 
      ts.id,
      ts.table_id,
      ts.origin,
      ts.people_count,
      ts.customer_name,
      ts.opened_at,
      dt.code as table_code,
      dt.label as table_label,
      z.name as zone_name,
      o.id as order_id,
      o.status_ext as order_status,
      o.total,
      COUNT(oi.id) as items_count
    FROM table_sessions ts
    LEFT JOIN dining_tables dt ON ts.table_id = dt.id
    LEFT JOIN zones z ON dt.zone_id = z.id
    LEFT JOIN orders o ON ts.id = o.session_id AND o.closed_at IS NULL
    LEFT JOIN order_items oi ON o.id = oi.order_id
    WHERE ts.business_id = :business_id
      AND ts.closed_at IS NULL
    GROUP BY ts.id, dt.code, dt.label, z.name, o.id
    ORDER BY ts.opened_at DESC;
  ''';

  /// Obtener mesas por zona
  static const String tablesByZone = '''
    SELECT 
      dt.id,
      dt.code,
      dt.label,
      dt.state,
      dt.capacity,
      dt.pos_x,
      dt.pos_y,
      dt.width,
      dt.height,
      dt.rotation,
      z.name as zone_name,
      z.id as zone_id,
      ts.id as active_session_id,
      ts.people_count,
      o.id as active_order_id,
      o.total as current_total,
      o.status_ext as order_status
    FROM dining_tables dt
    JOIN zones z ON dt.zone_id = z.id
    LEFT JOIN table_sessions ts ON dt.id = ts.table_id AND ts.closed_at IS NULL
    LEFT JOIN orders o ON ts.id = o.session_id AND o.closed_at IS NULL
    WHERE z.business_id = :business_id
      AND dt.is_active = true
    ORDER BY z.sort_index, dt.code;
  ''';

  /// Obtener checks de una orden
  static const String orderChecksSummary = '''
    SELECT 
      oc.id,
      oc.label,
      oc.position,
      oc.is_closed,
      oc.subtotal,
      oc.tax,
      oc.total,
      COUNT(oi.id) as items_count
    FROM order_checks oc
    LEFT JOIN order_items oi ON oc.id = oi.check_id
    WHERE oc.order_id = :order_id
    GROUP BY oc.id
    ORDER BY oc.position;
  ''';

  // ============================================================
  // 🔧 FUNCIONES RPC (YA EXISTENTES EN SUPABASE)
  // ============================================================

  /// Abrir mesa y crear orden
  static const String rpcOpenTable = 'fn_open_table';

  /// Abrir venta manual o rápida
  static const String rpcOpenManualOrQuick = 'fn_open_manual_or_quick';

  /// Agregar item del menú
  static const String rpcAddItemFromMenu = 'fn_add_item_from_menu';

  /// Actualizar cantidad de item
  static const String rpcUpdateItemQty = 'fn_update_item_qty';

  /// Actualizar notas de item
  static const String rpcUpdateItemNotes = 'fn_update_item_notes';

  /// Eliminar item
  static const String rpcDeleteItem = 'fn_delete_item';

  /// Mover item a otro check
  static const String rpcMoveItemToCheck = 'fn_move_item_to_check';

  /// Toggle takeout de item
  static const String rpcToggleItemTakeout = 'fn_toggle_item_takeout';

  /// Enviar orden a cocina
  static const String rpcConfirmOrderToKitchen = 'fn_confirm_order_to_kitchen';

  /// Cerrar orden y mesa
  static const String rpcCloseOrderAndTable = 'fn_close_order_and_table';

  /// Crear split bill
  static const String rpcCreateSplitBill = 'fn_create_split_bill';

  /// Procesar pago
  static const String rpcProcessPayment = 'fn_process_payment_v2';

  /// Generar NCF
  static const String rpcGenerateNCF = 'generate_ncf';

  /// Crear documento fiscal
  static const String rpcCreateFiscalDocument = 'create_fiscal_document';
}

class PurchasesQueries {
  static const tableSuppliers = 'suppliers';
  static const tablePurchaseOrders = 'purchase_orders';
  static const tablePurchaseOrderItems = 'purchase_order_items';
  static const tableWarehouses = 'warehouses';
  static const tableInventoryItems = 'inventory_items';
  static const tablePurchaseReceptions = 'purchase_receptions';
  static const tablePurchaseReceptionLines = 'purchase_reception_lines';
  static const tableEmployees = 'employees';
  static const rpcReceivePurchaseOrder = 'fn_receive_purchase_order';
  static const rpcReceivePurchaseOrderPartial = 'fn_receive_purchase_order_partial';

  /// Recepción de mercancía que además EMITE el conduce: deja documento
  /// numerado en `purchase_receptions` y es idempotente por clave.
  /// Migración 20260828_0001 (sobre 20260812_0001).
  static const rpcReceivePurchaseOrderV2 = 'fn_receive_purchase_order_v2';
}

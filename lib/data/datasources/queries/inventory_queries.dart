class InventoryQueries {
  static const tableInventoryItems = 'inventory_items';
  static const tableInventoryMovements = 'inventory_movements';
  static const tableInventoryStock = 'inventory_stock';
  static const tableWarehouses = 'warehouses';
  static const rpcRecordMovement = 'fn_inventory_record_movement';
  static const rpcAdjustInventory = 'fn_inventory_adjust';
  static const rpcTransferSend = 'fn_inventory_transfer_send';
  static const rpcTransferReceive = 'fn_inventory_transfer_receive';
  static const rpcTransferCancel = 'fn_inventory_transfer_cancel';
  static const tableStockTransferItems = 'stock_transfer_items';
  static const viewTransfersLog = 'v_inventory_transfers_log';
}

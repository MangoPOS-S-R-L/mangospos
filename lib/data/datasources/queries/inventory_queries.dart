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

  // F2 — Requisiciones (migración 20260902_0001).
  static const tableRequisitions = 'requisitions';
  static const tableRequisitionLines = 'requisition_lines';
  static const rpcRequisitionCreate = 'fn_requisition_create';
  static const rpcRequisitionDispatch = 'fn_requisition_dispatch';
  static const rpcRequisitionReceive = 'fn_requisition_receive';
  static const rpcRequisitionCancel = 'fn_requisition_cancel';
  static const viewTransfersLog = 'v_inventory_transfers_log';
  static const viewMovementsKardex = 'v_inventory_movements_with_balance';
  static const viewLowStock = 'v_inventory_low_stock';
  static const viewStockByWarehouse = 'v_inventory_stock_by_warehouse';
  static const tableDirectReceipts = 'direct_receipts';
  static const tableDirectReceiptItems = 'direct_receipt_items';
  static const viewDirectReceiptsLog = 'v_direct_receipts_log';
  static const rpcDirectReceipt = 'fn_inventory_direct_receipt';
  static const rpcDirectReceiptCancel = 'fn_inventory_direct_receipt_cancel';
  // Sprint 4 lotes
  static const tableInventoryLots = 'inventory_lots';
  static const viewLotsWithStatus = 'v_inventory_lots_with_status';
  static const rpcRegisterLot = 'fn_inventory_register_lot';
  static const rpcLotDispose = 'fn_inventory_lot_dispose';
  // Sprint 5 reportería
  static const viewValuation = 'v_inventory_valuation';
  static const viewValuationSummary = 'v_inventory_valuation_summary';
  static const rpcRotationAnalysis = 'fn_inventory_rotation_analysis';
}

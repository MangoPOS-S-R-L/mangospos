class CreditsQueries {
  static const tableCustomerCredits = 'customer_credits';
  static const tableCreditPayments = 'credit_payments';
  static const tableSupplierCredits = 'supplier_credits';
  static const tableSupplierCreditPayments = 'supplier_credit_payments';

  // Embeds vía FK: customers/suppliers para pintar nombre sin segunda consulta.
  static const selectReceivables =
      'id, business_id, customer_id, order_id, fiscal_document_id, '
      'original_amount, balance, due_date, status, notes, created_at, '
      'customers(name, phone)';

  static const selectReceivablePayments =
      'id, credit_id, amount, reference, session_id, created_at, '
      'payment_methods(name, code)';

  // `ncf` (mig 20260814_0003) y el embed de la orden que originó la deuda:
  // desde la CxP se puede volver al documento que la creó, y el comprobante
  // fiscal se consulta sin abrir la compra.
  static const selectPayables =
      'id, business_id, supplier_id, purchase_order_id, invoice_number, ncf, '
      'original_amount, balance, due_date, status, notes, created_at, '
      'suppliers(name, phone), purchase_orders(order_number)';

  /// Selección sin las columnas de 20260814_0003, para ambientes donde la
  /// migración todavía no se aplicó.
  static const selectPayablesLegacy =
      'id, business_id, supplier_id, purchase_order_id, invoice_number, '
      'original_amount, balance, due_date, status, notes, created_at, '
      'suppliers(name, phone)';

  static const selectPayablePayments =
      'id, supplier_credit_id, amount, payment_method_code, reference, '
      'session_id, created_at';

  static const rpcRegisterCreditAbono = 'fn_register_credit_abono';
  static const rpcRegisterSupplierCreditPayment =
      'fn_register_supplier_credit_payment';
  static const rpcEnsureCreditPaymentMethod = 'fn_ensure_credit_payment_method';
}

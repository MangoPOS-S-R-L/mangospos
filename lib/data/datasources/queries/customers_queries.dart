class CustomersQueries {
  static const tableCustomers = 'customers';
  static const selectBase =
      'id, business_id, name, email, phone, rnc, total_orders, total_spent, loyalty_points, created_at';

  static const searchFields =
      'name.ilike.%{q}%,email.ilike.%{q}%,phone.ilike.%{q}%,rnc.ilike.%{q}%';
}

class CustomersQueries {
  static const tableCustomers = 'customers';
  static const selectBase =
      'id, business_id, name, email, phone, address, tax_id, notes, created_at, updated_at';

  static const searchFields =
      'name.ilike.%{q}%,email.ilike.%{q}%,phone.ilike.%{q}%,rnc.ilike.%{q}%';
}

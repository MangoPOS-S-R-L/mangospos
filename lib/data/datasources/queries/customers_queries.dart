class CustomersQueries {
  static const tableCustomers = 'customers';
  static const selectBase =
      'id, business_id, name, email, phone, address, tax_id, notes, created_at, updated_at';

  // OJO: el campo en la DB es `tax_id`, no `rnc`. Antes este string usaba
  // `rnc.ilike` y Supabase ignoraba silenciosamente la cláusula → la
  // búsqueda por RNC fallaba sin error visible.
  static const searchFields =
      'name.ilike.%{q}%,email.ilike.%{q}%,phone.ilike.%{q}%,tax_id.ilike.%{q}%';
}

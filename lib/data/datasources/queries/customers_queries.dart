class CustomersQueries {
  static const tableCustomers = 'customers';
  static const selectBase =
      'id, business_id, name, legal_name, email, phone, address, tax_id, notes, '
      'credit_enabled, credit_limit, credit_days, created_at, updated_at';

  // OJO: el campo en la DB es `tax_id`, no `rnc`. Antes este string usaba
  // `rnc.ilike` y Supabase ignoraba silenciosamente la cláusula → la
  // búsqueda por RNC fallaba sin error visible.
  // `legal_name` agregado para que el admin encuentre por razón social
  // cuando solo recuerda el nombre legal y no el comercial.
  static const searchFields =
      'name.ilike.%{q}%,legal_name.ilike.%{q}%,email.ilike.%{q}%,phone.ilike.%{q}%,tax_id.ilike.%{q}%';
}

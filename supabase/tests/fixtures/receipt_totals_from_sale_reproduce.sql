-- La función anterior reproduce los importes de ambas fotos de la orden.
INSERT INTO orders (id,delivery_fee) VALUES ('20000000-0000-0000-0000-000000000001', 0);
INSERT INTO order_items (order_id, unit_price) VALUES ('20000000-0000-0000-0000-000000000001', 6800);
INSERT INTO fiscal_documents (id, business_id, order_id) VALUES
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001');
INSERT INTO payments (order_id, fiscal_document_id, amount) VALUES
  ('20000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 6900);
SELECT test_assert(
  subtotal=5312.50 AND itbis_amount=956.25 AND service_fee=531.25 AND total=6900,
  'v6 reproduce venta6800 / pago6900 / total emitido6900 incoherente'
) FROM fiscal_documents WHERE id='30000000-0000-0000-0000-000000000001';

-- Documento preemitido antes del despliegue con cuenta aún abierta.
INSERT INTO orders (id,delivery_fee,closed_at) VALUES ('20000000-0000-0000-0000-000000000010',0,NULL);
INSERT INTO order_items (order_id,unit_price,tax_rate) VALUES ('20000000-0000-0000-0000-000000000010',500,0);
INSERT INTO fiscal_documents (id,business_id,order_id,subtotal,taxable_amount,total) VALUES
  ('30000000-0000-0000-0000-000000000011','10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000010',500,500,500);
INSERT INTO payments (order_id,amount) VALUES ('20000000-0000-0000-0000-000000000010',200);

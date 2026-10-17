-- Documentos anteriores permanecen intactos, también ante abonos posteriores.
SELECT test_assert(total=6900 AND sale_totals_locked, 'migración no reescribe NCF anterior')
FROM fiscal_documents WHERE id='30000000-0000-0000-0000-000000000001';
UPDATE payments SET amount=7000 WHERE fiscal_document_id='30000000-0000-0000-0000-000000000001';
SELECT test_assert(total=6900, 'cambiar pago histórico no reescribe NCF anterior')
FROM fiscal_documents WHERE id='30000000-0000-0000-0000-000000000001';
UPDATE orders SET closed_at=NULL WHERE id='20000000-0000-0000-0000-000000000001';
UPDATE payments SET amount=7100 WHERE fiscal_document_id='30000000-0000-0000-0000-000000000001';
SELECT test_assert(total=6900 AND sale_totals_locked, 'reabrir scope no descongela comprobante definitivo previo')
FROM fiscal_documents WHERE id='30000000-0000-0000-0000-000000000001';

-- Venta de 6800 con un pago registrado de 6900: el excedente no es mercancía.
INSERT INTO orders (id,delivery_fee) VALUES ('20000000-0000-0000-0000-000000000002', 0);
INSERT INTO order_items (order_id, unit_price) VALUES ('20000000-0000-0000-0000-000000000002', 6800);
INSERT INTO fiscal_documents (id,business_id,order_id) VALUES
  ('30000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000002');
INSERT INTO payments (order_id,fiscal_document_id,amount) VALUES
  ('20000000-0000-0000-0000-000000000002','30000000-0000-0000-0000-000000000002',6900);
SELECT test_assert(subtotal=5312.50 AND itbis_amount=956.25 AND service_fee=531.25
  AND total=6800 AND sale_totals_locked, 'venta6800 conserva total6800 con pago6900')
FROM fiscal_documents WHERE id='30000000-0000-0000-0000-000000000002';
SELECT test_assert(amount=6900 AND change_amount=0, 'el pago registrado6900 permanece intacto')
FROM payments WHERE fiscal_document_id='30000000-0000-0000-0000-000000000002';

-- El primer link de un cobro en dos métodos ya ve la venta completa.
INSERT INTO orders (id,delivery_fee) VALUES ('20000000-0000-0000-0000-000000000003', 0);
INSERT INTO order_items (order_id,unit_price) VALUES ('20000000-0000-0000-0000-000000000003',6800);
INSERT INTO fiscal_documents (id,business_id,order_id) VALUES
  ('30000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000003');
INSERT INTO payments (order_id,fiscal_document_id,amount) VALUES
  ('20000000-0000-0000-0000-000000000003','30000000-0000-0000-0000-000000000003',3000);
SELECT test_assert(total=6800, 'primer abono no prorratea el NCF emitido al cerrar')
FROM fiscal_documents WHERE id='30000000-0000-0000-0000-000000000003';
INSERT INTO payments (order_id,fiscal_document_id,amount) VALUES
  ('20000000-0000-0000-0000-000000000003','30000000-0000-0000-0000-000000000003',4000);
UPDATE payments SET change_amount=200 WHERE fiscal_document_id='30000000-0000-0000-0000-000000000003' AND amount=4000;
SELECT test_assert(total=6800 AND subtotal+itbis_amount+service_fee=total,
  'segundo abono y vuelto no cambian venta emitida')
FROM fiscal_documents WHERE id='30000000-0000-0000-0000-000000000003';

-- Oferta real del fixture: dos margaritas de 400, descuento400, paga400.
INSERT INTO orders (id,delivery_fee) VALUES ('20000000-0000-0000-0000-000000000004', 0);
INSERT INTO order_items (order_id,qty,quantity,unit_price,discounts) VALUES
  ('20000000-0000-0000-0000-000000000004',2,2,400,400);
SELECT test_assert(subtotal=625 AND tax=175 AND total=400, 'motor real conserva base predescuento 2x1')
FROM order_items WHERE order_id='20000000-0000-0000-0000-000000000004';
INSERT INTO fiscal_documents (id,business_id,order_id) VALUES
  ('30000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000004');
INSERT INTO payments (order_id,fiscal_document_id,amount) VALUES
  ('20000000-0000-0000-0000-000000000004','30000000-0000-0000-0000-000000000004',400);
SELECT test_assert(subtotal=625 AND itbis_amount=112.50 AND service_fee=62.50 AND total=400,
  'oferta 2x1 resta descuento una vez y conserva impuestos')
FROM fiscal_documents WHERE id='30000000-0000-0000-0000-000000000004';

-- Descuento sobre precio exclusive con cargo exento real de delivery.
INSERT INTO orders (id,delivery_fee) VALUES ('20000000-0000-0000-0000-000000000005',100);
INSERT INTO order_items (order_id,unit_price,tax_mode,discounts) VALUES
  ('20000000-0000-0000-0000-000000000005',295,'exclusive',75.52);
INSERT INTO fiscal_documents (id,business_id,order_id) VALUES
  ('30000000-0000-0000-0000-000000000005','10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000005');
INSERT INTO payments (order_id,fiscal_document_id,amount) VALUES
  ('20000000-0000-0000-0000-000000000005','30000000-0000-0000-0000-000000000005',402.08);
SELECT test_assert(subtotal=295 AND itbis_amount=53.10 AND service_fee=29.50
  AND delivery_fee=100 AND total=402.08, 'descuento exclusive y delivery exento conservan venta')
FROM fiscal_documents WHERE id='30000000-0000-0000-0000-000000000005';
UPDATE orders SET delivery_fee=900 WHERE id='20000000-0000-0000-0000-000000000005';
UPDATE payments SET amount=502.08 WHERE fiscal_document_id='30000000-0000-0000-0000-000000000005';
SELECT test_assert(delivery_fee=100 AND total=402.08, 'delivery emitido no sigue saldo actual de orden')
FROM fiscal_documents WHERE id='30000000-0000-0000-0000-000000000005';

-- Remanente: no repetir productos con comprobante o nota propios. Un check
-- autocerrado sin documento sí pertenece al comprobante de la orden.
INSERT INTO orders (id,delivery_fee) VALUES ('20000000-0000-0000-0000-000000000006',0);
INSERT INTO order_checks (id,order_id) VALUES
  ('40000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000006'),
  ('40000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000006'),
  ('40000000-0000-0000-0000-000000000003','20000000-0000-0000-0000-000000000006');
INSERT INTO order_items (order_id,check_id,unit_price,tax_rate) VALUES
  ('20000000-0000-0000-0000-000000000006',NULL,100,0),
  ('20000000-0000-0000-0000-000000000006','40000000-0000-0000-0000-000000000001',200,0),
  ('20000000-0000-0000-0000-000000000006','40000000-0000-0000-0000-000000000002',300,0),
  ('20000000-0000-0000-0000-000000000006','40000000-0000-0000-0000-000000000003',400,0);
INSERT INTO fiscal_documents (id,business_id,order_id,check_id,sale_totals_locked,total) VALUES
  ('30000000-0000-0000-0000-000000000061','10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000006','40000000-0000-0000-0000-000000000001',true,200);
INSERT INTO sales_notes (id,order_id,check_id) VALUES
  ('50000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000006','40000000-0000-0000-0000-000000000002');
INSERT INTO fiscal_documents (id,business_id,order_id) VALUES
  ('30000000-0000-0000-0000-000000000006','10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000006');
INSERT INTO payments (order_id,fiscal_document_id,amount) VALUES
  ('20000000-0000-0000-0000-000000000006','30000000-0000-0000-0000-000000000006',500);
SELECT test_assert(subtotal=500 AND total=500 AND itbis_amount=0 AND service_fee=0,
  'remanente excluye checks documentados e incluye check sin documento')
FROM fiscal_documents WHERE id='30000000-0000-0000-0000-000000000006';

-- Un documento de subcuenta solo toma sus ítems y no duplica delivery.
INSERT INTO fiscal_documents (id,business_id,order_id,check_id) VALUES
  ('30000000-0000-0000-0000-000000000063','10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000006','40000000-0000-0000-0000-000000000003');
UPDATE orders SET delivery_fee=100 WHERE id='20000000-0000-0000-0000-000000000006';
INSERT INTO payments (order_id,check_id,fiscal_document_id,amount) VALUES
  ('20000000-0000-0000-0000-000000000006','40000000-0000-0000-0000-000000000003',
   '30000000-0000-0000-0000-000000000063',450);
SELECT test_assert(total=400 AND delivery_fee=0, 'subcuenta conserva scope y no duplica delivery')
FROM fiscal_documents WHERE id='30000000-0000-0000-0000-000000000063';

DO $$
BEGIN
  -- Nunca fijar un scope diferente al documento.
  INSERT INTO fiscal_documents (id,business_id,order_id) VALUES
    ('30000000-0000-0000-0000-000000000007','10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000006');
  BEGIN
    PERFORM fn_recompute_fd_for_scope('30000000-0000-0000-0000-000000000007',
      '20000000-0000-0000-0000-000000000006','40000000-0000-0000-0000-000000000003');
    RAISE EXCEPTION 'FAIL: aceptó scope ajeno';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'FISCAL_DOCUMENT_SCOPE_MISMATCH' THEN RAISE; END IF;
    PERFORM test_assert(true, 'scope ajeno rechazado');
  END;
END;
$$;

-- Negocio sin configuración include_in_ecf: conserva respaldo por nombre.
INSERT INTO taxes VALUES
  ('10000000-0000-0000-0000-000000000002','ITBIS',18,true,true),
  ('10000000-0000-0000-0000-000000000002','Ley',10,true,true);
INSERT INTO orders (id,delivery_fee) VALUES ('20000000-0000-0000-0000-000000000007',0);
INSERT INTO order_items (order_id,unit_price,status) VALUES
  ('20000000-0000-0000-0000-000000000007',128,'paid'),
  ('20000000-0000-0000-0000-000000000007',128,'void');
INSERT INTO fiscal_documents (id,business_id,order_id) VALUES
  ('30000000-0000-0000-0000-000000000008','10000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000007');
INSERT INTO payments (order_id,fiscal_document_id,amount) VALUES
  ('20000000-0000-0000-0000-000000000007','30000000-0000-0000-0000-000000000008',128);
SELECT test_assert(subtotal=100 AND itbis_amount=18 AND service_fee=10 AND total=128,
  'respaldo por nombre conserva split de impuestos e ignora void')
FROM fiscal_documents WHERE id='30000000-0000-0000-0000-000000000008';

DO $$
BEGIN
  INSERT INTO orders (id,delivery_fee) VALUES ('20000000-0000-0000-0000-000000000008',0);
  INSERT INTO fiscal_documents (id,business_id,order_id) VALUES
    ('30000000-0000-0000-0000-000000000009','10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000008');
  BEGIN
    INSERT INTO payments (order_id,fiscal_document_id,amount) VALUES
      ('20000000-0000-0000-0000-000000000008','30000000-0000-0000-0000-000000000009',100);
    RAISE EXCEPTION 'FAIL: emitió mercancía sin productos';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'FISCAL_DOCUMENT_ITEMS_MISSING' THEN RAISE; END IF;
    PERFORM test_assert(true, 'no inventa mercancía a partir de pago sin ítems');
  END;
END;
$$;

-- RPC de preemisión con abono: la cuenta sigue abierta y admite productos.
-- Imita el cierre real: último pago, closeOrder y recálculo del FD existente
-- desde fn_issue_sale_document. El abono no congela una venta incompleta.
INSERT INTO orders (id,delivery_fee,closed_at) VALUES ('20000000-0000-0000-0000-000000000009',0,NULL);
INSERT INTO order_items (order_id,unit_price,tax_rate) VALUES
  ('20000000-0000-0000-0000-000000000009',500,0);
INSERT INTO fiscal_documents (id,business_id,order_id) VALUES
  ('30000000-0000-0000-0000-000000000010','10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000009');
INSERT INTO payments (order_id,fiscal_document_id,amount) VALUES
  ('20000000-0000-0000-0000-000000000009','30000000-0000-0000-0000-000000000010',200);
SELECT test_assert(total=500 AND NOT sale_totals_locked, 'abono preemitido no bloquea cuenta abierta')
FROM fiscal_documents WHERE id='30000000-0000-0000-0000-000000000010';

-- Un abono preexistente al despliegue conserva el importe al instalar, pero
-- puede crecer al consumirse más mercancía y cerrarse su cuenta después.
SELECT test_assert(subtotal=500 AND total=500 AND NOT sale_totals_locked,
  'preemisión antigua abierta conserva importes y no queda bloqueada al instalar')
FROM fiscal_documents WHERE id='30000000-0000-0000-0000-000000000011';
INSERT INTO order_items (order_id,unit_price,tax_rate) VALUES
  ('20000000-0000-0000-0000-000000000010',300,0);
INSERT INTO payments (order_id,fiscal_document_id,amount) VALUES
  ('20000000-0000-0000-0000-000000000010','30000000-0000-0000-0000-000000000011',600);
UPDATE orders SET closed_at=now() WHERE id='20000000-0000-0000-0000-000000000010';
SELECT fn_recompute_fd_for_scope('30000000-0000-0000-0000-000000000011','20000000-0000-0000-0000-000000000010',NULL);
SELECT test_assert(subtotal=800 AND total=800 AND sale_totals_locked,
  'preemisión antigua incluye consumos nuevos al cierre800')
FROM fiscal_documents WHERE id='30000000-0000-0000-0000-000000000011';
INSERT INTO order_items (order_id,unit_price,tax_rate) VALUES
  ('20000000-0000-0000-0000-000000000009',300,0);
INSERT INTO payments (order_id,fiscal_document_id,amount) VALUES
  ('20000000-0000-0000-0000-000000000009','30000000-0000-0000-0000-000000000010',600);
UPDATE orders SET closed_at=now() WHERE id='20000000-0000-0000-0000-000000000009';
SELECT fn_recompute_fd_for_scope('30000000-0000-0000-0000-000000000010','20000000-0000-0000-0000-000000000009',NULL);
SELECT test_assert(total=800 AND subtotal=800 AND sale_totals_locked,
  'cierre después de abono y alta adicional fija venta completa800')
FROM fiscal_documents WHERE id='30000000-0000-0000-0000-000000000010';
UPDATE payments SET amount=900 WHERE fiscal_document_id='30000000-0000-0000-0000-000000000010' AND amount=600;
SELECT test_assert(total=800, 'pago posterior al cierre no cambia venta definitiva800')
FROM fiscal_documents WHERE id='30000000-0000-0000-0000-000000000010';

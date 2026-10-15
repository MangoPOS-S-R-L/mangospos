set request.jwt.claim.sub='a0000000-0000-0000-0000-000000000001';
set request.jwt.claim.role='authenticated';
do $$
declare o uuid; a uuid; b uuid; r jsonb; op uuid; v bigint;
begin
 o:=review_empty_order();
 insert into order_items(order_id,check_id,product_name,qty,quantity,unit_price,tax_mode,tax_rate,discounts,notes,promotion_id)
 values(o,fn_get_or_create_check(o,1),'4x3 Presidente',8,8,250,'inclusive',28,500,
 '[DEAL:70000000-0000-4000-8000-000000000002]','70000000-0000-4000-8000-000000000002') returning id into a;
 perform test_assert((select total=1500 and notes like '%[DEAL_RULE:4:250.00]%' from order_items where id=a),'8 cervezas: dos paquetes de 750 y snapshot persistido');
 op:=gen_random_uuid(); select version into v from order_items where id=a;
 r:=fn_apply_order_edit(op,o,'qty',a,v,null,'{"qty":7}');
 perform test_assert(r->>'status'='applied','reducir una cerveza se aplica por API versionada');
 perform test_assert((select qty=7 and discounts=250 and total=1500 from order_items where id=a),'7 cervezas: un paquete y tres unidades, total 1500');
 perform fn_apply_order_edit(op,o,'qty',a,v,null,'{"qty":7}');
 perform test_assert((select qty=7 and discounts=250 and total=1500 from order_items where id=a),'reintentar no duplica ni prorratea descuento');
 perform fn_apply_order_edit(gen_random_uuid(),o,'qty',a,(select version from order_items where id=a),null,'{"qty":6}');
 perform test_assert((select qty=6 and discounts=250 and total=1250 from order_items where id=a),'6 cervezas: un paquete de 750 y dos de 250, no descuento proporcional');
 perform test_assert((select total=1250 and discounts=250 from order_checks where id=fn_get_or_create_check(o,1)),'la subcuenta guarda 1250 después de retirar dos botellas');
 -- La promoción se cambia después de vender. La venta usa su snapshot.
 update promotions set buy_quantity=2,pay_quantity=1 where id='70000000-0000-4000-8000-000000000002';
 perform fn_apply_order_edit(gen_random_uuid(),o,'details',a,(select version from order_items where id=a),null,
   '{"product_name":"4x3 Presidente","qty":4,"discounts":125,"is_takeout":false,"notes":"[DEAL:70000000-0000-4000-8000-000000000002]\n[REDUCCION:Error de digitación]"}');
 perform test_assert((select qty=4 and discounts=250 and total=750 and notes like '%[REDUCCION:%' and notes like '%[DEAL_RULE:4:250.00]%' from order_items where id=a),'4 cervezas: 750 aun con cliente que envia 125 y omite snapshot');
 perform test_assert((select total=750 and discounts=250 from order_checks where id=fn_get_or_create_check(o,1)),'el check guarda los mismos 750');
 perform fn_apply_order_edit(gen_random_uuid(),o,'qty',a,(select version from order_items where id=a),null,'{"qty":3}');
 perform test_assert((select discounts=0 and total=750 from order_items where id=a),'3 unidades no reciben una oferta fraccionada');
 perform fn_apply_order_edit(gen_random_uuid(),o,'qty',a,(select version from order_items where id=a),null,'{"qty":8}');
 perform test_assert((select discounts=500 and total=1500 from order_items where id=a),'volver a 8 restaura dos paquetes completos');
 update promotions set buy_quantity=4,pay_quantity=3 where id='70000000-0000-4000-8000-000000000002';
 -- Dos altas independientes agrupadas en pantalla: borrar una deja la otra.
 b:=fn_add_offer_deal(o,'60000000-0000-4000-8000-000000000001',4,250,'4x3 Presidente','70000000-0000-4000-8000-000000000002',1);
 -- fn_add_offer_deal usa precio 400 del menú del fixture: corregir SOLO el
 -- precio sintético para este escenario de cervezas de 250.
 update order_items set unit_price=250 where id=b;
 perform fn_apply_order_edit(gen_random_uuid(),o,'delete',a,(select version from order_items where id=a));
 perform test_assert((select qty=4 and discounts=250 and total=750 from order_items where id=b),'borrar un paquete no cambia el descuento del paquete restante');
 -- No cambia precios de productos normales, cortesías ni líneas cobradas.
 update order_items set notes=notes||E'\n[CORTESIA:autorizada]',discounts=1000 where id=b;
 perform fn_apply_order_edit(gen_random_uuid(),o,'details',b,(select version from order_items where id=b),null,
   '{"qty":3,"discounts":750,"notes":"[DEAL:70000000-0000-4000-8000-000000000002]\n[CORTESIA:autorizada]"}');
 perform test_assert((select discounts=750 and total=0 from order_items where id=b),'una cortesía explícita conserva el descuento autorizado');
 -- La pantalla puede agrupar DOS filas: mantener la primera oferta y
 -- reducir la segunda de 4 a 2 debe quitar TODO el descuento de esa segunda.
 o:=review_empty_order();
 a:=fn_add_offer_deal(o,'60000000-0000-4000-8000-000000000002',4,250,'4x3 Presidente','70000000-0000-4000-8000-000000000002',1);
 b:=fn_add_offer_deal(o,'60000000-0000-4000-8000-000000000002',4,250,'4x3 Presidente','70000000-0000-4000-8000-000000000002',1);
 perform test_assert((select sum(qty)=8 and sum(discounts)=500 and sum(total)=1500 from order_items where order_id=o),'dos filas de oferta comienzan con ocho botellas por 1500');
 perform fn_apply_order_edit(gen_random_uuid(),o,'details',b,(select version from order_items where id=b),null,
   '{"qty":2,"discounts":125,"notes":"[DEAL:70000000-0000-4000-8000-000000000002]\n[REDUCCION:Error de digitación]"}');
 perform test_assert((select qty=2 and discounts=0 and total=500 from order_items where id=b),'quitar dos de la segunda oferta elimina su descuento completo');
 perform test_assert((select qty=4 and discounts=250 and total=750 from order_items where id=a),'la primera oferta conserva el beneficio completo');
 perform test_assert((select total=1250 and discounts=250 from order_checks where id=fn_get_or_create_check(o,1)),'seis botellas en dos filas: una oferta y dos unidades normales, 1250');
 perform fn_apply_order_edit(gen_random_uuid(),o,'move',a,(select version from order_items where id=a),null,'{"check_position":2}');
 perform fn_apply_order_edit(gen_random_uuid(),o,'move',b,(select version from order_items where id=b),null,'{"check_position":2}');
 perform test_assert((select total=1250 and discounts=250 from order_checks where id=fn_get_or_create_check(o,2)),'al mover las seis botellas a subcuenta se conserva una sola oferta y total 1250');
end $$;

-- Legacy sin snapshot: resolver dos paquetes consolidados con su descuento
-- original. Se crea tras retirar temporalmente SOLO este trigger local.
alter table order_items disable trigger a00_offer_quantity_discount;
do $$ declare o uuid; a uuid; begin
 o:=review_empty_order();
 insert into order_items(order_id,check_id,qty,quantity,unit_price,tax_mode,tax_rate,discounts,notes,promotion_id)
 values(o,fn_get_or_create_check(o,1),8,8,250,'inclusive',28,500,
 '[DEAL:70000000-0000-4000-8000-000000000002]','70000000-0000-4000-8000-000000000002') returning id into a;
 perform set_config('review.legacy_offer',a::text,false);
end $$;
alter table order_items enable trigger a00_offer_quantity_discount;
do $$ declare a uuid:=current_setting('review.legacy_offer')::uuid; o uuid; begin
 select order_id into o from order_items where id=a;
 perform fn_apply_order_edit(gen_random_uuid(),o,'qty',a,(select version from order_items where id=a),null,'{"qty":4}');
 perform test_assert((select qty=4 and discounts=250 and total=750 from order_items where id=a),'legacy consolidado 8 a 4 conserva una oferta de 750');
end $$;

alter table order_items disable trigger a00_offer_quantity_discount;
do $$ declare o uuid; a uuid; begin
 o:=review_empty_order();
 insert into order_items(order_id,check_id,qty,quantity,unit_price,tax_mode,tax_rate,discounts,notes)
 values(o,fn_get_or_create_check(o,1),3,3,250,'inclusive',28,125,
 '[DEAL:70000000-0000-4000-8000-000000000002]') returning id into a;
 perform set_config('review.uncertain_offer',a::text,false);
end $$;
alter table order_items enable trigger a00_offer_quantity_discount;
do $$ declare a uuid:=current_setting('review.uncertain_offer')::uuid; begin
 begin
   perform fn_update_item_qty(a,2);
   raise exception 'FAIL: inventó una regla para una oferta legacy fraccionada';
 exception when raise_exception then
   if sqlerrm not like 'OFFER_RULE_SNAPSHOT_REQUIRED:%' then raise; end if;
 end;
 perform test_assert((select qty=3 and discounts=125 from order_items where id=a),'una oferta legacy incierta se rechaza sin cambiar su dinero');
end $$;

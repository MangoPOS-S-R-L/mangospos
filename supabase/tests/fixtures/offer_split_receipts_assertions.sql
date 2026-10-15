set request.jwt.claim.sub='a0000000-0000-0000-0000-000000000001';
set request.jwt.claim.role='authenticated';
do $$
declare o uuid; a uuid;b uuid; plain uuid; ch uuid; r jsonb; op uuid; count_before int; amount_before numeric;
begin
 o:=review_empty_order();a:=review_offer(o);b:=review_offer(o);
 perform test_assert((select count(*)=2 and sum(qty)=4 and sum(discounts)=800 and sum(total)=800 from order_items where order_id=o),'dos ofertas: dos paquetes y dinero correcto');
 perform test_assert(fn_explode_items_for_split(o)=0,'la RPC segura no parte ofertas');
 perform test_assert(fn_explode_items_to_units(o)=0,'los clientes antiguos también conservan ofertas completas');
 perform set_config('request.jwt.claim.sub','a0000000-0000-0000-0000-000000000004',true);
 begin
  perform fn_explode_items_for_split(o);
  raise exception 'FAIL: permitió dividir una cuenta de otro negocio';
 exception when insufficient_privilege then null; end;
 perform set_config('request.jwt.claim.sub','a0000000-0000-0000-0000-000000000001',true);
 perform test_assert((select count(*)=2 from order_items where order_id=o),'un extraño no puede dividir ni alterar la cuenta');
 insert into order_items(order_id,check_id,product_name,qty,quantity,unit_price,tax_mode,tax_rate)
 values(o,fn_get_or_create_check(o,1),'Producto normal',3,3,100,'inclusive',28) returning id into plain;
 perform test_assert(fn_explode_items_for_split(o)=2,'los productos normales siguen separándose en unidades');
 perform test_assert((select count(*)=2 and bool_and(qty=2 and discounts=400) from order_items where order_id=o and position('[DEAL:' in coalesce(notes,''))>0),'la separación mixta conserva ambas ofertas y sus descuentos');
 perform fn_apply_order_edit(gen_random_uuid(),o,'consolidate_check',fn_get_or_create_check(o,1));
 perform test_assert((select count(*)=2 from order_items where id in(a,b)),'consolidar no une ni elimina paquetes de oferta');
 perform test_assert((select count(*)=1 and sum(qty)=3 from order_items where order_id=o and notes is null),'la consolidación normal sigue funcionando');
 -- Mover los dos paquetes a subcuentas mediante la misma API que la app.
 r:=fn_apply_order_edit(gen_random_uuid(),o,'move',a,(select version from order_items where id=a),null,'{"check_position":2}');
 perform test_assert(r->>'status'='applied','mover una oferta entera se aplica');
 r:=fn_apply_order_edit(gen_random_uuid(),o,'move',b,(select version from order_items where id=b),null,'{"check_position":3}');
 perform test_assert(r->>'status'='applied','la segunda oferta conserva su identidad al mover');
 op:=gen_random_uuid();
 r:=fn_apply_order_edit(op,o,'delete',b,(select version from order_items where id=b));
 perform test_assert(r->>'status'='applied','eliminar un paquete completo se aplica');
 perform fn_apply_order_edit(op,o,'delete',b,null);
 perform test_assert((select qty=2 and discounts=400 and total=400 from order_items where id=a),'la oferta restante conserva cantidad, descuento y total');
 perform test_assert(not exists(select 1 from order_items where id=b),'el replay de eliminación no resta otro paquete');
 perform test_assert((select count(*)=2 from order_item_client_ops where order_id=o),'la bitácora de altas no se borra al dividir/eliminar');
 perform test_assert(not has_function_privilege('anon','public.fn_explode_items_for_split(uuid)','execute') and has_function_privilege('authenticated','public.fn_explode_items_for_split(uuid)','execute'),'permisos de la RPC segura');
 -- Un documento ya emitido sigue impidiendo eliminar productos facturados.
 insert into fiscal_documents(order_id,check_id,ncf_number,total) values(o,fn_get_or_create_check(o,2),'REPRO-ONLY',400);
 begin
  perform fn_apply_order_edit(gen_random_uuid(),o,'delete',a,(select version from order_items where id=a));
  raise exception 'FAIL: permitió eliminar una oferta facturada';
 exception when sqlstate 'MP404' then null; end;
 perform test_assert(exists(select 1 from order_items where id=a),'el comprobante emitido conserva sus productos');
end $$;

set request.jwt.claim.sub='a0000000-0000-0000-0000-000000000001';
set request.jwt.claim.role='authenticated';
do $$ declare o uuid;a uuid;b uuid;n uuid:=gen_random_uuid();op uuid:=gen_random_uuid();payload jsonb;r jsonb;v bigint;begin
 o:=review_empty_order();
 a:=fn_add_offer_deal(o,'60000000-0000-4000-8000-000000000002',4,250,'4x3 Presidente','70000000-0000-4000-8000-000000000002',1);
 b:=fn_add_offer_deal(o,'60000000-0000-4000-8000-000000000002',4,250,'4x3 Presidente','70000000-0000-4000-8000-000000000002',1);
 select version into v from order_items where id=a;
 payload:=jsonb_build_array(
   jsonb_build_object('kind','details','item_id',a,'base_version',v,'args',jsonb_build_object('qty',3,'discounts',0,'notes',(select notes from order_items where id=a))),
   jsonb_build_object('kind','details','item_id',b,'base_version',99999,'args','{"qty":2}'::jsonb));
 r:=fn_apply_order_item_group(op,o,payload);
 perform test_assert(r->>'status'='conflict','un conflicto en segunda fila rechaza todo el grupo');
 perform test_assert((select qty=4 and discounts=250 and version=v from order_items where id=a),'la primera fila y su versión se revierten');
 perform test_assert(not exists(select 1 from order_group_edit_ops where op_id=op),'un conflicto no consume la llave de reintento');
 payload:=jsonb_build_array(
   jsonb_build_object('kind','details','item_id',a,'base_version',v,'args',jsonb_build_object('qty',4,'discounts',250,'notes',(select notes from order_items where id=a))),
   jsonb_build_object('kind','details','item_id',b,'base_version',(select version from order_items where id=b),'args',jsonb_build_object('qty',4,'discounts',250,'notes',(select notes from order_items where id=b))),
   jsonb_build_object('kind','add','item_id',n,'source_id',b,'args',jsonb_build_object('qty',4,'notes',(select notes from order_items where id=b))));
 r:=fn_apply_order_item_group(op,o,payload);
 perform test_assert(r->>'status'='applied','aumento de 8 a 12 aplica en una transacción');
 perform test_assert((select sum(qty)=12 and sum(discounts)=750 and sum(total)=2250 from order_items where order_id=o),'12 botellas conservan tres ofertas completas por 2250');
 perform test_assert((select qty=4 and status::text='draft' from order_items where id=n),'la ronda nueva de cuatro queda por enviar');
 r:=fn_apply_order_item_group(op,o,payload);
 perform test_assert(r->>'replayed'='true' and (select count(*)=3 from order_items where order_id=o),'respuesta perdida no crea otra ronda');
 -- La oferta sigue cumpliéndose aunque las unidades estén en rondas 3+1.
 o:=review_empty_order(); a:=fn_add_offer_deal(o,'60000000-0000-4000-8000-000000000002',4,250,'4x3 Presidente','70000000-0000-4000-8000-000000000002',1);
 perform fn_update_item_qty(a,3);
 update order_items set status='pending' where id=a;
 n:=gen_random_uuid();
 payload:=jsonb_build_array(
  jsonb_build_object('kind','details','item_id',a,'base_version',(select version from order_items where id=a),'args',jsonb_build_object('qty',3,'discounts',0,'notes',(select notes from order_items where id=a))),
  jsonb_build_object('kind','add','item_id',n,'source_id',a,'args',jsonb_build_object('qty',1)));
 perform fn_apply_order_item_group(gen_random_uuid(),o,payload);
 perform test_assert((select sum(qty)=4 and sum(discounts)=250 and sum(total)=750 from order_items where order_id=o),'rondas de tres y una completan una oferta, sin duplicar cocina');
 perform test_assert((select qty=3 and status::text='pending' from order_items where id=a),'la ronda ya enviada conserva tres unidades');
 perform test_assert((select qty=1 and status::text='draft' from order_items where id=n),'solo la unidad nueva queda por enviar');
 -- Separar las rondas cambia su elegibilidad por subcuenta; no queda
 -- una botella gratis aislada en otra cuenta después del traslado.
 perform fn_apply_order_edit(gen_random_uuid(),o,'move',n,(select version from order_items where id=n),null,'{"check_position":2}');
 perform test_assert((select sum(discounts)=0 and sum(total)=1000 from order_items where order_id=o),'mover la unidad a otra subcuenta retira la oferta incompleta de ambas');
 perform fn_apply_order_edit(gen_random_uuid(),o,'move',n,(select version from order_items where id=n),null,'{"check_position":1}');
 perform test_assert((select sum(discounts)=250 and sum(total)=750 from order_items where order_id=o),'al reunir tres y una se recupera una oferta completa');
 -- Error de validación en una acción posterior: tampoco queda media edición.
 select version into v from order_items where id=a;
 begin
   perform fn_apply_order_item_group(gen_random_uuid(),o,jsonb_build_array(
    jsonb_build_object('kind','details','item_id',a,'base_version',v,'args',jsonb_build_object('qty',2,'discounts',0,'notes',(select notes from order_items where id=a))),
    jsonb_build_object('kind','unknown')));
   raise exception 'FAIL: permitió una acción inválida';
 exception when invalid_parameter_value then null; end;
 perform test_assert((select qty=3 and version=v from order_items where id=a),'un error SQL posterior revierte también la primera fila');
 perform set_config('request.jwt.claim.sub','a0000000-0000-0000-0000-000000000004',true);
 begin perform fn_apply_order_item_group(gen_random_uuid(),o,payload); raise exception 'FAIL: acceso de otro negocio'; exception when insufficient_privilege then null; end;
 perform test_assert(not has_function_privilege('anon','public.fn_apply_order_item_group(uuid,uuid,jsonb,boolean)','execute'),'anon no puede ejecutar lotes');
end $$;

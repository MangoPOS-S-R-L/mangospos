-- Caso real: tres jugos en una línea deben poder repartirse uno a uno.
alter table order_items add column if not exists print_area_code text;
alter table order_items add column if not exists started_at timestamptz;
alter table order_items add column if not exists ready_at timestamptz;
set request.jwt.claim.sub='a0000000-0000-0000-0000-000000000001';
set request.jwt.claim.role='authenticated';
do $$ declare o uuid;c uuid;a uuid;b uuid;r jsonb;p jsonb;n integer;frozen jsonb;
begin
  o:=review_empty_order();c:=fn_get_or_create_check(o,1);
  insert into order_items(order_id,check_id,product_name,qty,quantity,unit_price,tax_mode,tax_rate,
    status,kitchen_sent_at,started_at,ready_at,print_area_code,created_by_employee_id,notes)
    values(o,c,'JUGOS NATURALES',3,3,250,'inclusive',28,'served',now()-interval '15 minutes',
      now()-interval '12 minutes',now()-interval '10 minutes','bar',
      '82000000-0000-4000-8000-000000000001','Sin azúcar') returning id into a;
  n:=fn_explode_items_for_split(o);
  perform test_assert(n=2 and (select count(*)=3 and bool_and(qty=1) and sum(total)=750 from order_items where order_id=o),
    'tres jugos son tres filas por 750, conservando el ID original');
  perform test_assert(exists(select 1 from order_items where id=a) and
    (select bool_and(status::text='served' and kitchen_sent_at=now()-interval '15 minutes'
      and started_at=now()-interval '12 minutes' and ready_at=now()-interval '10 minutes'
      and print_area_code='bar' and notes='Sin azúcar'
      and created_by_employee_id='82000000-0000-4000-8000-000000000001') from order_items where order_id=o),
    'preparar unidades conserva cocina, tiempos, ruta, autor y notas; no vuelve a enviarlas');
  perform test_assert(fn_explode_items_for_split(o)=0 and (select count(*)=3 from order_items where order_id=o),
    'perder la respuesta y reintentar no crea más jugos');
  select id into b from order_items where order_id=o and id<>a order by id limit 1;
  p:=jsonb_build_array(jsonb_build_object('item_id',a,'base_version',(select version from order_items where id=a),'target_position',2),
    jsonb_build_object('item_id',b,'base_version',(select version from order_items where id=b),'target_position',3));
  r:=fn_apply_bill_split(gen_random_uuid(),o,p,'[{"position":2},{"position":3}]');
  perform test_assert(r->>'status'='applied' and (select count(distinct check_id)=3 and sum(qty)=3 and sum(total)=750 from order_items where order_id=o)
    and (select qty=1 and total=250 from order_items where id=a) and (select qty=1 and total=250 from order_items where id=b),
    'se mueve un jugo a C2, otro a C3 y el tercero queda en la principal');

  o:=review_empty_order();c:=fn_get_or_create_check(o,1);
  insert into order_items(order_id,check_id,product_name,qty,quantity,unit_price,tax_mode,tax_rate,status)
    values(o,c,'Tres con extra',3,3,200,'inclusive',28,'pending') returning id into a;
  insert into order_item_modifiers(item_id,name,qty,price,menu_item_id,modifier_id)
    values(a,'Extra',1,50,'60000000-0000-4000-8000-000000000002','80000000-0000-4000-8000-000000000001');
  update order_items set unit_price=unit_price where id=a;
  n:=fn_explode_items_for_split(o);
  perform test_assert(n=2 and (select count(*)=3 and sum(total)=750 and bool_and(qty=1 and tax_mode='inclusive' and tax_rate=28 and status::text='pending')
    from order_items where order_id=o),'los extras también se separan y tres por 250 conservan 750');
  perform test_assert((select count(*)=3 and bool_and(m.qty=1 and m.price=50
      and m.menu_item_id='60000000-0000-4000-8000-000000000002' and m.modifier_id='80000000-0000-4000-8000-000000000001')
    from order_item_modifiers m join order_items i on i.id=m.item_id where i.order_id=o),
    'cada unidad conserva el extra completo y sus identidades de inventario');

  o:=review_empty_order();c:=fn_get_or_create_check(o,1);
  insert into order_items(order_id,check_id,product_name,qty,quantity,unit_price,tax_mode,tax_rate,discounts)
    values(o,c,'Descuento pequeño',5,5,0.01,'exclusive',60,0.03) returning id into a;
  insert into order_item_tax_lines(order_item_id,tax_id,tax_name,tax_rate,amount)
    values(a,'81000000-0000-4000-8000-000000000001','Impuesto histórico',60,0.03);
  perform fn_explode_items_for_split(o);
  perform test_assert((select count(*)=5 and sum(discounts)=0.03 and min(discounts)>=0 and sum(total)=0.05
    from order_items where order_id=o),'el descuento de tres centavos se reparte sin residuo negativo ni cambio de importe');
  perform test_assert((select count(*)=5 and sum(t.amount)=0.03 and min(t.amount)>=0 and bool_and(t.tax_name='Impuesto histórico' and t.tax_rate=60)
    from order_item_tax_lines t join order_items i on i.id=t.order_item_id where i.order_id=o),
    'el snapshot fiscal conserva sus tres centavos exactos, nombre y tasa');

  o:=review_empty_order();a:=fn_add_offer_deal(o,'60000000-0000-4000-8000-000000000002',4,250,'4x3 Presidente',
    '70000000-0000-4000-8000-000000000002',1);
  select to_jsonb(i) into frozen from order_items i where id=a;
  insert into order_items(order_id,check_id,product_name,qty,quantity,unit_price,tax_mode,tax_rate)
    values(o,fn_get_or_create_check(o,1),'Jugos junto a oferta',3,3,250,'inclusive',28);
  perform fn_explode_items_for_split(o);
  perform test_assert((select to_jsonb(i)=frozen and qty=4 and total=750 from order_items i where id=a)
    and (select count(*)=4 and sum(total)=1500 from order_items where order_id=o),
    'preparar tres jugos no rompe ni reinterpreta una oferta 4x3');

  o:=review_empty_order();c:=fn_get_or_create_check(o,2);
  insert into order_items(order_id,check_id,product_name,qty,quantity,unit_price,tax_mode,tax_rate,status)
    values(o,c,'Facturado',3,3,250,'inclusive',28,'pending') returning id into a;
  insert into fiscal_documents(order_id,check_id,ncf_number,status,total) values(o,c,'B02-UNIT-PROTECTED','active',750);
  select to_jsonb(i) into frozen from order_items i where id=a;
  perform test_assert(fn_explode_items_for_split(o)=0 and (select to_jsonb(i)=frozen from order_items i where id=a),
    'la preparación no fracciona productos con comprobante aunque el check siga abierto');
  update orders set closed_at=now() where id=o;
  begin perform fn_explode_items_for_split(o);raise exception 'FAIL: preparó orden cerrada';
    exception when raise_exception then if sqlerrm<>'ORDER_CLOSED' then raise; end if; end;
  perform set_config('request.jwt.claim.sub','a0000000-0000-0000-0000-000000000004',true);
  begin perform fn_explode_items_for_split(o);raise exception 'FAIL: preparó orden ajena';
    exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub','a0000000-0000-0000-0000-000000000001',true);
  perform test_assert(not has_function_privilege('anon','public.fn_explode_items_for_split(uuid)','execute'),
    'la preparación mantiene autorización por negocio y acceso anónimo revocado');
end $$;

-- Un fallo posterior (por ejemplo, inventario) revierte también la primera unidad.
create function pg_temp.reject_split_unit() returns trigger language plpgsql as $$
begin if new.notes='REJECT_SPLIT_UNIT' and new.qty=1 then raise exception 'UNIT_INSERT_REJECTED'; end if; return new; end $$;
create trigger review_reject_split_unit before insert on order_items for each row execute function pg_temp.reject_split_unit();
do $$ declare o uuid;a uuid;frozen jsonb; begin
  o:=review_empty_order();
  insert into order_items(order_id,check_id,product_name,qty,quantity,unit_price,tax_mode,tax_rate,notes)
    values(o,fn_get_or_create_check(o,1),'No guardar parcialmente',3,3,250,'inclusive',28,'REJECT_SPLIT_UNIT') returning id into a;
  select to_jsonb(i) into frozen from order_items i where id=a;
  begin perform fn_explode_items_for_split(o);raise exception 'FAIL: no rechazó inserción';
    exception when raise_exception then if sqlerrm<>'UNIT_INSERT_REJECTED' then raise; end if; end;
  perform test_assert((select count(*)=1 and sum(qty)=3 and sum(total)=750 from order_items where order_id=o)
    and (select to_jsonb(i)=frozen from order_items i where id=a),
    'fallar al crear otra unidad revierte cantidad, dinero y versión de la original');
end $$;
drop trigger review_reject_split_unit on order_items;

set request.jwt.claim.sub='a0000000-0000-0000-0000-000000000001';
set request.jwt.claim.role='authenticated';
create table if not exists public.customers(id uuid primary key,business_id uuid);
create table if not exists public.order_item_tax_lines(id uuid primary key default gen_random_uuid(),
  order_item_id uuid references order_items(id) on delete cascade,tax_id uuid,tax_name text,
  tax_rate numeric,amount numeric,created_at timestamptz default now());
insert into customers values('90000000-0000-4000-8000-000000000001','b0000000-0000-0000-0000-000000000001');
do $$ declare o uuid;c uuid;a uuid;b uuid;v bigint;r jsonb;op uuid;p jsonb;checks jsonb;before_amount numeric;frozen jsonb;
begin
  o:=review_empty_order();c:=fn_get_or_create_check(o,1);
  insert into order_items(order_id,check_id,product_name,qty,quantity,unit_price,tax_mode,tax_rate)
    values(o,c,'Producto con extra',2,2,250,'inclusive',28) returning id into a;
  insert into order_item_modifiers(item_id,name,qty,price,modifier_id)
    values(a,'Extra por unidad',1,50,'80000000-0000-4000-8000-000000000001');
  update order_items set unit_price=unit_price where id=a;
  insert into order_item_tax_lines(order_item_id,tax_id,tax_name,tax_rate,amount)
    values(a,'81000000-0000-4000-8000-000000000001','Impuesto histórico',28,131.25);
  select sum(total) into before_amount from order_items where order_id=o;
  op:=gen_random_uuid();
  r:=fn_apply_bill_split(op,o,p_equal_people=>2);
  perform test_assert(r->>'status'='applied','igualitaria atómica aplica');
  perform test_assert((select sum(total)=600 and sum(qty)=2 and bool_and(tax_mode='inclusive' and tax_rate=28)
    from order_items where order_id=o),'extras e impuestos: 600 sigue siendo 600');
  perform test_assert((select count(*)=2 and bool_and(m.qty=1 and m.modifier_id='80000000-0000-4000-8000-000000000001')
    from order_item_modifiers m join order_items i on i.id=m.item_id where i.order_id=o),'extras conservan cantidad por unidad e identidad de inventario');
  perform test_assert((select count(*)=2 and bool_and(t.tax_name='Impuesto histórico' and t.tax_rate=28)
    from order_item_tax_lines t join order_items i on i.id=t.order_item_id where i.order_id=o),
    'el desglose conserva nombre y tasa de la venta, sin releer catálogo');
  r:=fn_apply_bill_split(op,o,p_equal_people=>2);
  perform test_assert(r->>'replayed'='true' and (select count(*)=2 from order_items where order_id=o),'reintento igualitario no vuelve a dividir');
  begin perform fn_apply_bill_split(op,o,p_equal_people=>3);raise exception 'FAIL: reutilizó llave'; exception when sqlstate 'MP430' then null; end;

  o:=review_empty_order();c:=fn_get_or_create_check(o,2);
  insert into order_items(order_id,check_id,product_name,qty,quantity,unit_price,tax_mode,tax_rate,status)
    values(o,c,'Ya cobrado',1,1,100,'inclusive',0,'paid');
  update order_checks set is_closed=true,closed_at=now() where id=c;
  insert into fiscal_documents(order_id,check_id,ncf_number,status) values(o,c,'B02-SPLIT','active');
  select to_jsonb(x) into frozen from order_checks x where id=c;
  insert into order_items(order_id,check_id,product_name,qty,quantity,unit_price,tax_mode,tax_rate)
    values(o,fn_get_or_create_check(o,1),'Abierto A',1,1,100,'inclusive',0),
          (o,fn_get_or_create_check(o,1),'Abierto B',1,1,100,'inclusive',0);
  perform fn_split_items_equally(o,2);
  perform test_assert((select to_jsonb(x)=frozen from order_checks x where id=c),'C2 cobrada permanece idéntica');
  perform test_assert(not exists(select 1 from order_items where check_id=c and status::text<>'paid'),
    'productos nuevos usan C3/C4, nunca C2 facturada');

  o:=review_empty_order();c:=fn_get_or_create_check(o,1);
  insert into order_items(order_id,check_id,product_name,qty,quantity,unit_price,tax_mode,tax_rate)
    values(o,c,'A',1,1,100,'inclusive',0) returning id into a;
  insert into order_items(order_id,check_id,product_name,qty,quantity,unit_price,tax_mode,tax_rate)
    values(o,c,'B',1,1,100,'inclusive',0) returning id into b;
  select version into v from order_items where id=a;
  checks:='[{"position":2,"write_metadata":true,"customer_id":"90000000-0000-4000-8000-000000000001","customer_name":"Ana","customer_rnc":"101010101","requested_ncf_type":"B01"},{"position":3}]';
  p:=jsonb_build_array(jsonb_build_object('item_id',a,'base_version',v,'target_position',2),
    jsonb_build_object('item_id',b,'base_version',999999,'target_position',3));
  op:=gen_random_uuid(); r:=fn_apply_bill_split(op,o,p,checks);
  perform test_assert(r->>'status'='conflict' and (select check_id=c and version=v from order_items where id=a),
    'conflicto posterior revierte el primer traslado y su versión');
  perform test_assert((select count(*)=1 from order_checks where order_id=o) and not exists(select 1 from bill_split_ops where op_id=op),
    'conflicto revierte cuentas y datos fiscales y no consume llave');
  p:=jsonb_set(p,'{1,base_version}',to_jsonb((select version from order_items where id=b)));
  r:=fn_apply_bill_split(op,o,p,checks);
  perform test_assert(r->>'status'='applied' and (select count(distinct check_id)=2 from order_items where order_id=o),
    'ambos destinos se confirman juntos');
  perform test_assert(exists(select 1 from order_checks where order_id=o and position=2 and customer_name='Ana'
    and customer_rnc='101010101' and requested_ncf_type::text='B01'),'cliente, RNC y comprobante nuevo se guardan en la misma transacción');
  r:=fn_apply_bill_split(op,o,p,checks);
  perform test_assert(r->>'replayed'='true','reintento manual devuelve el resultado sin repetir movimientos');

  -- Intercambiar no puede cerrar el destino en mitad del proceso.
  p:=jsonb_build_array(jsonb_build_object('item_id',a,'base_version',(select version from order_items where id=a),'target_position',3),
    jsonb_build_object('item_id',b,'base_version',(select version from order_items where id=b),'target_position',2));
  r:=fn_apply_bill_split(gen_random_uuid(),o,p);
  perform test_assert(r->>'status'='applied' and (select check_id=(select id from order_checks where order_id=o and position=3) from order_items where id=a)
    and (select check_id=(select id from order_checks where order_id=o and position=2) from order_items where id=b),
    'intercambio conserva ambos destinos con autocierre y guard reales');
  -- Un borrado con un producto concurrente rechaza TODO.
  p:=jsonb_build_array(jsonb_build_object('item_id',a,'base_version',(select version from order_items where id=a),'target_position',1));
  select check_id into c from order_items where id=b;
  r:=fn_apply_bill_split(gen_random_uuid(),o,p,p_deleted_check_ids=>array[c]);
  perform test_assert(r->>'reason'='check_not_empty' and (select check_id is not null from order_items where id=a),
    'no elimina una subcuenta que recibió productos ni deja movimientos parciales');
  -- Fuerza explícita no permite tocar una cuenta cobrada.
  update order_items set status='paid' where id=b;
  r:=fn_apply_bill_split(gen_random_uuid(),o,jsonb_build_array(jsonb_build_object('item_id',b,'target_position',1)),p_force=>true);
  perform test_assert(r->>'reason'='item_closed','forzar no mueve productos cobrados');

  o:=review_empty_order();c:=fn_get_or_create_check(o,1);
  insert into order_items(order_id,check_id,product_name,qty,quantity,unit_price,tax_mode,tax_rate)
    values(o,c,'Iguales',1,1,100,'inclusive',0) returning id into a;
  insert into order_items(order_id,check_id,product_name,qty,quantity,unit_price,tax_mode,tax_rate)
    values(o,c,'Iguales',1,1,100,'inclusive',0) returning id into b;
  p:=jsonb_build_array(jsonb_build_object('item_id',a,'base_version',(select version from order_items where id=a),'target_position',3),
    jsonb_build_object('item_id',b,'base_version',(select version from order_items where id=b),'target_position',3));
  perform fn_apply_bill_split(gen_random_uuid(),o,p,'[{"position":3}]');
  perform test_assert((select count(*)=2 and sum(qty)=2 and sum(total)=200 and count(distinct check_id)=1
    from order_items where id in(a,b)),'unir conserva las dos filas físicas y traslada ambas');

  perform set_config('request.jwt.claim.sub','a0000000-0000-0000-0000-000000000004',true);
  begin perform fn_split_items_equally(o,2);raise exception 'FAIL: ajeno igualitaria'; exception when insufficient_privilege then null; end;
  begin perform fn_apply_bill_split(gen_random_uuid(),o);raise exception 'FAIL: ajeno manual'; exception when insufficient_privilege then null; end;
  perform test_assert(not has_function_privilege('anon','public.fn_split_items_equally(uuid,integer)','execute')
    and not has_function_privilege('anon','public.fn_apply_bill_split(uuid,uuid,jsonb,jsonb,uuid[],bigint,integer,boolean)','execute'),
    'anon no puede dividir y los usuarios ajenos son rechazados');
  perform set_config('request.jwt.claim.sub','a0000000-0000-0000-0000-000000000001',true);
end $$;

-- Metadatos concurrentes, ofertas entre destinos y perfil exclusivo real.
do $$ declare o uuid;c uuid;a uuid;b uuid;r jsonb;p jsonb;meta jsonb;before_amount numeric;
begin
  o:=review_empty_order();c:=fn_get_or_create_check(o,2);
  update order_checks set customer_name='Cliente actual',customer_rnc='123456789',requested_ncf_type='B01' where id=c;
  insert into order_items(order_id,check_id,product_name,qty,quantity,unit_price,tax_mode,tax_rate)
    values(o,c,'A',1,1,100,'inclusive',0) returning id into a;
  p:=jsonb_build_array(jsonb_build_object('item_id',a,'base_version',(select version from order_items where id=a),'target_position',3));
  meta:=jsonb_build_array(jsonb_build_object('id',c,'position',2,'write_metadata',true,'customer_name','Cliente viejo',
    'expected_metadata',jsonb_build_object('customer_id',null,'customer_name','Anterior','customer_rnc',null,'requested_ncf_type',null)));
  r:=fn_apply_bill_split(gen_random_uuid(),o,p,meta);
  perform test_assert(r->>'reason'='stale_version' and (select customer_name='Cliente actual' and customer_rnc='123456789' from order_checks where id=c)
    and (select check_id=c from order_items where id=a),'cliente fiscal cambiado por otro equipo no se sobreescribe ni mueve productos');
  r:=fn_apply_bill_split(gen_random_uuid(),o,p,meta #- '{0,expected_metadata}');
  perform test_assert(r->>'reason'='stale_version','sin snapshot no se sobreescriben metadatos existentes');
  meta:=jsonb_build_array(jsonb_build_object('id',c,'position',2,'write_metadata',true,
    'expected_metadata',(select jsonb_build_object('customer_id',customer_id,'customer_name',customer_name,
      'customer_rnc',customer_rnc,'requested_ncf_type',requested_ncf_type) from order_checks where id=c)));
  r:=fn_apply_bill_split(gen_random_uuid(),o,p_checks=>meta);
  perform test_assert(r->>'status'='applied' and (select customer_id is null and customer_name is null and customer_rnc is null
    and requested_ncf_type is null from order_checks where id=c),'retirar cliente y comprobante también se confirma sin valores residuales');

  o:=review_empty_order();c:=fn_get_or_create_check(o,1);
  insert into order_items(order_id,check_id,product_id,product_name,qty,quantity,unit_price,tax_mode,tax_rate,notes,promotion_id)
    values(o,c,'60000000-0000-4000-8000-000000000002','4x3 Presidente',3,3,250,'inclusive',28,
      '[DEAL:70000000-0000-4000-8000-000000000002] [DEAL_RULE:4:250.00]',
      '70000000-0000-4000-8000-000000000002') returning id into a;
  insert into order_items(order_id,check_id,product_id,product_name,qty,quantity,unit_price,tax_mode,tax_rate,notes,promotion_id)
    values(o,c,'60000000-0000-4000-8000-000000000002','4x3 Presidente',1,1,250,'inclusive',28,
      '[DEAL:70000000-0000-4000-8000-000000000002] [DEAL_RULE:4:250.00]',
      '70000000-0000-4000-8000-000000000002') returning id into b;
  perform fn_reprice_order_offer_groups(o);
  perform test_assert((select sum(total)=750 from order_items where order_id=o),'3+1 juntas califican para una oferta completa');
  p:=jsonb_build_array(jsonb_build_object('item_id',a,'base_version',(select version from order_items where id=a),'target_position',2),
    jsonb_build_object('item_id',b,'base_version',(select version from order_items where id=b),'target_position',3));
  r:=fn_apply_bill_split(gen_random_uuid(),o,p,'[{"position":2},{"position":3}]');
  perform test_assert(r->>'status'='applied' and (select sum(total)=1000 and sum(discounts)=0 from order_items where order_id=o)
    and (select total=750 from order_checks where order_id=o and position=2)
    and (select total=250 from order_checks where order_id=o and position=3),'3 y 1 separadas: 750+250 y ningún beneficio fraccionado');
  p:=jsonb_build_array(jsonb_build_object('item_id',b,'base_version',(select version from order_items where id=b),'target_position',2));
  r:=fn_apply_bill_split(gen_random_uuid(),o,p);
  perform test_assert(r->>'status'='applied' and (select sum(total)=750 and sum(qty)=4 from order_items where order_id=o),
    'reunir restaura una oferta y conserva las cuatro botellas');

  o:=review_empty_order();c:=fn_get_or_create_check(o,1);
  insert into order_items(order_id,check_id,product_name,qty,quantity,unit_price,tax_mode,tax_rate)
    values(o,c,'Producto exclusivo',2,2,250,'exclusive',18) returning id into a;
  insert into order_item_modifiers(item_id,name,qty,price,modifier_id)
    values(a,'Extra por unidad',1,50,'80000000-0000-4000-8000-000000000001');
  update order_items set unit_price=unit_price where id=a;
  select sum(total) into before_amount from order_items where order_id=o;
  r:=fn_apply_bill_split(gen_random_uuid(),o,p_equal_people=>2);
  perform test_assert(r->>'status'='applied' and (select sum(total)=before_amount and bool_and(tax_mode='exclusive' and tax_rate=18)
    from order_items where order_id=o),'igualitaria conserva el importe y perfil exclusivo con extras');

  o:=review_empty_order();c:=fn_get_or_create_check(o,2);
  insert into order_items(order_id,check_id,product_name,qty,quantity,unit_price,tax_mode,tax_rate,discounts,notes)
    values(o,c,'4x3 histórico facturado',4,4,250,'inclusive',28,250,
      '[DEAL:70000000-0000-4000-8000-000000000002] [DEAL_RULE:4:250.00]') returning id into a;
  update order_items set discounts=400 where id=a;
  insert into fiscal_documents(order_id,check_id,ncf_number,status,total) values(o,c,'B02-PROTECTED-OPEN','active',600);
  insert into order_items(order_id,check_id,product_name,qty,quantity,unit_price,tax_mode,tax_rate)
    values(o,fn_get_or_create_check(o,1),'Nuevo consumo',1,1,100,'inclusive',0) returning id into b;
  p:=jsonb_build_array(jsonb_build_object('item_id',b,'base_version',(select version from order_items where id=b),'target_position',3));
  r:=fn_apply_bill_split(gen_random_uuid(),o,p,'[{"position":3}]');
  perform test_assert(r->>'status'='applied' and (select discounts=400 and total=600 from order_items where id=a)
    and (select not is_closed from order_checks where id=c),'recalcular no reinterpreta ofertas facturadas aunque is_closed siga abierto');
end $$;

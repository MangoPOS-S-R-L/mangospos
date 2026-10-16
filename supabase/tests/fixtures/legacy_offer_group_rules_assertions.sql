set request.jwt.claim.sub='a0000000-0000-0000-0000-000000000001';
set request.jwt.claim.role='authenticated';
do $$ declare o uuid;i uuid;n uuid;op uuid;v bigint;r jsonb;p jsonb;q numeric;target numeric;expected numeric;
begin
  for q,target,expected in values (4,3,750),(8,7,1500),(8,6,1250),(8,4,750) loop
    o:=review_empty_order();
    i:=fn_add_offer_deal(o,'60000000-0000-4000-8000-000000000002',q,q/4*250,'4x3 Presidente',
      '70000000-0000-4000-8000-000000000002',1);
    -- Simular una venta previa al snapshot, con promoción ya inexistente.
    perform set_config('mangopos.atomic_offer_group','on',true);
    update order_items set notes='[DEAL:70000000-0000-4000-8000-000000000099]',status='pending' where id=i;
    perform set_config('mangopos.atomic_offer_group','',true);
    select version into v from order_items where id=i;
    p:=jsonb_build_array(jsonb_build_object('kind','details','item_id',i,'base_version',v,
      'args',jsonb_build_object('qty',target,'discounts',0,
        'notes','[DEAL:fake-client]\n[DEAL_RULE:2:999.00]')));
    op:=gen_random_uuid();
    r:=fn_apply_order_item_group(op,o,p);
    perform test_assert(r->>'status'='applied','legacy: retirar unidades sin snapshot aplica');
    perform test_assert((select qty=target and total=expected and notes like '%[DEAL_RULE:4:250.00]%'
      and notes like '%[DEAL:70000000-0000-4000-8000-000000000099]%' and status::text='pending'
      from order_items where id=i),'legacy: total y snapshot originales prevalecen sobre cliente/catálogo');
    r:=fn_apply_order_item_group(op,o,p);
    perform test_assert(r->>'replayed'='true','legacy: replay no vuelve a reducir unidades');
  end loop;
  -- La misma recuperación sirve en la entrada individual antigua.
  o:=review_empty_order();
  i:=fn_add_offer_deal(o,'60000000-0000-4000-8000-000000000002',4,250,'4x3 Presidente',
    '70000000-0000-4000-8000-000000000002',1);
  perform set_config('mangopos.atomic_offer_group','on',true);
  update order_items set notes='[DEAL:70000000-0000-4000-8000-000000000099]' where id=i;
  perform set_config('mangopos.atomic_offer_group','',true);
  perform fn_update_item_qty(i,3);
  perform test_assert((select qty=3 and discounts=0 and total=750 and notes like '%[DEAL_RULE:4:250.00]%'
    from order_items where id=i),'legacy: edición individual recupera regla sin catálogo');
  -- Un aumento conserva la nueva ronda en draft y el snapshot validado.
  o:=review_empty_order();
  i:=fn_add_offer_deal(o,'60000000-0000-4000-8000-000000000002',4,250,'4x3 Presidente',
    '70000000-0000-4000-8000-000000000002',1);
  perform set_config('mangopos.atomic_offer_group','on',true);
  update order_items set notes='[DEAL:70000000-0000-4000-8000-000000000099]',status='pending' where id=i;
  perform set_config('mangopos.atomic_offer_group','',true);
  n:=gen_random_uuid();
  perform fn_apply_order_item_group(gen_random_uuid(),o,jsonb_build_array(
    jsonb_build_object('kind','details','item_id',i,'base_version',(select version from order_items where id=i),
      'args',jsonb_build_object('qty',4,'notes','[DEAL_RULE:2:999.00]')),
    jsonb_build_object('kind','add','item_id',n,'source_id',i,'args','{"qty":4}'::jsonb)));
  perform test_assert((select sum(qty)=8 and sum(discounts)=500 and sum(total)=1500
    from order_items where order_id=o),'legacy: aumento de 4 a 8 conserva dos ofertas');
  perform test_assert((select status::text='draft' and notes like '%[DEAL_RULE:4:250.00]%'
    from order_items where id=n),'legacy: ronda nueva hereda solo snapshot validado');
  -- Ambigüedad: no alterar cantidad/cobro, pero permitir retirar todo.
  o:=review_empty_order();
  i:=fn_add_offer_deal(o,'60000000-0000-4000-8000-000000000002',4,250,'4x3 Presidente',
    '70000000-0000-4000-8000-000000000002',1);
  perform set_config('mangopos.atomic_offer_group','on',true);
  update order_items set notes='[DEAL:70000000-0000-4000-8000-000000000099]',discounts=125 where id=i;
  perform set_config('mangopos.atomic_offer_group','',true);
  select version into v from order_items where id=i;
  begin
    perform fn_apply_order_item_group(gen_random_uuid(),o,jsonb_build_array(jsonb_build_object(
      'kind','details','item_id',i,'base_version',v,'args','{"qty":3}'::jsonb)));
    raise exception 'FAIL: aceptó una regla histórica contradictoria';
  exception when invalid_parameter_value then null; end;
  perform test_assert((select qty=4 and discounts=125 and version=v from order_items where id=i),
    'legacy: ambigüedad no escribe ni recalcula');
  r:=fn_apply_order_item_group(gen_random_uuid(),o,jsonb_build_array(jsonb_build_object(
    'kind','delete','item_id',i,'base_version',v)));
  perform test_assert(r->>'status'='applied' and not exists(select 1 from order_items where id=i),
    'legacy: retirar la oferta completa no exige reconstruir regla');
end $$;

-- Recuperar ofertas anteriores a DEAL_RULE sin consultar el catálogo actual.
-- La etiqueta histórica N×M solo se admite si concuerda con los paquetes,
-- el precio y el descuento guardados ANTES de editar. Sin backfill.
begin;
set local lock_timeout='5s';

create or replace function public.fn_legacy_offer_rule(p_item public.order_items)
returns text language plpgsql immutable set search_path=public as $$
declare label text[]; units numeric; paid numeric; benefit numeric; quantity numeric;
begin
  if coalesce(p_item.notes,'') !~ '\[DEAL:[^\]]*\]'
     or p_item.notes like '%[CORTESIA:%' then return null; end if;
  label:=regexp_match(p_item.product_name,'^[[:space:]]*([0-9]+)[xX×]([0-9]+)[[:space:]]+');
  if label is null then return null; end if;
  units:=label[1]::numeric; paid:=label[2]::numeric;
  quantity:=coalesce(p_item.qty,p_item.quantity);
  if units<2 or units>2147483647 or paid<1 or paid>=units
     or quantity is null or quantity<units or quantity<>trunc(quantity)
     or mod(quantity,units)<>0 or coalesce(p_item.unit_price,0)<=0
     or p_item.unit_price::text in ('NaN','Infinity','-Infinity')
     or p_item.discounts is null or p_item.discounts::text in ('NaN','Infinity','-Infinity')
     then return null; end if;
  benefit:=round(p_item.unit_price*(units-paid),2);
  if abs(p_item.discounts-quantity/units*benefit)>0.01 then return null; end if;
  return '[DEAL_RULE:'||units::integer||':'||round(benefit,2)||']';
end $$;
revoke all on function public.fn_legacy_offer_rule(public.order_items) from public,anon,authenticated;

-- El trigger individual recupera desde la venta antes de su compatibilidad
-- con promociones antiguas. El snapshot prevalece sobre cualquier catálogo.
do $$ declare s text; needle text; begin
  s:=pg_get_functiondef('public.fn_offer_quantity_discount()'::regprocedure);
  if position('-- recover_legacy_sale_rule' in s)=0 then
    needle:='  if v_rule is not null then';
    if position(needle in s)=0 then raise exception 'LEGACY_OFFER_TRIGGER_PATCH_NOT_FOUND'; end if;
    s:=replace(s,needle,$patch$  -- recover_legacy_sale_rule
  if v_rule is null and tg_op='UPDATE' then
    v_rule:=regexp_match(public.fn_legacy_offer_rule(old), '\[DEAL_RULE:([0-9]+):([0-9]+(?:\.[0-9]+)?)\]');
  end if;
  -- end_recover_legacy_sale_rule
$patch$||needle);
    execute s;
  end if;
end $$;

-- Validar sobre la fila anterior, sin alterar su versión antes de que la
-- entrada versionada compruebe el conflicto. No confiar en reglas del cliente.
do $$ declare s text; needle text; begin
  s:=pg_get_functiondef('public.fn_apply_order_item_group(uuid,uuid,jsonb,boolean)'::regprocedure);
  if position('-- recover_legacy_group_rule' in s)=0 then
    needle:='       r:=fn_apply_order_edit(gen_random_uuid(),p_order_id,a->>''kind'',(a->>''item_id'')::uuid,';
    if position(needle in s)=0 then raise exception 'LEGACY_OFFER_GROUP_PATCH_NOT_FOUND'; end if;
    s:=replace(s,needle,$patch$       -- recover_legacy_group_rule
       select * into row from public.order_items
         where id=(a->>'item_id')::uuid and order_id=p_order_id for update;
       if found and a->>'kind'='details' and coalesce(row.notes,'') ~ '\[DEAL:[^\]]*\]'
          and row.notes not like '%[CORTESIA:%' then
         k:=coalesce((regexp_match(row.notes,'(\[DEAL_RULE:[0-9]+:[0-9]+(?:\.[0-9]+)?\])'))[1],
           public.fn_legacy_offer_rule(row));
         if k is null and coalesce((args->>'qty')::numeric,row.qty) is distinct from row.qty then
           raise exception 'OFFER_RULE_SNAPSHOT_REQUIRED' using errcode='22023';
         end if;
         args:=jsonb_set(args,'{notes}',to_jsonb(concat_ws(E'\n',
           nullif(btrim(regexp_replace(coalesce(args->>'notes',row.notes),
             '\[DEAL(?:_RULE)?:[^\]]*\]','','g'),E'\n '),''),
           (regexp_match(row.notes,'(\[DEAL:[^\]]*\])'))[1],k)));
       end if;
       -- end_recover_legacy_group_rule
$patch$||needle);
    execute s;
  end if;
end $$;
notify pgrst,'reload schema';
commit;

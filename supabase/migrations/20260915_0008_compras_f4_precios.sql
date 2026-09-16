-- =============================================================================
-- 20260915_0008 — Compras F4: comparador de precios + el precio se aprende al
-- recibir (D4)
--
-- PRD: docs/PRD_COMPRAS_PEDIDO_SUGERIDO.md (F4). REQUIERE: 20260915_0003.
--
-- QUÉ ENTREGA:
--
-- 1) `supplier_items.last_price_at` y `last_price_source` ('manual' |
--    'recepcion'): de cuándo es el precio de lista y de dónde salió. Un
--    trigger BEFORE los sella cuando alguien cambia el precio a mano (la app no
--    cambia).
--
-- 2) EL PRECIO SE APRENDE AL RECIBIR [D4]. Trigger AFTER INSERT en
--    `inventory_movements`, SOLO para movimientos `purchase` de las tres puertas
--    (orden recibida, recepción directa, recepción con conduce): pone
--    `supplier_items.last_price` = costo real × contenido de la presentación
--    (precio POR UNIDAD DE COMPRA, como dice 0003) y CREA el vínculo si no
--    existía. Nunca pisa un precio más nuevo; un vínculo desactivado sigue
--    desactivado. Si algo falla, avisa (WARNING) y la recepción sigue: aprender
--    un precio jamás puede impedir que entre mercancía.
--    Las VENTAS no pagan nada: la condición WHEN filtra antes de llamar a la
--    función. Un documento ya anulado no enseña precio.
--
-- 2b) ANULAR VUELVE A APRENDER. Si se anula una recepción directa, un conduce
--    o una orden (un costo mal digitado es justo lo que se anula), el precio de
--    lista de esos insumos vuelve a salir de la última compra VÁLIDA a ese
--    suplidor; si no queda ninguna, se vacía. Los precios escritos a mano no se
--    tocan. Tampoco bloquea la anulación si algo falla.
--
-- 3) `fn_purchase_price_comparison(negocio, insumos, días)`, SOLO LECTURA: por
--    insumo × suplidor, desde el costo REAL recibido (nunca borradores ni
--    documentos anulados): último costo y fecha, anterior DISTINTO y tendencia,
--    promedio ponderado / mín / máx / compras / cantidad de la ventana, precio
--    de lista, si es el suplidor que usa el pedido sugerido, puesto por último
--    costo y % sobre el más barato. Todo en unidad base; con el contenido para
--    mostrarlo por empaque.
--
-- OJO AL APLICAR: crear un trigger en `inventory_movements` toma un candado
--   breve sobre la tabla (bloquea ventas mientras dura). lock_timeout de 5 s:
--   si hay mucho movimiento, falla sin aplicar nada; reintentar en hora baja.
--
-- NEGOCIOS SIN INVENTARIO: sin compras, el trigger nunca se dispara.
--
-- PRUEBA: supabase/tests/compras_f4_local_test.sh (Postgres 15 local).
-- IDEMPOTENTE: sí. REVERSIBLE: sí (_ROLLBACK).
-- =============================================================================

begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

do $guard$
begin
  if to_regprocedure('public.fn_purchase_resolve_suppliers(uuid,uuid[])') is null then
    raise exception 'Falta aplicar 20260915_0003 (fn_purchase_resolve_suppliers). No se aplicó nada.';
  end if;
  if to_regclass('public.supplier_items') is null then
    raise exception 'Falta public.supplier_items (20260819_0003). No se aplicó nada.';
  end if;
  if to_regclass('public.direct_receipts') is null or to_regclass('public.purchase_receptions') is null then
    raise exception 'Faltan direct_receipts o purchase_receptions. No se aplicó nada.';
  end if;
end
$guard$;

-- ---------------------------------------------------------------------------
-- 1) Fecha y fuente del precio de lista
-- ---------------------------------------------------------------------------

alter table public.supplier_items add column if not exists last_price_at timestamptz;
alter table public.supplier_items add column if not exists last_price_source text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'supplier_items_last_price_source_check'
       and conrelid = 'public.supplier_items'::regclass
  ) then
    alter table public.supplier_items
      add constraint supplier_items_last_price_source_check
      check (last_price_source is null or last_price_source in ('manual', 'recepcion'));
  end if;
end
$$;

comment on column public.supplier_items.last_price is
  'Precio POR UNIDAD DE COMPRA (la del vínculo, o la del insumo si el vínculo '
  'no tiene). Lo actualiza la recepción (20260915_0008) o se escribe a mano.';
comment on column public.supplier_items.last_price_at is
  'Cuándo se fijó last_price: la fecha de la recepción o la del cambio manual.';
comment on column public.supplier_items.last_price_source is
  '''recepcion'' = aprendido del costo real recibido; ''manual'' = escrito en la app.';

create or replace function public.fn_supplier_items_price_stamp()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'UPDATE' and new.last_price is not distinct from old.last_price then
    return new;
  end if;
  if new.last_price is null then
    new.last_price_at := null;
    new.last_price_source := null;
    return new;
  end if;
  -- El trigger de recepción ya puso su fecha y su fuente.
  if coalesce(current_setting('mangopos.supplier_price_from_receipt', true), '') = 'on' then
    return new;
  end if;
  new.last_price_at := now();
  new.last_price_source := 'manual';
  return new;
end;
$$;

drop trigger if exists trg_supplier_items_price_stamp on public.supplier_items;
create trigger trg_supplier_items_price_stamp
  before insert or update of last_price on public.supplier_items
  for each row
  execute function public.fn_supplier_items_price_stamp();

-- ---------------------------------------------------------------------------
-- 2) El precio se aprende al recibir [D4]
-- ---------------------------------------------------------------------------

create or replace function public.fn_supplier_items_learn_from_receipt()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_supplier    uuid;
  v_item_unit   text;
  v_item_pack   numeric;
  v_link_unit   text;
  v_link_pack   numeric;
  v_pack        numeric;
begin
  if new.quantity is null or new.quantity <= 0
     or new.cost_per_unit is null or new.cost_per_unit <= 0
     or new.reference_id is null then
    return new;
  end if;

  begin
    if new.reference_type = 'purchase_order' then
      select po.supplier_id into v_supplier
        from public.purchase_orders po
       where po.id = new.reference_id and po.status::text <> 'cancelled';
    elsif new.reference_type = 'direct_receipt' then
      select dr.supplier_id into v_supplier
        from public.direct_receipts dr
       where dr.id = new.reference_id and coalesce(dr.status, 'received') <> 'cancelled';
    elsif new.reference_type = 'purchase_reception_line' then
      select pr.supplier_id into v_supplier
        from public.purchase_reception_lines prl
        join public.purchase_receptions pr on pr.id = prl.reception_id
       where prl.id = new.reference_id and pr.status <> 'cancelled';
    else
      return new;
    end if;

    if v_supplier is null or not exists (
      select 1 from public.suppliers s
       where s.id = v_supplier and s.business_id = new.business_id
    ) then
      return new;
    end if;

    select ii.purchase_unit, ii.pack_size into v_item_unit, v_item_pack
      from public.inventory_items ii
     where ii.id = new.item_id and ii.business_id = new.business_id;
    if not found then
      return new;
    end if;

    select si.purchase_unit, si.pack_size into v_link_unit, v_link_pack
      from public.supplier_items si
     where si.supplier_id = v_supplier and si.inventory_item_id = new.item_id;

    -- La misma presentación que usa fn_purchase_resolve_suppliers: la del
    -- vínculo si trae unidad Y contenido; si no, la del insumo.
    v_pack := case
                when v_link_unit is not null and coalesce(v_link_pack, 0) > 0 then v_link_pack
                else coalesce(nullif(v_item_pack, 0), 1)
              end;

    perform set_config('mangopos.supplier_price_from_receipt', 'on', true);

    insert into public.supplier_items (
      business_id, supplier_id, inventory_item_id,
      purchase_unit, pack_size,
      last_price, last_price_at, last_price_source
    )
    values (
      new.business_id, v_supplier, new.item_id,
      v_item_unit,
      case when v_item_unit is not null and coalesce(v_item_pack, 0) > 0 then v_item_pack end,
      round(new.cost_per_unit * v_pack, 4),
      coalesce(new.created_at, now()),
      'recepcion'
    )
    on conflict (supplier_id, inventory_item_id) do update
       set last_price        = excluded.last_price,
           last_price_at     = excluded.last_price_at,
           last_price_source = 'recepcion',
           updated_at        = now()
     where public.supplier_items.last_price_at is null
        or public.supplier_items.last_price_at <= excluded.last_price_at;

    perform set_config('mangopos.supplier_price_from_receipt', '', true);
  exception when others then
    perform set_config('mangopos.supplier_price_from_receipt', '', true);
    raise warning 'No se actualizó el precio del suplidor para el movimiento % (%): %',
      new.id, sqlstate, sqlerrm;
  end;

  return new;
end;
$$;

comment on function public.fn_supplier_items_learn_from_receipt() is
  'D4: al recibir mercancía (movimiento purchase de orden, recepción directa o '
  'conduce) fija supplier_items.last_price = costo real × contenido y crea el '
  'vínculo si no existe. Nunca pisa un precio más nuevo ni bloquea la '
  'recepción. Ver 20260915_0008.';

drop trigger if exists trg_inventory_movements_learn_supplier_price on public.inventory_movements;
create trigger trg_inventory_movements_learn_supplier_price
  after insert on public.inventory_movements
  for each row
  when (new.movement_type = 'purchase'
        and new.reference_type in ('purchase_order', 'direct_receipt', 'purchase_reception_line'))
  execute function public.fn_supplier_items_learn_from_receipt();

-- ---------------------------------------------------------------------------
-- 2b) Anular vuelve a aprender
-- ---------------------------------------------------------------------------

create or replace function public.fn_supplier_items_relearn(
  p_business_id uuid,
  p_supplier_id uuid,
  p_item_ids    uuid[]
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_business_id is null or p_supplier_id is null
     or p_item_ids is null or cardinality(p_item_ids) = 0 then
    return;
  end if;

  perform set_config('mangopos.supplier_price_from_receipt', 'on', true);

  with purchases as (
    select im.item_id, im.cost_per_unit as cost, im.created_at as at
      from public.inventory_movements im
      join public.purchase_orders po on po.id = im.reference_id
     where im.business_id = p_business_id
       and im.movement_type = 'purchase' and im.reference_type = 'purchase_order'
       and po.supplier_id = p_supplier_id and po.status::text <> 'cancelled'
       and im.cost_per_unit > 0 and im.quantity > 0
       and im.item_id = any (p_item_ids)
    union all
    select im.item_id, im.cost_per_unit, im.created_at
      from public.inventory_movements im
      join public.direct_receipts dr on dr.id = im.reference_id
     where im.business_id = p_business_id
       and im.movement_type = 'purchase' and im.reference_type = 'direct_receipt'
       and dr.supplier_id = p_supplier_id and coalesce(dr.status, 'received') <> 'cancelled'
       and im.cost_per_unit > 0 and im.quantity > 0
       and im.item_id = any (p_item_ids)
    union all
    select im.item_id, im.cost_per_unit, im.created_at
      from public.inventory_movements im
      join public.purchase_reception_lines prl on prl.id = im.reference_id
      join public.purchase_receptions pr on pr.id = prl.reception_id
     where im.business_id = p_business_id
       and im.movement_type = 'purchase' and im.reference_type = 'purchase_reception_line'
       and pr.supplier_id = p_supplier_id and pr.status <> 'cancelled'
       and im.cost_per_unit > 0 and im.quantity > 0
       and im.item_id = any (p_item_ids)
  ),
  latest as (
    select distinct on (p.item_id) p.item_id, p.cost, p.at
      from purchases p
     order by p.item_id, p.at desc
  ),
  target as (
    select si.id,
           l.cost,
           l.at,
           case when si.purchase_unit is not null and coalesce(si.pack_size, 0) > 0 then si.pack_size
                else coalesce(nullif(ii.pack_size, 0), 1) end as pack
      from public.supplier_items si
      join public.inventory_items ii on ii.id = si.inventory_item_id
      left join latest l on l.item_id = si.inventory_item_id
     where si.business_id = p_business_id
       and si.supplier_id = p_supplier_id
       and si.inventory_item_id = any (p_item_ids)
       -- Lo escrito a mano no se toca.
       and si.last_price_source = 'recepcion'
  )
  update public.supplier_items si
     set last_price        = case when t.cost is null then null else round(t.cost * t.pack, 4) end,
         last_price_at     = t.at,
         last_price_source = case when t.cost is null then null else 'recepcion' end,
         updated_at        = now()
    from target t
   where si.id = t.id;

  perform set_config('mangopos.supplier_price_from_receipt', '', true);
end;
$$;

comment on function public.fn_supplier_items_relearn(uuid, uuid, uuid[]) is
  'Recalcula supplier_items.last_price (solo los aprendidos de recepción) desde '
  'la última compra VÁLIDA de ese suplidor; sin compras válidas lo vacía. Ver '
  '20260915_0008.';

revoke all on function public.fn_supplier_items_relearn(uuid, uuid, uuid[]) from public;
revoke all on function public.fn_supplier_items_relearn(uuid, uuid, uuid[]) from anon;
revoke all on function public.fn_supplier_items_relearn(uuid, uuid, uuid[]) from authenticated;

create or replace function public.fn_supplier_items_relearn_on_cancel()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_items uuid[];
begin
  begin
    if tg_table_name = 'direct_receipts' then
      select array_agg(distinct im.item_id) into v_items
        from public.inventory_movements im
       where im.business_id = new.business_id
         and im.movement_type = 'purchase' and im.reference_type = 'direct_receipt'
         and im.reference_id = new.id;
    elsif tg_table_name = 'purchase_receptions' then
      select array_agg(distinct im.item_id) into v_items
        from public.inventory_movements im
        join public.purchase_reception_lines prl on prl.id = im.reference_id
       where im.business_id = new.business_id
         and im.movement_type = 'purchase' and im.reference_type = 'purchase_reception_line'
         and prl.reception_id = new.id;
    elsif tg_table_name = 'purchase_orders' then
      select array_agg(distinct im.item_id) into v_items
        from public.inventory_movements im
       where im.business_id = new.business_id
         and im.movement_type = 'purchase' and im.reference_type = 'purchase_order'
         and im.reference_id = new.id;
    end if;

    perform public.fn_supplier_items_relearn(new.business_id, new.supplier_id, v_items);
  exception when others then
    perform set_config('mangopos.supplier_price_from_receipt', '', true);
    raise warning 'No se recalculó el precio del suplidor al anular % % (%): %',
      tg_table_name, new.id, sqlstate, sqlerrm;
  end;
  return new;
end;
$$;

drop trigger if exists trg_direct_receipts_relearn_supplier_price on public.direct_receipts;
create trigger trg_direct_receipts_relearn_supplier_price
  after update of status on public.direct_receipts
  for each row
  when (new.status = 'cancelled' and old.status is distinct from 'cancelled')
  execute function public.fn_supplier_items_relearn_on_cancel();

drop trigger if exists trg_purchase_receptions_relearn_supplier_price on public.purchase_receptions;
create trigger trg_purchase_receptions_relearn_supplier_price
  after update of status on public.purchase_receptions
  for each row
  when (new.status = 'cancelled' and old.status is distinct from 'cancelled')
  execute function public.fn_supplier_items_relearn_on_cancel();

drop trigger if exists trg_purchase_orders_relearn_supplier_price on public.purchase_orders;
create trigger trg_purchase_orders_relearn_supplier_price
  after update of status on public.purchase_orders
  for each row
  when (new.status::text = 'cancelled' and old.status::text is distinct from 'cancelled')
  execute function public.fn_supplier_items_relearn_on_cancel();

-- ---------------------------------------------------------------------------
-- 3) Comparador de precios
-- ---------------------------------------------------------------------------

create or replace function public.fn_purchase_price_comparison(
  p_business_id uuid,
  p_item_ids    uuid[]  default null,
  p_days_back   integer default 90
)
returns table (
  item_id            uuid,
  supplier_id        uuid,
  supplier_name      text,
  supplier_active    boolean,
  purchases_count    integer,
  quantity_total     numeric,
  last_cost_base     numeric,
  last_at            timestamptz,
  previous_cost_base numeric,
  trend_pct          numeric,
  avg_cost_base      numeric,
  min_cost_base      numeric,
  max_cost_base      numeric,
  purchase_unit      text,
  pack_size          numeric,
  list_price_pack    numeric,
  list_price_base    numeric,
  list_price_at      timestamptz,
  list_price_source  text,
  is_linked          boolean,
  link_active        boolean,
  is_resolved        boolean,
  rank_by_last       integer,
  vs_cheapest_pct    numeric
)
language sql
stable
security invoker
set search_path = public
as $$
  with params as (
    select greatest(coalesce(p_days_back, 90), 1) as days_back
  ),
  -- Mercancía que ENTRÓ, con su suplidor y su costo real, por las tres puertas.
  -- Documentos anulados fuera: su movimiento de compra sigue ahí (la
  -- anulación agrega un ajuste), pero ese precio ya no vale.
  purchases as (
    select im.item_id, po.supplier_id, im.cost_per_unit as cost, im.quantity as qty, im.created_at as at
      from public.inventory_movements im
      join public.purchase_orders po on po.id = im.reference_id
     where im.business_id = p_business_id
       and im.movement_type = 'purchase'
       and im.reference_type = 'purchase_order'
       and po.supplier_id is not null
       and po.status::text <> 'cancelled'
       and im.cost_per_unit > 0 and im.quantity > 0
       and (p_item_ids is null or im.item_id = any (p_item_ids))
    union all
    select im.item_id, dr.supplier_id, im.cost_per_unit, im.quantity, im.created_at
      from public.inventory_movements im
      join public.direct_receipts dr on dr.id = im.reference_id
     where im.business_id = p_business_id
       and im.movement_type = 'purchase'
       and im.reference_type = 'direct_receipt'
       and dr.supplier_id is not null
       and coalesce(dr.status, 'received') <> 'cancelled'
       and im.cost_per_unit > 0 and im.quantity > 0
       and (p_item_ids is null or im.item_id = any (p_item_ids))
    union all
    select im.item_id, pr.supplier_id, im.cost_per_unit, im.quantity, im.created_at
      from public.inventory_movements im
      join public.purchase_reception_lines prl on prl.id = im.reference_id
      join public.purchase_receptions pr on pr.id = prl.reception_id
     where im.business_id = p_business_id
       and im.movement_type = 'purchase'
       and im.reference_type = 'purchase_reception_line'
       and pr.supplier_id is not null
       and pr.status <> 'cancelled'
       and im.cost_per_unit > 0 and im.quantity > 0
       and (p_item_ids is null or im.item_id = any (p_item_ids))
  ),
  ordered as (
    select p.*,
           row_number() over (partition by p.item_id, p.supplier_id order by p.at desc) as rn
      from purchases p
  ),
  last_buy as (
    select o.item_id, o.supplier_id, o.cost as last_cost, o.at as last_at
      from ordered o
     where o.rn = 1
  ),
  -- El anterior DISTINTO: comprar dos veces al mismo precio no es un cambio.
  previous_buy as (
    select distinct on (o.item_id, o.supplier_id)
           o.item_id, o.supplier_id, o.cost as previous_cost
      from ordered o
      join last_buy l on l.item_id = o.item_id and l.supplier_id = o.supplier_id
     where o.rn > 1 and o.cost <> l.last_cost
     order by o.item_id, o.supplier_id, o.at desc
  ),
  window_stats as (
    select p.item_id, p.supplier_id,
           count(*)::integer                              as purchases_count,
           sum(p.qty)                                     as quantity_total,
           sum(p.cost * p.qty) / nullif(sum(p.qty), 0)    as avg_cost,
           min(p.cost)                                    as min_cost,
           max(p.cost)                                    as max_cost
      from purchases p
     where p.at >= now() - make_interval(days => (select days_back from params))
     group by p.item_id, p.supplier_id
  ),
  links as (
    select si.inventory_item_id as item_id, si.supplier_id, si.purchase_unit, si.pack_size,
           si.last_price, si.last_price_at, si.last_price_source, si.is_active
      from public.supplier_items si
     where si.business_id = p_business_id
       and (p_item_ids is null or si.inventory_item_id = any (p_item_ids))
  ),
  pairs as (
    select lb.item_id, lb.supplier_id from last_buy lb
    union
    select lk.item_id, lk.supplier_id from links lk where lk.is_active
  ),
  resolved as (
    select r.item_id, r.supplier_id
      from public.fn_purchase_resolve_suppliers(p_business_id, p_item_ids) r
     where r.supplier_id is not null
  ),
  base as (
    select pr.item_id,
           pr.supplier_id,
           s.name                                   as supplier_name,
           coalesce(s.is_active, true)              as supplier_active,
           coalesce(w.purchases_count, 0)           as purchases_count,
           coalesce(w.quantity_total, 0)            as quantity_total,
           lb.last_cost,
           lb.last_at,
           pv.previous_cost,
           w.avg_cost, w.min_cost, w.max_cost,
           case when lk.purchase_unit is not null and coalesce(lk.pack_size, 0) > 0
                then lk.purchase_unit else ii.purchase_unit end          as purchase_unit,
           case when lk.purchase_unit is not null and coalesce(lk.pack_size, 0) > 0
                then lk.pack_size else coalesce(nullif(ii.pack_size, 0), 1) end as pack_size,
           lk.last_price                            as list_price_pack,
           lk.last_price_at,
           lk.last_price_source,
           (lk.item_id is not null)                 as is_linked,
           coalesce(lk.is_active, false)            as link_active,
           (rs.supplier_id is not null)             as is_resolved
      from pairs pr
      join public.suppliers s        on s.id = pr.supplier_id and s.business_id = p_business_id
      join public.inventory_items ii on ii.id = pr.item_id and ii.business_id = p_business_id
      left join last_buy lb     on lb.item_id = pr.item_id and lb.supplier_id = pr.supplier_id
      left join previous_buy pv on pv.item_id = pr.item_id and pv.supplier_id = pr.supplier_id
      left join window_stats w  on w.item_id  = pr.item_id and w.supplier_id  = pr.supplier_id
      left join links lk        on lk.item_id = pr.item_id and lk.supplier_id = pr.supplier_id
      left join resolved rs     on rs.item_id = pr.item_id and rs.supplier_id = pr.supplier_id
  )
  select b.item_id,
         b.supplier_id,
         b.supplier_name,
         b.supplier_active,
         b.purchases_count,
         b.quantity_total,
         round(b.last_cost, 4),
         b.last_at,
         round(b.previous_cost, 4),
         case when b.previous_cost > 0 and b.last_cost is not null
              then round((b.last_cost - b.previous_cost) / b.previous_cost * 100, 1) end,
         round(b.avg_cost, 4),
         round(b.min_cost, 4),
         round(b.max_cost, 4),
         b.purchase_unit,
         b.pack_size,
         b.list_price_pack,
         case when b.list_price_pack is not null then round(b.list_price_pack / b.pack_size, 4) end,
         b.last_price_at,
         b.last_price_source,
         b.is_linked,
         b.link_active,
         b.is_resolved,
         case when b.last_cost is not null
              then (rank() over (partition by b.item_id order by b.last_cost asc nulls last))::integer end,
         case when b.last_cost is not null
              then round((b.last_cost / nullif(min(b.last_cost) over (partition by b.item_id), 0) - 1) * 100, 1) end
    from base b
   order by b.item_id, b.last_cost asc nulls last, b.supplier_name;
$$;

comment on function public.fn_purchase_price_comparison(uuid, uuid[], integer) is
  'Comparador de precios por insumo × suplidor desde el costo REAL recibido '
  '(órdenes, recepciones directas y conduces; sin anulados): último y anterior '
  'distinto, tendencia, promedio ponderado/mín/máx de la ventana, precio de '
  'lista con fecha y fuente, suplidor del pedido sugerido, puesto y % sobre el '
  'más barato. Unidad base. Ver 20260915_0008.';

grant execute on function public.fn_purchase_price_comparison(uuid, uuid[], integer) to authenticated;

commit;

notify pgrst, 'reload schema';

-- =============================================================================
-- 20260915_0009 — Compras F5a: presentaciones de dos niveles («caja dentro de
-- caja»)
--
-- PRD: docs/PRD_COMPRAS_PEDIDO_SUGERIDO.md (F5). Modelo de referencia: Toast
--   (Lata = 355 mL; Caja = 24 Lata → la caja trae 8,520 mL).
-- REQUIERE: user_has_business_access(uuid, uuid) y
--   user_has_business_permission(uuid, text) (ya en prod: las usa la 0007).
--
-- QUÉ ENTREGA:
--
-- 1) `inventory_item_presentations`: por insumo, hasta 5 presentaciones.
--    Cada una CONTIENE la unidad base o UNA presentación que contiene la base
--    (máximo dos niveles). `base_qty` = unidades base por 1 de esa presentación,
--    ya calculado. Una sola marcada como la de COMPRA por defecto.
--
-- 2) COMPATIBILIDAD: la de compra por defecto se APLANA en
--    `inventory_items.purchase_unit` / `pack_size` (Caja = 8,520 mL). Compras,
--    recepción, kardex, costos, RPCs, proyección y analytics siguen leyendo un
--    solo `pack_size` y no cambian. Sin presentación por defecto, la ficha no se
--    toca.
--
-- 3) `fn_inventory_item_presentations_save(insumo, presentaciones jsonb)`:
--    reemplaza el juego completo en UNA transacción, valida (unidad repetida,
--    igual a la base, cantidad ≤ 0, contenedor inexistente, tres niveles, dos
--    por defecto, más de 5) y aplana. SECURITY INVOKER (RLS de siempre) y además
--    exige el permiso de editar insumos para no «guardar» nada en silencio.
--
-- RLS: leer = miembro del negocio; escribir = `inventario.productos.crear_editar`
--   (lo mismo que `inventory_items`). Un trigger impide que una presentación
--   apunte a un insumo de otro negocio.
--
-- NEGOCIOS SIN INVENTARIO: tabla nueva y vacía; nada se escribe hasta que
--   alguien guarde presentaciones.
--
-- PRUEBA: supabase/tests/compras_f5_local_test.sh (Postgres 15 local).
-- IDEMPOTENTE: sí. REVERSIBLE: sí (_ROLLBACK borra la tabla; el pack aplanado
--   se queda en inventory_items).
-- =============================================================================

begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

do $guard$
begin
  if to_regprocedure('public.user_has_business_permission(uuid,text)') is null
     or to_regprocedure('public.user_has_business_access(uuid,uuid)') is null then
    raise exception 'Faltan user_has_business_permission / user_has_business_access. No se aplicó nada.';
  end if;
end
$guard$;

create table if not exists public.inventory_item_presentations (
  id                  uuid        not null default gen_random_uuid() primary key,
  business_id         uuid        not null references public.businesses(id) on delete cascade,
  item_id             uuid        not null references public.inventory_items(id) on delete cascade,
  -- Nombre de la presentación: código del catálogo de unidades (Caja, Lata,
  -- Botella…) o texto libre.
  unit                text        not null check (btrim(unit) <> ''),
  -- Cuánto contiene: `contains_qty` de `contains_unit`. contains_unit NULL =
  -- la unidad base del insumo; si no, el `unit` de otra presentación del mismo
  -- insumo que contiene la base.
  contains_qty        numeric     not null check (contains_qty > 0),
  contains_unit       text,
  -- Unidades BASE por 1 de esta presentación (aplanado, lo calcula la función).
  base_qty            numeric     not null check (base_qty > 0),
  is_purchase_default boolean     not null default false,
  sort_order          smallint    not null default 0,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

comment on table public.inventory_item_presentations is
  'Presentaciones de un insumo en hasta dos niveles (Lata = 355 mL; Caja = 24 '
  'Lata). La de compra por defecto se aplana en inventory_items.purchase_unit/'
  'pack_size. Se escribe con fn_inventory_item_presentations_save. Ver 20260915_0009.';

create unique index if not exists uq_inventory_item_presentations_unit
  on public.inventory_item_presentations (item_id, lower(btrim(unit)));
create unique index if not exists uq_inventory_item_presentations_default
  on public.inventory_item_presentations (item_id) where is_purchase_default;
create index if not exists idx_inventory_item_presentations_business
  on public.inventory_item_presentations (business_id);

-- El insumo tiene que ser del MISMO negocio que la fila.
create or replace function public.fn_inventory_item_presentations_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from public.inventory_items ii
     where ii.id = new.item_id and ii.business_id = new.business_id
  ) then
    raise exception 'PRESENTATIONS_ITEM_BUSINESS_MISMATCH: el insumo no es de este negocio'
      using errcode = '42501';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_inventory_item_presentations_guard on public.inventory_item_presentations;
create trigger trg_inventory_item_presentations_guard
  before insert or update on public.inventory_item_presentations
  for each row
  execute function public.fn_inventory_item_presentations_guard();

alter table public.inventory_item_presentations enable row level security;

drop policy if exists "iip_select" on public.inventory_item_presentations;
create policy "iip_select" on public.inventory_item_presentations
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

drop policy if exists "iip_write_by_permission" on public.inventory_item_presentations;
create policy "iip_write_by_permission" on public.inventory_item_presentations
  for all to authenticated
  using (public.user_has_business_permission(business_id, 'inventario.productos.crear_editar'))
  with check (public.user_has_business_permission(business_id, 'inventario.productos.crear_editar'));

revoke all on table public.inventory_item_presentations from anon;
grant select, insert, update, delete on table public.inventory_item_presentations to authenticated;

create or replace function public.fn_inventory_item_presentations_save(
  p_item_id       uuid,
  p_presentations jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_business_id uuid;
  v_base_unit   text;
  v_total       integer;
  v_bad         bigint;
  v_bad_text    text;
  v_result      jsonb;
begin
  select ii.business_id, lower(btrim(coalesce(ii.unit, 'unidad')))
    into v_business_id, v_base_unit
    from public.inventory_items ii
   where ii.id = p_item_id;
  if v_business_id is null then
    raise exception 'PRESENTATIONS_ITEM_NOT_FOUND: el insumo no existe o no tienes acceso'
      using errcode = '42501';
  end if;

  if not public.user_has_business_permission(v_business_id, 'inventario.productos.crear_editar') then
    raise exception 'PRESENTATIONS_ACCESS_DENIED: no tienes permiso para editar insumos en este negocio'
      using errcode = '42501';
  end if;

  if p_presentations is null or jsonb_typeof(p_presentations) <> 'array' then
    raise exception 'PRESENTATIONS_INVALID: se esperaba una lista de presentaciones'
      using errcode = '22023';
  end if;
  v_total := jsonb_array_length(p_presentations);
  if v_total > 5 then
    raise exception 'PRESENTATIONS_TOO_MANY: % presentaciones (máximo 5)', v_total
      using errcode = '22023';
  end if;

  -- Forma de cada una: {unit: texto, contains_qty: número > 0,
  -- contains_unit: texto | null, is_purchase_default: bool | null}.
  select e.n into v_bad
    from jsonb_array_elements(p_presentations) with ordinality as e(v, n)
   where case
           when jsonb_typeof(e.v) <> 'object' then true
           when jsonb_typeof(e.v -> 'unit') is distinct from 'string' then true
           when btrim(e.v ->> 'unit') = '' then true
           when jsonb_typeof(e.v -> 'contains_qty') is distinct from 'number' then true
           when (e.v ->> 'contains_qty')::numeric <= 0 then true
           when coalesce(jsonb_typeof(e.v -> 'contains_unit'), 'null') not in ('string', 'null') then true
           when coalesce(jsonb_typeof(e.v -> 'is_purchase_default'), 'null') not in ('boolean', 'null') then true
           else false
         end
   order by e.n
   limit 1;
  if v_bad is not null then
    raise exception 'PRESENTATIONS_LINE_INVALID: la presentación % no es válida (nombre y cantidad mayor que 0)', v_bad
      using errcode = '22023';
  end if;

  select btrim(e.v ->> 'unit') into v_bad_text
    from jsonb_array_elements(p_presentations) as e(v)
   where lower(btrim(e.v ->> 'unit')) = v_base_unit
   limit 1;
  if v_bad_text is not null then
    raise exception 'PRESENTATIONS_SAME_AS_BASE: «%» es la unidad base del insumo', v_bad_text
      using errcode = '22023';
  end if;

  select min(btrim(e.v ->> 'unit')) into v_bad_text
    from jsonb_array_elements(p_presentations) as e(v)
   group by lower(btrim(e.v ->> 'unit'))
  having count(*) > 1
   limit 1;
  if v_bad_text is not null then
    raise exception 'PRESENTATIONS_DUPLICATE: «%» está repetida', v_bad_text
      using errcode = '22023';
  end if;

  if (select count(*) from jsonb_array_elements(p_presentations) as e(v)
       where coalesce((e.v ->> 'is_purchase_default')::boolean, false)) > 1 then
    raise exception 'PRESENTATIONS_DEFAULT_DUPLICATE: solo una puede ser la de compra por defecto'
      using errcode = '22023';
  end if;

  -- Resolver contenedores. contains_unit vacío o igual a la base = la base.
  with p as (
    select e.n,
           btrim(e.v ->> 'unit')                                      as unit,
           (e.v ->> 'contains_qty')::numeric                          as qty,
           case when nullif(btrim(coalesce(e.v ->> 'contains_unit', '')), '') is null
                  or lower(btrim(e.v ->> 'contains_unit')) = v_base_unit
                then null
                else btrim(e.v ->> 'contains_unit') end               as parent,
           coalesce((e.v ->> 'is_purchase_default')::boolean, false)  as is_default
      from jsonb_array_elements(p_presentations) with ordinality as e(v, n)
  )
  select string_agg(format('«%s» contiene «%s»', c.unit, c.parent), '; ' order by c.n)
    into v_bad_text
    from p c
    left join p par on lower(par.unit) = lower(c.parent)
   where c.parent is not null
     and (par.unit is null            -- el contenedor no existe
          or par.parent is not null   -- tres niveles
          or lower(par.unit) = lower(c.unit));
  if v_bad_text is not null then
    raise exception 'PRESENTATIONS_BAD_PARENT: % — una presentación solo puede contener la unidad base o una presentación que contenga la base', v_bad_text
      using errcode = '22023';
  end if;

  -- Reemplazo completo del juego.
  delete from public.inventory_item_presentations where item_id = p_item_id;

  with p as (
    select e.n,
           btrim(e.v ->> 'unit')                                      as unit,
           (e.v ->> 'contains_qty')::numeric                          as qty,
           case when nullif(btrim(coalesce(e.v ->> 'contains_unit', '')), '') is null
                  or lower(btrim(e.v ->> 'contains_unit')) = v_base_unit
                then null
                else btrim(e.v ->> 'contains_unit') end               as parent,
           coalesce((e.v ->> 'is_purchase_default')::boolean, false)  as is_default
      from jsonb_array_elements(p_presentations) with ordinality as e(v, n)
  )
  insert into public.inventory_item_presentations (
    business_id, item_id, unit, contains_qty, contains_unit, base_qty, is_purchase_default, sort_order
  )
  select v_business_id,
         p_item_id,
         c.unit,
         c.qty,
         par.unit,
         case when c.parent is null then c.qty else c.qty * par.qty end,
         c.is_default,
         c.n::smallint
    from p c
    left join p par on c.parent is not null and lower(par.unit) = lower(c.parent);

  -- Aplanar la de compra por defecto en la ficha (todo lo existente la lee).
  update public.inventory_items ii
     set purchase_unit = d.unit,
         pack_size     = d.base_qty
    from public.inventory_item_presentations d
   where d.item_id = p_item_id
     and d.is_purchase_default
     and ii.id = p_item_id
     and (ii.purchase_unit is distinct from d.unit or ii.pack_size is distinct from d.base_qty);

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', x.id,
           'unit', x.unit,
           'contains_qty', x.contains_qty,
           'contains_unit', x.contains_unit,
           'base_qty', x.base_qty,
           'is_purchase_default', x.is_purchase_default,
           'sort_order', x.sort_order
         ) order by x.sort_order), '[]'::jsonb)
    into v_result
    from public.inventory_item_presentations x
   where x.item_id = p_item_id;

  return v_result;
end;
$$;

comment on function public.fn_inventory_item_presentations_save(uuid, jsonb) is
  'Reemplaza las presentaciones de un insumo (máx. 5, dos niveles), valida y '
  'aplana la de compra por defecto en inventory_items.purchase_unit/pack_size. '
  'Ver 20260915_0009.';

-- EXECUTE viene dado a PUBLIC por defecto: se quita y se da solo a authenticated.
revoke all on function public.fn_inventory_item_presentations_save(uuid, jsonb) from public;
revoke all on function public.fn_inventory_item_presentations_save(uuid, jsonb) from anon;
grant execute on function public.fn_inventory_item_presentations_save(uuid, jsonb) to authenticated;

commit;

notify pgrst, 'reload schema';

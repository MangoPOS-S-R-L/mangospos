-- =============================================================================
-- 20260915_0007 — Compras F3: mínimos en lote
--
-- PRD: docs/PRD_COMPRAS_PEDIDO_SUGERIDO.md (F3).
-- REQUIERE: 20260803_0001 (user_has_business_permission), user_business_role
--   y 20260819_0001 (inventory_stock.min_stock). Sin ellas no se aplica nada.
--
-- QUÉ ENTREGA: `fn_inventory_set_min_stock_bulk(negocio, almacén, cambios)`.
--   La pantalla «Mínimos en lote» cambia el mínimo de cientos de insumos de
--   una vez (poner valor, aplicar el sugerido, subir/bajar %, quitar, o subir
--   un Excel):
--
--   * SIN almacén → mínimo GENERAL (`inventory_items.min_stock`). Quitar = 0.
--   * CON almacén → mínimo PROPIO de ese almacén (`inventory_stock.min_stock`).
--     Quitar = null, y vuelve a regir el general. Si el insumo nunca entró a
--     ese almacén se crea su fila con existencia 0 (igual que
--     fn_inventory_set_warehouse_min_stock); quitar un mínimo que no existe
--     no crea nada. La existencia NUNCA se toca.
--   * TODO O NADA: un cambio malo (insumo de otro negocio, mínimo negativo,
--     insumo repetido) y no se guarda ninguno.
--   * Permiso: propietario/administrador/gerente, o quien tenga
--     `inventario.productos.crear_editar` (el mismo que exige el RLS para
--     editar insumos).
--   * Devuelve {updated, unchanged}: lo que ya tenía ese valor no se reescribe.
--
-- SECURITY DEFINER porque `inventory_stock` no tiene policy de escritura para
--   authenticated; por eso valida negocio, almacén, insumos y permiso ella
--   misma, y se le quita EXECUTE a public/anon.
--
-- NEGOCIOS SIN INVENTARIO: la función no escribe nada y solo corre si alguien
--   la llama.
--
-- PRUEBA: supabase/tests/compras_f3_local_test.sh (Postgres 15 local).
-- IDEMPOTENTE: sí. REVERSIBLE: sí (_ROLLBACK; los mínimos guardados quedan).
-- =============================================================================

begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

do $guard$
begin
  if to_regprocedure('public.user_has_business_permission(uuid,text)') is null then
    raise exception 'Falta public.user_has_business_permission(uuid, text) (20260803_0001). No se aplicó nada.';
  end if;
  if to_regprocedure('public.user_business_role(uuid,uuid)') is null then
    raise exception 'Falta public.user_business_role(uuid, uuid). No se aplicó nada.';
  end if;
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'inventory_stock'
       and column_name = 'min_stock'
  ) then
    raise exception 'Falta inventory_stock.min_stock (20260819_0001). No se aplicó nada.';
  end if;
end
$guard$;

create or replace function public.fn_inventory_set_min_stock_bulk(
  p_business_id  uuid,
  p_warehouse_id uuid,
  p_changes      jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
-- Si el POS está moviendo esas mismas filas, esperar poco y fallar con motivo
-- antes que dejar la pantalla colgada.
set lock_timeout = '5s'
as $$
declare
  v_user      uuid := auth.uid();
  v_role      text;
  v_total     integer;
  v_updated   integer := 0;
  v_bad_n     bigint;
  v_bad_text  text;
begin
  if v_user is null then
    raise exception 'AUTH_REQUIRED' using errcode = '42501';
  end if;
  if p_business_id is null then
    raise exception 'MIN_STOCK_BULK_INVALID: falta el negocio' using errcode = '22023';
  end if;

  select public.user_business_role(v_user, p_business_id) into v_role;
  if coalesce(v_role, '') not in ('owner', 'admin', 'manager')
     and not public.user_has_business_permission(p_business_id, 'inventario.productos.crear_editar') then
    raise exception 'MIN_STOCK_BULK_ACCESS_DENIED: no tienes permiso para editar insumos en este negocio'
      using errcode = '42501';
  end if;

  if p_changes is null or jsonb_typeof(p_changes) <> 'array'
     or jsonb_array_length(p_changes) = 0 then
    raise exception 'MIN_STOCK_BULK_EMPTY: no hay cambios que guardar' using errcode = '22023';
  end if;
  v_total := jsonb_array_length(p_changes);
  if v_total > 10000 then
    raise exception 'MIN_STOCK_BULK_TOO_LARGE: % cambios en un lote (máximo 10,000)', v_total
      using errcode = '22023';
  end if;

  if p_warehouse_id is not null and not exists (
    select 1 from public.warehouses w
     where w.id = p_warehouse_id
       and w.business_id = p_business_id
       and w.name is distinct from '__IN_TRANSIT__'
  ) then
    raise exception 'MIN_STOCK_BULK_INVALID: el almacén no es de este negocio' using errcode = '42501';
  end if;

  -- Cada cambio: {item_id: uuid, min_stock: número ≥ 0 | null}.
  select c.n into v_bad_n
    from jsonb_array_elements(p_changes) with ordinality as c(v, n)
   where case
           when jsonb_typeof(c.v) <> 'object' then true
           when coalesce(c.v ->> 'item_id', '')
                !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then true
           when not (c.v ? 'min_stock') then true
           when jsonb_typeof(c.v -> 'min_stock') = 'null' then false
           when jsonb_typeof(c.v -> 'min_stock') <> 'number' then true
           else (c.v ->> 'min_stock')::numeric < 0
         end
   order by c.n
   limit 1;
  if v_bad_n is not null then
    raise exception 'MIN_STOCK_BULK_LINE_INVALID: el cambio % no es válido (insumo y mínimo mayor o igual a 0, o vacío)', v_bad_n
      using errcode = '22023';
  end if;

  -- Por uuid, no por texto: «C000…» y «c000…» son el mismo insumo, y dos
  -- filas del mismo insumo harían que el update eligiera una al azar.
  select min(c.v ->> 'item_id') into v_bad_text
    from jsonb_array_elements(p_changes) as c(v)
   group by (c.v ->> 'item_id')::uuid
  having count(*) > 1
   limit 1;
  if v_bad_text is not null then
    raise exception 'MIN_STOCK_BULK_DUPLICATE: el insumo % viene más de una vez', v_bad_text
      using errcode = '22023';
  end if;

  select ii_name.label into v_bad_text
    from (
      select c.v ->> 'item_id' as label
        from jsonb_array_elements(p_changes) as c(v)
       where not exists (
         select 1 from public.inventory_items ii
          where ii.id = (c.v ->> 'item_id')::uuid
            and ii.business_id = p_business_id
       )
       limit 1
    ) ii_name;
  if v_bad_text is not null then
    raise exception 'MIN_STOCK_BULK_ITEM_INVALID: el insumo % no es de este negocio', v_bad_text
      using errcode = '42501';
  end if;

  if p_warehouse_id is null then
    -- Mínimo GENERAL. Quitar = 0 (lo que la vista de stock bajo entiende como
    -- «sin mínimo»).
    with c as (
      select (e.v ->> 'item_id')::uuid as item_id,
             coalesce(case when jsonb_typeof(e.v -> 'min_stock') = 'number'
                           then (e.v ->> 'min_stock')::numeric end, 0) as min_stock
        from jsonb_array_elements(p_changes) as e(v)
    ),
    u as (
      update public.inventory_items ii
         set min_stock = c.min_stock
        from c
       where ii.id = c.item_id
         and ii.business_id = p_business_id
         and ii.min_stock is distinct from c.min_stock
      returning 1
    )
    select count(*) into v_updated from u;
  else
    -- Mínimo PROPIO del almacén. Quitar = null (rige el general).
    with c as (
      select (e.v ->> 'item_id')::uuid as item_id,
             case when jsonb_typeof(e.v -> 'min_stock') = 'number'
                  then (e.v ->> 'min_stock')::numeric end as min_stock
        from jsonb_array_elements(p_changes) as e(v)
    ),
    u as (
      insert into public.inventory_stock (warehouse_id, item_id, quantity, min_stock)
      select p_warehouse_id, c.item_id, 0, c.min_stock
        from c
       where c.min_stock is not null
          or exists (
            select 1 from public.inventory_stock s
             where s.warehouse_id = p_warehouse_id and s.item_id = c.item_id
          )
      on conflict (warehouse_id, item_id)
      do update set min_stock = excluded.min_stock
       where public.inventory_stock.min_stock is distinct from excluded.min_stock
      returning 1
    )
    select count(*) into v_updated from u;
  end if;

  return jsonb_build_object(
    'updated',   v_updated,
    'unchanged', v_total - v_updated,
    'scope',     case when p_warehouse_id is null then 'general' else 'almacen' end
  );
end;
$$;

comment on function public.fn_inventory_set_min_stock_bulk(uuid, uuid, jsonb) is
  'Mínimos en lote, todo o nada. Sin almacén: inventory_items.min_stock '
  '(quitar = 0). Con almacén: inventory_stock.min_stock (quitar = null, '
  'crea la fila con existencia 0 si hace falta; nunca toca la existencia). '
  'Permiso: owner/admin/manager o inventario.productos.crear_editar. '
  'p_changes = [{item_id, min_stock}]. Ver 20260915_0007.';

revoke all on function public.fn_inventory_set_min_stock_bulk(uuid, uuid, jsonb) from public;
revoke all on function public.fn_inventory_set_min_stock_bulk(uuid, uuid, jsonb) from anon;
grant execute on function public.fn_inventory_set_min_stock_bulk(uuid, uuid, jsonb) to authenticated;

commit;

notify pgrst, 'reload schema';

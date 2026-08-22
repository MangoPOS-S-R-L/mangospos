-- =============================================================================
-- Fase 2 Bodegas — Copiar la LISTA de insumos a una bodega nueva.
--
-- CONTEXTO:
--   Al abrir una bodega nueva (un Bar, una nevera, un depósito) el operador
--   casi siempre quiere los MISMOS insumos que ya maneja en otra: lo que
--   cambia es dónde está la mercancía, no qué mercancía es. Hoy la bodega
--   nace vacía y cada insumo aparece recién cuando alguien le hace un
--   movimiento, así que no se puede ni contar ni fijarle mínimos hasta que
--   entre algo.
--
-- ENTREGA:
--   `fn_inventory_copy_warehouse_items(destino, origen, solo_activos)` crea
--   la fila de cada insumo en la bodega destino con existencia CERO.
--
--   Copia la lista, NUNCA las cantidades. Es deliberado: duplicar el stock
--   inventaría mercancía que no existe y descuadraría la valuación del
--   negocio entero. La bodega nueva arranca en cero y se llena contando,
--   recibiendo o transfiriendo.
--
--   `origen` nulo = todo el catálogo del negocio.
--   Las filas que ya existen en el destino no se tocan (`do nothing`): no
--   pisa cantidades ni mínimos de una bodega que ya venía operando.
--
--   SECURITY DEFINER porque `inventory_stock` sólo tiene policy de SELECT
--   para `authenticated` — un INSERT directo del cliente no crearía nada.
--
-- IDEMPOTENTE: sí (la función se reemplaza; el insert ignora lo ya creado).
-- REVERSIBLE: sí (ver _ROLLBACK).
-- =============================================================================

begin;

create or replace function public.fn_inventory_copy_warehouse_items(
  p_target_warehouse_id uuid,
  p_source_warehouse_id uuid default null,
  p_only_active         boolean default true
) returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_business_id     uuid;
  v_source_business uuid;
  v_inserted        integer := 0;
begin
  select w.business_id into v_business_id
    from public.warehouses w
   where w.id = p_target_warehouse_id;

  if v_business_id is null then
    raise exception 'La bodega destino no existe.' using errcode = 'P0002';
  end if;

  if not public.user_has_business_access(auth.uid(), v_business_id) then
    raise exception 'No tienes acceso a este negocio.' using errcode = '42501';
  end if;

  if p_source_warehouse_id is not null then
    if p_source_warehouse_id = p_target_warehouse_id then
      return 0;
    end if;

    select w.business_id into v_source_business
      from public.warehouses w
     where w.id = p_source_warehouse_id;

    -- El origen tiene que ser del MISMO negocio: si no, un id de otro tenant
    -- filtraría su catálogo de insumos por la puerta de atrás.
    if v_source_business is distinct from v_business_id then
      raise exception 'La bodega de origen no pertenece a este negocio.'
        using errcode = '42501';
    end if;
  end if;

  insert into public.inventory_stock (warehouse_id, item_id, quantity)
  select p_target_warehouse_id, i.id, 0
    from public.inventory_items i
   where i.business_id = v_business_id
     and (not p_only_active or coalesce(i.is_active, true))
     and (
       p_source_warehouse_id is null
       or exists (
         select 1 from public.inventory_stock s
          where s.warehouse_id = p_source_warehouse_id
            and s.item_id = i.id
       )
     )
  on conflict (warehouse_id, item_id) do nothing;

  get diagnostics v_inserted = row_count;
  return v_inserted;
end;
$$;

comment on function public.fn_inventory_copy_warehouse_items(uuid, uuid, boolean) is
  'Crea en la bodega destino la fila (existencia 0) de cada insumo de la '
  'bodega de origen, o de todo el catálogo si el origen es nulo. Copia la '
  'lista, nunca las cantidades. Devuelve cuántas filas creó. Fase 2 Bodegas.';

grant execute on function
  public.fn_inventory_copy_warehouse_items(uuid, uuid, boolean)
  to authenticated;

commit;

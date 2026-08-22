-- =============================================================================
-- Fase 2 Bodegas — Mínimo POR BODEGA (modelo híbrido).
--
-- CONTEXTO:
--   `inventory_items.min_stock` es un mínimo GLOBAL del negocio. La pantalla
--   de una bodega necesita comparar lo que hay ACÁ contra lo que tiene que
--   haber ACÁ: Cocina necesita 3 kg de queso y la Principal 10. Comparar el
--   mínimo del negocio contra el stock de un solo almacén siempre miente —
--   o inventa faltantes que no existen, o esconde los que sí.
--
-- ENTREGA:
--   1. `inventory_stock.min_stock` numeric NULO = "sin mínimo propio".
--      NULL y 0 significan cosas distintas: NULL es "no configurado" (la
--      bodega no dispara alerta), 0 es "acá no debe faltar nunca porque no
--      se guarda nada" — un mínimo explícito de cero.
--   2. `fn_inventory_set_warehouse_min_stock` para escribirlo desde la app.
--      `inventory_stock` sólo tiene policy de SELECT para `authenticated`
--      (toda escritura pasa por funciones), así que un UPDATE directo del
--      cliente se iría en silencio sin afectar filas.
--
--   La regla de negocio (que vive en la app, no acá): si la bodega tiene
--   mínimo propio, ese manda; si no lo tiene y el negocio opera con UNA
--   sola bodega, el global aplica porque son lo mismo; con varias bodegas
--   y sin mínimo propio, no hay alerta local — el global se muestra sólo
--   como referencia.
--
-- IDEMPOTENTE: sí (`add column if not exists` + `create or replace`).
-- REVERSIBLE: sí (ver _ROLLBACK). No toca ninguna columna existente ni
--   ninguna función del flujo de caja/fiscal.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. La columna
-- ---------------------------------------------------------------------------

alter table public.inventory_stock
  add column if not exists min_stock numeric;

comment on column public.inventory_stock.min_stock is
  'Mínimo de reposición de este insumo EN ESTA BODEGA. NULL = sin mínimo '
  'propio (la bodega no dispara alerta local; el min_stock global del '
  'insumo queda como referencia). Fase 2 Bodegas.';

-- Índice parcial: las consultas de la pantalla piden "los que tienen mínimo
-- propio en esta bodega", que en un negocio típico son pocas filas de todo
-- inventory_stock.
create index if not exists idx_inventory_stock_warehouse_min_stock
  on public.inventory_stock (warehouse_id)
  where min_stock is not null;

-- ---------------------------------------------------------------------------
-- 2. Escritura: RPC con chequeo de acceso
-- ---------------------------------------------------------------------------

create or replace function public.fn_inventory_set_warehouse_min_stock(
  p_warehouse_id uuid,
  p_item_id      uuid,
  p_min_stock    numeric
) returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_business_id uuid;
begin
  select w.business_id into v_business_id
    from public.warehouses w
   where w.id = p_warehouse_id;

  if v_business_id is null then
    raise exception 'La bodega no existe.' using errcode = 'P0002';
  end if;

  if not public.user_has_business_access(auth.uid(), v_business_id) then
    raise exception 'No tienes acceso a este negocio.' using errcode = '42501';
  end if;

  -- El insumo tiene que ser del MISMO negocio que la bodega: sin esto, un
  -- id de otro tenant crearía una fila de stock cruzada.
  if not exists (
    select 1 from public.inventory_items i
     where i.id = p_item_id and i.business_id = v_business_id
  ) then
    raise exception 'El insumo no pertenece a este negocio.'
      using errcode = '42501';
  end if;

  if p_min_stock is not null and p_min_stock < 0 then
    raise exception 'El mínimo no puede ser negativo.' using errcode = '22023';
  end if;

  -- La fila puede no existir todavía: configurar el mínimo de un insumo que
  -- nunca entró a esta bodega es justamente cómo se prepara la reposición.
  -- `quantity` arranca en 0 y NO se toca cuando la fila ya existía.
  insert into public.inventory_stock (warehouse_id, item_id, quantity, min_stock)
  values (p_warehouse_id, p_item_id, 0, p_min_stock)
  on conflict (warehouse_id, item_id)
  do update set min_stock = excluded.min_stock;
end;
$$;

comment on function public.fn_inventory_set_warehouse_min_stock(uuid, uuid, numeric) is
  'Fija (o borra, con NULL) el mínimo de un insumo en una bodega. '
  'SECURITY DEFINER porque inventory_stock no tiene policy de escritura '
  'para authenticated. Fase 2 Bodegas.';

grant execute on function
  public.fn_inventory_set_warehouse_min_stock(uuid, uuid, numeric)
  to authenticated;

commit;

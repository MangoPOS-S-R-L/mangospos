-- =============================================================================
-- "Mostrar los productos de esta bodega en el punto de venta".
--
-- POR QUÉ, si ya existe el área de producción:
--   El área resuelve POR PRODUCTO y sirve a un restaurante con Cocina, Bar y
--   Food Shop, donde cada plato sale de su lado. Pero un bar con dos
--   almacenes no piensa así: piensa "el punto de venta es el Bar, el otro es
--   el depósito". Obligarlo a rutear productos a un área para expresar eso
--   es hacerlo dar una vuelta larga, y en la práctica termina marcando el
--   área equivocada sobre la bodega equivocada.
--
--   Este interruptor dice lo mismo en una sola casilla, y las dos formas
--   conviven: el área manda cuando el producto tiene una; si no tiene, manda
--   la bodega del punto de venta; si tampoco hay, la principal de siempre.
--
-- ENTREGA:
--   1. `warehouses.shows_in_pos` — una sola bodega por negocio.
--   2. `fn_resolve_consumption_warehouse` con el nuevo escalón en el medio.
--
-- MUESTRA Y DESCUENTA DE LA MISMA BODEGA, a propósito:
--   El resolvedor lo usan las DOS puntas —la vista que pinta el grid y la
--   función que descuenta al vender—. Si mostrara la existencia del Bar y
--   descontara de la Principal, el inventario del bar no significaría nada
--   y nadie entendería por qué los números no cierran.
--
-- NO ESTÁ DETRÁS DE `warehouse_sections_enabled`, a diferencia del área.
--   La casilla ES el acto deliberado: se prende en una bodega concreta de un
--   negocio concreto y se apaga destildándola. La bandera sigue gobernando
--   sólo la resolución POR ÁREA, que es la que afecta a todo el menú de
--   golpe.
--
-- OJO AL PRENDERLA: si esa bodega está en cero y la mercancía está toda en
--   la otra, el menú se bloquea entero. Cargar la bodega ANTES —contándola o
--   transfiriendo— y usar el paso 4 de
--   `supabase/CONFIGURAR_bar_dos_almacenes.sql` para ver qué se va a
--   bloquear antes de tildarla.
--
-- REQUIERE: 20260901_0001 y 20260901_0002.
-- IDEMPOTENTE: sí. REVERSIBLE: sí (ver _ROLLBACK).
-- =============================================================================

begin;

-- La 20260901_0004 también la declara, porque la lee. Las dos usan
-- `add column if not exists`: se pueden aplicar en cualquier orden.
alter table public.warehouses
  add column if not exists shows_in_pos boolean not null default false;

comment on column public.warehouses.shows_in_pos is
  'El punto de venta muestra Y descuenta la existencia de esta bodega para '
  'los productos que no resuelven por área de producción. Una sola por '
  'negocio. Al prenderla, un producto en cero acá deja de poder venderse '
  'aunque haya existencia en otra bodega.';

-- Una sola por negocio: con dos, la venta tendría dos candidatos y elegiría
-- por orden de creación, que es como no elegir.
create unique index if not exists uq_warehouses_pos_source
  on public.warehouses (business_id)
  where shows_in_pos;

-- ---------------------------------------------------------------------------
-- El resolvedor, con el escalón nuevo
-- ---------------------------------------------------------------------------

create or replace function public.fn_resolve_consumption_warehouse(
  p_business_id         uuid,
  p_menu_item_id        uuid,
  p_default_warehouse_id uuid
) returns uuid
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(
    -- (1) El área del producto. Sólo si la bandera de secciones está
    -- prendida: eso cambia el menú entero de golpe y por eso va detrás de
    -- un interruptor de negocio.
    case
      when coalesce(
        (select bs.warehouse_sections_enabled
           from public.business_settings bs
          where bs.business_id = p_business_id),
        false
      ) then (
        select w.id
          from public.warehouses w
          join public.print_areas pa on pa.id = w.production_area_id
         where w.business_id = p_business_id
           and coalesce(w.is_active, true)
           and w.warehouse_type = 'production'
           and pa.id in (
             select mipa.print_area_id
               from public.menu_item_print_areas mipa
              where mipa.menu_item_id = p_menu_item_id
             union all
             -- Legacy, SÓLO si el producto no tiene filas N:M: la N:M
             -- sobrescribe al código, igual que en el ruteo de comandas.
             select pa2.id
               from public.menu_items mi
               join public.print_areas pa2
                 on pa2.business_id = mi.business_id
                and pa2.code = mi.print_area_code
              where mi.id = p_menu_item_id
                and mi.print_area_code is not null
                and not exists (
                  select 1
                    from public.menu_item_print_areas x
                   where x.menu_item_id = p_menu_item_id
                )
           )
         order by coalesce(pa.display_order, 0) asc, pa.name asc, w.id asc
         limit 1
      )
    end,

    -- (2) La bodega del punto de venta. No depende de la bandera: la casilla
    -- de esa bodega es el acto deliberado.
    (
      select w.id
        from public.warehouses w
       where w.business_id = p_business_id
         and coalesce(w.is_active, true)
         and w.shows_in_pos
       limit 1
    ),

    -- (3) Lo de siempre.
    p_default_warehouse_id
  );
$$;

comment on function public.fn_resolve_consumption_warehouse(uuid, uuid, uuid) is
  'De qué bodega sale un producto al venderse, y cuál se muestra en el grid. '
  'Orden: área de producción del producto (detrás de '
  'warehouse_sections_enabled) → bodega marcada shows_in_pos → la que se le '
  'pase por defecto. La usan la vista v_menu_items_stock y '
  'consume_inventory_from_order: mostrar y descontar salen del mismo lugar.';

grant execute on function
  public.fn_resolve_consumption_warehouse(uuid, uuid, uuid)
  to authenticated, service_role;

commit;

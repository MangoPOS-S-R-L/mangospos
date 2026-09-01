-- ROLLBACK de 20260901_0005_warehouse_pos_source.sql
--
-- Devuelve el resolvedor a la versión de 20260901_0002 (sólo área) y quita
-- la columna. Se pierde qué bodega estaba marcada para el punto de venta;
-- el stock y los movimientos no se tocan.
--
-- Después de esto, un negocio que dependía de la casilla vuelve a mostrar y
-- descontar de la bodega principal.

begin;

drop index if exists public.uq_warehouses_pos_source;

create or replace function public.fn_resolve_consumption_warehouse(
  p_business_id         uuid,
  p_menu_item_id        uuid,
  p_default_warehouse_id uuid
) returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select case
    -- (1) Bandera apagada: comportamiento histórico, sin tocar nada más.
    when not coalesce(
      (select bs.warehouse_sections_enabled
         from public.business_settings bs
        where bs.business_id = p_business_id),
      false
    ) then p_default_warehouse_id
    else coalesce(
      (
        select w.id
          from public.warehouses w
          join public.print_areas pa on pa.id = w.production_area_id
         where w.business_id = p_business_id
           and coalesce(w.is_active, true)
           and w.warehouse_type = 'production'
           and pa.id in (
             -- (2) Áreas declaradas en la N:M.
             select mipa.print_area_id
               from public.menu_item_print_areas mipa
              where mipa.menu_item_id = p_menu_item_id
             union all
             -- (3) Legacy, SOLO si el producto no tiene filas N:M.
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
         -- (4) Desempate determinista.
         order by coalesce(pa.display_order, 0) asc, pa.name asc, w.id asc
         limit 1
      ),
      -- (5) Sin área, sin almacén para esa área, o almacén desactivado.
      p_default_warehouse_id
    )
  end;
$$;

alter table public.warehouses drop column if exists shows_in_pos;

commit;

-- ============================================================================
-- Import de catálogo Square → MangoPOS
-- Business 882ef5a4-93eb-4e58-92c3-bf532e179d45 (licorería MONCION)
-- Fuente: MLYH9X2TGPA28_catalog-2026-08-11-0140.csv (export de Square)
-- ============================================================================
--
-- PASO 4 — Inventario: 1374 productos contables.
--
-- QUÉ ENTRA: todo salvo Tragos, Cócteles, Comida, Fiesta y Hookah — preparados
--   y servicios. Square les puso stock de mentira (Long Island 1000,
--   Martini 999, Mojitos 645) porque nunca se contaron. Un trago descuenta de
--   la BOTELLA, no de sí mismo: eso necesita receta, no link 1:1, y quedó fuera
--   por decisión explícita.
--
-- CÓMO: link directo menu_items.inventory_item_id → inventory_items (1:1),
--   sin recetas. Vende 1, descuenta 1.
--
-- POR QUÉ DML DIRECTO Y NO fn_menu_item_set_inventory_tracked: esa función es
--   SECURITY DEFINER y valida auth.uid() contra user_business_role. Desde el
--   SQL Editor auth.uid() es null → INSUFFICIENT_ROLE. Este script hace
--   exactamente lo mismo que la función, paso por paso.
--
-- STOCK INICIAL: 1132 productos con cantidad > 0, del conteo MONCION del
--   CSV. Se registra como movimiento 'purchase'; el trigger
--   trg_inventory_stock_sync actualiza inventory_stock solo. Las 53 cantidades
--   negativas del CSV entraron como 0 (ver 00_REPORTE.md).
--
-- inventory_mode = 'advanced' de ÚLTIMO, a propósito: hasta que se sube, el
--   motor no descuenta nada aunque los productos estén marcados.
--
-- Requiere los PASOS 1 y 2.
-- ============================================================================

begin;

do $$
declare
  v_business  uuid := '882ef5a4-93eb-4e58-92c3-bf532e179d45';
  v_warehouse uuid;
  v_creados   int;
  v_linkeados int;
  v_movs      int;
begin
  -- Bodega destino del stock inicial: la principal.
  select id into v_warehouse
  from public.warehouses
  where business_id = v_business
    and coalesce(is_active, true)
    and name is distinct from '__IN_TRANSIT__'
  order by is_main desc nulls last, created_at asc nulls first
  limit 1;

  if v_warehouse is null then
    raise exception
      'Este negocio no tiene ninguna bodega activa. Crea la bodega principal '
      'en Ajustes → Inventario antes de correr este paso.';
  end if;

  -- 1) Insumo por producto contable. Nombre idéntico al producto para que se
  --    puedan cruzar de un vistazo en la pantalla de Insumos.
  insert into public.inventory_items (business_id, sku, name, unit, cost, is_active)
  select v_business, nullif(btrim(coalesce(s.sku,'')),''), s.name, 'unidad',
         coalesce(s.cost, 0), true
  from public._import_882ef5a4 s
  where s.inventariable
    and not exists (
      select 1 from public.inventory_items ii
      where ii.business_id = v_business
        and lower(btrim(ii.name)) = lower(btrim(s.name))
    );
  get diagnostics v_creados = row_count;

  -- 2) Link directo + flag de tracking.
  update public.menu_items mi
  set inventory_item_id = ii.id,
      is_inventory_tracked = true
  from public._import_882ef5a4 s
  join public.inventory_items ii
    on ii.business_id = v_business
   and lower(btrim(ii.name)) = lower(btrim(s.name))
  where mi.business_id = v_business
    and lower(mi.name) = lower(s.name)
    and s.inventariable
    and (mi.inventory_item_id is distinct from ii.id
         or coalesce(mi.is_inventory_tracked, false) = false);
  get diagnostics v_linkeados = row_count;

  -- 3) Stock inicial. IDEMPOTENTE: solo si ese insumo no tiene ya un
  --    movimiento 'initial_stock'. Re-ejecutar NO vuelve a sumar.
  insert into public.inventory_movements (
    business_id, warehouse_id, item_id, movement_type, quantity,
    cost_per_unit, reference_type, notes
  )
  select v_business, v_warehouse, ii.id, 'purchase'::public.movement_type,
         s.qty, s.cost, 'initial_stock',
         'Stock inicial import Square (conteo MONCION) — ' || s.name
  from public._import_882ef5a4 s
  join public.inventory_items ii
    on ii.business_id = v_business
   and lower(btrim(ii.name)) = lower(btrim(s.name))
  where s.inventariable
    and s.qty > 0
    and not exists (
      select 1 from public.inventory_movements m
      where m.item_id = ii.id and m.reference_type = 'initial_stock'
    );
  get diagnostics v_movs = row_count;

  -- 4) Encender el motor. Va de último: sin esto nada descuenta.
  update public.business_settings
  set inventory_mode = 'advanced'
  where business_id = v_business
    and inventory_mode is distinct from 'advanced';

  raise notice 'insumos creados: % | productos linkeados: % | movimientos de stock inicial: %',
    v_creados, v_linkeados, v_movs;
end $$;

commit;

-- ============================================================================
-- VERIFICACIÓN
-- ============================================================================

-- A) Modo de inventario — debe decir 'advanced'
select inventory_mode from public.business_settings
where business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid;

-- B) Cobertura por categoría. `inventariables` debe ser 0 en Tragos, Cócteles,
--    Comida, Fiesta y Hookah, y = productos en todas las demás.
select
  c.position, c.name as categoria,
  count(*)                                              as productos,
  count(*) filter (where mi.is_inventory_tracked)       as inventariables,
  count(*) filter (where mi.inventory_item_id is null
                     and mi.is_inventory_tracked)       as tracked_sin_link
from public.menu_items mi
join public.categories c on c.id = mi.category_id
where mi.business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid and mi.is_active
group by c.position, c.name
order by c.position;

-- C) RED FLAG — marcado inventariable pero sin insumo: se vende sin descontar.
--    Debe dar 0 filas.
select mi.name
from public.menu_items mi
where mi.business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid and mi.is_active
  and mi.is_inventory_tracked and mi.inventory_item_id is null;

-- D) Stock cargado — top 20
select ii.name, st.quantity, ii.cost
from public.inventory_stock st
join public.inventory_items ii on ii.id = st.item_id
where ii.business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid
order by st.quantity desc
limit 20;

-- E) Total de unidades y valor del inventario cargado
select
  count(*)                                  as insumos_con_stock,
  sum(st.quantity)                          as unidades,
  round(sum(st.quantity * coalesce(ii.cost,0)), 2) as valor_costo
from public.inventory_stock st
join public.inventory_items ii on ii.id = st.item_id
where ii.business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid and st.quantity > 0;

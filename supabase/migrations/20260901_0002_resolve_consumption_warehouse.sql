-- =============================================================================
-- F1 Almacenes por sección — el resolvedor de bodega. Paso 1 de 2.
--
-- QUÉ RESUELVE:
--   Hoy la venta descuenta SIEMPRE de una sola bodega — la principal. Esta
--   función responde la pregunta que hace falta para poder cambiarlo:
--   "este producto, ¿de qué almacén tiene que salir?".
--
-- ESTA MIGRACIÓN NO CAMBIA NADA.
--   Solo crea la función. Nadie la llama todavía: quien la va a usar es
--   `consume_inventory_from_order`, y eso es el paso 2
--   (20260901_0003_consume_by_area) que se aplica aparte, después de cotejar
--   la definición VIVA de esa función contra la del repositorio. Se separan
--   a propósito: así el paso peligroso se puede revertir solo.
--
-- LA CADENA DE RESOLUCIÓN, en orden:
--   1. Bandera `warehouse_sections_enabled` apagada → la bodega de siempre.
--      Es la primera comprobación y corta todo lo demás.
--   2. El producto tiene área(s) en `menu_item_print_areas` (N:M) y alguna
--      tiene almacén de producción activo → ese almacén.
--   3. El producto NO tiene filas N:M pero sí el legacy
--      `menu_items.print_area_code` → el almacén del área con ese código.
--      El orden importa: la N:M SOBRESCRIBE al código legacy, tal como ya
--      lo hace el ruteo de comandas (ver 20260521_0003).
--   4. Varias áreas candidatas (un combo que sale de Cocina y de Bar) → la
--      de menor `display_order`, después por nombre, después por id. Es un
--      desempate DETERMINISTA y auditable, no "la primera que aparezca".
--      La solución fina —asignar el INSUMO al área en vez del producto—
--      queda anotada en el PRD para una fase posterior.
--   5. Nada de lo anterior → la bodega de siempre.
--
-- DECISIONES QUE PARECEN DETALLE Y NO LO SON:
--   · Se filtra por `warehouses.is_active` pero NO por `print_areas
--     .is_active`. Desactivar un área es una decisión de IMPRESIÓN; no
--     debería mover en silencio de dónde sale la mercancía. Desactivar el
--     ALMACÉN sí es una decisión de inventario, y ahí sí cae al de siempre.
--   · `stable` y en SQL plano (no plpgsql) para que el planificador la pueda
--     insertar en la consulta que la llame: se invoca una vez por línea de
--     la orden.
--
-- REQUIERE: 20260901_0001 (columnas de sección) y 20260521_0002
--   (`print_areas.display_order`).
-- IDEMPOTENTE: sí (create or replace).
-- REVERSIBLE: sí (ver _ROLLBACK) — nadie la llama todavía.
-- =============================================================================

begin;

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

comment on function public.fn_resolve_consumption_warehouse(uuid, uuid, uuid) is
  'De qué almacén tiene que salir un producto al venderse. Con la bandera '
  'warehouse_sections_enabled apagada devuelve siempre el almacén por '
  'defecto que se le pase — o sea, el comportamiento de siempre. F1 '
  'Almacenes por sección; ver docs/PRD_ALMACENES_REQUISICION_COMPRAS.md.';

grant execute on function
  public.fn_resolve_consumption_warehouse(uuid, uuid, uuid)
  to authenticated, service_role;

commit;

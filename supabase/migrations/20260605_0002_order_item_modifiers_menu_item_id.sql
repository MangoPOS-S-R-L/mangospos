-- =============================================================================
-- 20260605_0002 — order_item_modifiers.menu_item_id: identidad del componente
-- =============================================================================
--
-- PROBLEMA QUE RESUELVE
-- ─────────────────────
-- Los componentes elegidos de un combo se guardan como filas en
-- `order_item_modifiers`, pero SOLO con `name` (texto, ej. "Tamaño: Grande") +
-- `qty` + `price`. NO se persiste qué producto (`menu_items.id`) es cada
-- componente. Sin esa identidad, el inventario NO puede expandir un combo a
-- sus componentes para descontar stock (PRD Ofertas/Combos/Inventario, R3).
--
-- FIX
-- ───
-- Columna estructurada `order_item_modifiers.menu_item_id uuid` (FK a
-- `menu_items`), que el flujo de selección de combo poblará con el id del
-- producto-componente. Los modifiers "normales" (extras tipo "queso extra")
-- siguen con `menu_item_id` NULL — no son productos y no descuentan inventario.
--
-- NOTAS DE SEGURIDAD
--   - 100% ADITIVA: columna NULLABLE; filas existentes y modifiers normales
--     quedan en NULL, sin cambio de comportamiento.
--   - FK ON DELETE SET NULL: borrar un producto NO rompe ventas históricas;
--     el modifier solo pierde la referencia.
--   - FK NOT VALID: evita scan/lock de validación sobre filas históricas (todas
--     NULL hoy). Inserciones/updates NUEVOS sí se validan.
--   - El consumo de inventario por componente lo agrega 20260605_0003, que
--     depende de esta columna. Aplicar esta migración ANTES.
-- =============================================================================

begin;

alter table public.order_item_modifiers
  add column if not exists menu_item_id uuid;

comment on column public.order_item_modifiers.menu_item_id is
  'Producto-componente (menu_items.id) cuando este modifier representa la '
  'selección de un grupo de combo. NULL para modifiers normales (extras). '
  'Fuente para expandir un combo a sus componentes y descontar inventario.';

-- FK idempotente y NOT VALID (sin scan de histórico).
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'order_item_modifiers_menu_item_id_fkey'
  ) then
    alter table public.order_item_modifiers
      add constraint order_item_modifiers_menu_item_id_fkey
      foreign key (menu_item_id) references public.menu_items(id)
      on delete set null
      not valid;
  end if;
end$$;

-- Índice parcial: solo modifiers que son componentes de combo (acelera la
-- expansión de inventario por orden).
create index if not exists idx_order_item_modifiers_menu_item_id
  on public.order_item_modifiers (menu_item_id)
  where menu_item_id is not null;

commit;

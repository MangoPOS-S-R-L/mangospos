-- =============================================================================
-- Fase 1 — Printing v2: extender `print_areas` con metadata visual.
--
-- CONTEXTO:
--   `print_areas` ya cumple el rol de "prep_station" del modelo Toast: agrupa
--   impresoras de una misma estación (Cocina Caliente, Bar, etc.) y permite
--   asignar productos vía `menu_items.print_area_code`. No se necesita una
--   tabla `prep_stations` separada — sería duplicación.
--
--   Esta migración solo agrega metadata útil para UI/KDS:
--     - color: para colorear chips/cards en la pantalla del mesero/KDS.
--     - display_order: orden manual en listas (ej. mostrar Bar antes que
--       Postres aunque alfabéticamente vaya después).
--
--   `branch_id` se omite intencionalmente: el repo no tiene tabla `branches`
--   formal todavía. Cuando se introduzca multi-sucursal, se agrega entonces.
--
-- COMPATIBILIDAD:
--   Aditivo puro. Queries existentes que no usan `color` o `display_order`
--   siguen funcionando sin cambios.
-- =============================================================================

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Nuevas columnas
-- ─────────────────────────────────────────────────────────────────────────────

alter table public.print_areas
  add column if not exists color text;

alter table public.print_areas
  add column if not exists display_order int not null default 0;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. CHECK: color debe ser hex válido si está presente
-- ─────────────────────────────────────────────────────────────────────────────

alter table public.print_areas
  drop constraint if exists print_areas_color_format_check;
alter table public.print_areas
  add constraint print_areas_color_format_check
  check (color is null or color ~ '^#[0-9A-Fa-f]{6}$');

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Índice para ordering por business
-- ─────────────────────────────────────────────────────────────────────────────

create index if not exists idx_print_areas_business_order
  on public.print_areas (business_id, display_order, name)
  where is_active = true;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Comentarios
-- ─────────────────────────────────────────────────────────────────────────────

comment on column public.print_areas.color is
  'Color hex (#RRGGBB) para chips/cards en UI/KDS. NULL = sin color asignado, UI usa default.';

comment on column public.print_areas.display_order is
  'Orden manual para listar áreas. 0 = primera. Cuando display_order es igual, se desempata por name alfabético.';

commit;

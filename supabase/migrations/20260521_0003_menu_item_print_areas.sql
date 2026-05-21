-- =============================================================================
-- Fase 1 — Printing v2: tabla N:M productos ↔ áreas de impresión.
--
-- CONTEXTO:
--   Hoy `menu_items.print_area_code` es FK soft 1:1 — un producto va a UNA
--   sola área. Limita combos donde un solo item debe imprimir en cocina
--   caliente Y bar (ej. "Combo Hamburguesa + Cerveza"), o donde un postre
--   también debe imprimirse en el pase (expo) para coordinar entrega.
--
--   Esta tabla N:M permite asignar varias áreas por producto. La columna
--   `print_area_code` se mantiene viva para no romper código existente —
--   el backfill espeja todas las asignaciones actuales aquí.
--
-- ORDEN DE RESOLUCIÓN en código nuevo:
--   1. Si hay filas en `menu_item_print_areas` para el producto → usar esas.
--   2. Si no → caer a `menu_items.print_area_code` (legacy).
--   3. Si tampoco → error claro al enviar a cocina (igual que hoy).
--
-- COMPATIBILIDAD:
--   100% backwards-compatible. Apps viejas que solo leen `print_area_code`
--   siguen funcionando.
-- =============================================================================

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Tabla nueva
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists public.menu_item_print_areas (
  menu_item_id uuid not null references public.menu_items(id) on delete cascade,
  print_area_id uuid not null references public.print_areas(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (menu_item_id, print_area_id)
);

create index if not exists idx_menu_item_print_areas_area
  on public.menu_item_print_areas (print_area_id);

comment on table public.menu_item_print_areas is
  'N:M productos ↔ áreas. Permite que un solo menu_item se rutee a varias áreas (combo cocina+bar). Sobrescribe a menu_items.print_area_code cuando está presente.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Backfill desde menu_items.print_area_code
-- ─────────────────────────────────────────────────────────────────────────────

insert into public.menu_item_print_areas (menu_item_id, print_area_id)
select
  mi.id as menu_item_id,
  pa.id as print_area_id
from public.menu_items mi
join public.print_areas pa
  on pa.code = mi.print_area_code
 and pa.business_id = mi.business_id
where mi.print_area_code is not null
  and mi.print_area_code <> ''
on conflict do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. RLS — solo miembros del business pueden leer/escribir
-- ─────────────────────────────────────────────────────────────────────────────

alter table public.menu_item_print_areas enable row level security;

drop policy if exists "menu_item_print_areas_select" on public.menu_item_print_areas;
create policy "menu_item_print_areas_select"
  on public.menu_item_print_areas
  for select
  using (
    exists (
      select 1
      from public.menu_items mi
      join public.memberships m on m.business_id = mi.business_id
      where mi.id = menu_item_id
        and m.user_id = auth.uid()
    )
  );

drop policy if exists "menu_item_print_areas_write" on public.menu_item_print_areas;
create policy "menu_item_print_areas_write"
  on public.menu_item_print_areas
  for all
  using (
    exists (
      select 1
      from public.menu_items mi
      join public.memberships m on m.business_id = mi.business_id
      where mi.id = menu_item_id
        and m.user_id = auth.uid()
        and m.role in ('owner','admin','manager')
    )
  )
  with check (
    exists (
      select 1
      from public.menu_items mi
      join public.memberships m on m.business_id = mi.business_id
      where mi.id = menu_item_id
        and m.user_id = auth.uid()
        and m.role in ('owner','admin','manager')
    )
  );

commit;

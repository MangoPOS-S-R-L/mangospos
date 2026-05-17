-- =============================================================================
-- Inventario: asegurar columnas faltantes en `inventory_items`.
--
-- CONTEXTO:
--   La UI de Insumos hace `select is_active, costing_method, barcode,
--   tracks_lots, item_classification` desde `inventory_items`. En algunos
--   ambientes faltó aplicar las migraciones de PRD09 fase 0 y de lotes
--   (20260514_0008), provocando:
--     PostgrestException: column inventory_items.costing_method does not exist
--   y bloqueando la pantalla de Insumos por completo.
--
-- ENTREGA:
--   Esta migración consolida en un solo lugar las columnas que la UI
--   necesita, todas con `add column if not exists` para ser idempotente
--   contra negocios donde ya estaban aplicadas:
--     - costing_method (default 'average', check in 'average'|'fifo')
--     - barcode (nullable)
--     - tracks_lots (default false)
--     - updated_at (default now() + trigger touch)
--
--   `item_classification` se agrega en 20260516_0003, no se toca aquí.
--   `is_active` es columna núcleo, ya existe.
--
-- IDEMPOTENTE: sí. Todo es `if not exists`. Seguro de re-correr.
-- =============================================================================

begin;

-- 1. costing_method
alter table public.inventory_items
  add column if not exists costing_method text not null default 'average';

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'inventory_items_costing_method_check'
      and conrelid = 'public.inventory_items'::regclass
  ) then
    alter table public.inventory_items
      add constraint inventory_items_costing_method_check
      check (costing_method in ('average', 'fifo'));
  end if;
end $$;

-- 2. barcode
alter table public.inventory_items
  add column if not exists barcode text;

-- 3. tracks_lots
alter table public.inventory_items
  add column if not exists tracks_lots boolean not null default false;

comment on column public.inventory_items.tracks_lots is
  'Si true, el item rastrea lotes y fechas de vencimiento. Default false '
  '(comportamiento normal). Opt-in por item, no por negocio.';

-- 4. updated_at + trigger touch
alter table public.inventory_items
  add column if not exists updated_at timestamptz not null default now();

create or replace function public.fn_inventory_items_touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_inventory_items_touch on public.inventory_items;
create trigger trg_inventory_items_touch
before update on public.inventory_items
for each row
execute function public.fn_inventory_items_touch_updated_at();

commit;

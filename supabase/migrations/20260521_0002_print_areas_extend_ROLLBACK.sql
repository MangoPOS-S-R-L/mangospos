-- Rollback de `20260521_0002_print_areas_extend.sql`.

begin;

drop index if exists public.idx_print_areas_business_order;

alter table public.print_areas
  drop constraint if exists print_areas_color_format_check;

alter table public.print_areas
  drop column if exists display_order;

alter table public.print_areas
  drop column if exists color;

commit;

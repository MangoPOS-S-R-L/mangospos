-- ============================================================
-- "Para llevar por defecto" por modo de venta (config-driven)
-- ============================================================
-- 3 toggles independientes: el admin elige en cuáles modos las
-- órdenes nuevas arrancan marcadas "para llevar" (is_takeout). NO
-- aplica a mesas (dine-in conserva su recargo). Default false (opt-in).

begin;

alter table public.business_settings
  add column if not exists default_takeout_quick boolean default false,
  add column if not exists default_takeout_manual boolean default false,
  add column if not exists default_takeout_delivery boolean default false;

update public.business_settings set
  default_takeout_quick = coalesce(default_takeout_quick, false),
  default_takeout_manual = coalesce(default_takeout_manual, false),
  default_takeout_delivery = coalesce(default_takeout_delivery, false);

comment on column public.business_settings.default_takeout_quick is
  'Si true, las ventas rápidas nuevas arrancan marcadas para llevar.';
comment on column public.business_settings.default_takeout_manual is
  'Si true, las ventas manuales nuevas arrancan marcadas para llevar.';
comment on column public.business_settings.default_takeout_delivery is
  'Si true, los pedidos de delivery nuevos arrancan marcados para llevar.';

commit;

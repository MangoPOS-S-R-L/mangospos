-- ============================================================
-- Conversión de empaque en insumos (comprar en botellas → stock en ml)
-- ============================================================
-- Un insumo declara:
--   unit          = unidad BASE de stock (ej. ml)  [ya existía]
--   purchase_unit = unidad de COMPRA (ej. botella)
--   pack_size     = unidades base por empaque (ej. 750 ml por botella)
--
-- El stock, los movimientos, las recetas y el consumo siguen TODOS en
-- unidad base. La app convierte botella↔ml solo al entrar (compras /
-- recepción) y al mostrar. Los RPCs de inventario NO cambian.
-- Aditivo: pack_size default 1 → insumos existentes operan igual (1:1).

begin;

alter table public.inventory_items
  add column if not exists purchase_unit text;
alter table public.inventory_items
  add column if not exists pack_size numeric default 1;

update public.inventory_items
  set pack_size = coalesce(pack_size, 1)
  where pack_size is null;

comment on column public.inventory_items.unit is
  'Unidad BASE de stock (ej. ml). Stock, recetas y consumo van en esta unidad.';
comment on column public.inventory_items.purchase_unit is
  'Unidad de COMPRA (ej. botella). Solo para entrada/visualización; la app '
  'convierte a unidad base con pack_size. NULL = se compra en la unidad base.';
comment on column public.inventory_items.pack_size is
  'Unidades base por 1 unidad de compra (ej. 750 ml por botella). Default 1 '
  '= sin conversión.';

-- Snapshot en la línea de compra para que la recepción muestre/reciba en la
-- unidad de compra fielmente, aunque el insumo cambie de empaque después.
alter table public.purchase_order_items
  add column if not exists purchase_unit text;
alter table public.purchase_order_items
  add column if not exists pack_size numeric;

comment on column public.purchase_order_items.purchase_unit is
  'Snapshot de la unidad de compra del insumo al crear la orden (display).';
comment on column public.purchase_order_items.pack_size is
  'Snapshot del contenido por empaque al crear la orden. quantity_ordered y '
  'unit_cost se guardan YA en unidad base; esto es solo para mostrar/recibir '
  'en la unidad de compra.';

commit;

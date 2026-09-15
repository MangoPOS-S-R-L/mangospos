-- =============================================================================
-- DIAGNÓSTICO — ¿Qué del sistema de inventario y recetas está aplicado?
-- SOLO LECTURA. Nada de esto escribe.
--
-- POR QUÉ HACE FALTA ANTES DE APLICAR NADA:
--   `consume_inventory_from_order` (lo que descuenta inventario en cada venta)
--   tiene en el repositorio DOS RAMAS que se separaron:
--     A) 20260901_0006  POS con varios almacenes
--     B) 20260907_0003  modificadores que descuentan insumos
--        20260910_0002  una orden anulada devuelve lo consumido
--   Las dos salen de 20260901_0003 y ninguna trae lo de la otra: aplicar una
--   encima de la otra BORRA en silencio lo que ya estaba.
--   Además, 20260910_0002 hace `join public.modifier_ingredients` sin
--   candado. PostgreSQL no lo valida al crear la función: si se aplica sin
--   20260907_0001, la POS deja de poder guardar pedidos.
--
-- CÓMO CORRERLO: cada bloque por separado, en orden, y pegar los resultados.
--   Bloque 1: una tabla con cada pieza → APLICADA / FALTA.
--   Bloque 2: banderas de La Penda.
--   Bloques 3 y 4: definiciones vivas completas. Solo si las pido.
-- =============================================================================


-- 1) QUÉ ESTÁ APLICADO -------------------------------------------------------
with
consume as (
  select pg_get_functiondef(p.oid) as src
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = 'consume_inventory_from_order'
   limit 1
),
avail as (
  select pg_get_functiondef(p.oid) as src
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = 'fn_recompute_menu_items_availability'
   limit 1
),
chk(orden, migracion, pieza, tipo, objeto) as (values
  -- Unidades
  ( 1, '20260915_0001', 'Equivalencia por insumo (1 ea = 200 g)',   'col',     'inventory_items.conversion_unit'),
  -- Recetas, sub-recetas y producción
  ( 2, '20260516_0007', 'Sub-recetas (receta que produce insumo)',   'col',     'recipes.inventory_item_id'),
  ( 3, '20260516_0008', 'Órdenes de producción (preparaciones)',     'tabla',   'production_orders'),
  ( 4, '20260516_0008', 'Órdenes de producción (preparaciones)',     'fn',      'fn_production_order_complete'),
  ( 5, '20260613_0001', 'Producto terminado con stock directo',      'col',     'menu_items.inventory_item_id'),
  -- Auto-86
  ( 6, '20260516_0015', 'Auto-86 de productos',                      'trg',     'trg_movements_recompute_menu_availability'),
  ( 7, '20260517_0001', 'Permitir venta sin stock',                  'col',     'menu_items.allow_negative_sale'),
  -- Almacenes por área
  ( 8, '20260901_0001', 'Almacén por área (columnas)',               'col',     'warehouses.production_area_id'),
  ( 9, '20260901_0001', 'Almacén por área (bandera del negocio)',    'col*',    'warehouse_sections_enabled'),
  (10, '20260901_0002', 'Resolvedor de almacén de consumo',          'fn',      'fn_resolve_consumption_warehouse'),
  -- (11) 20260901_0003 «consumo por área» quedó SUPERADA por 20260901_0006: ver fila 15.
  (12, '20260901_0006', 'Disponibilidad (auto-86) con varias bodegas', 'avail', 'fn_pos_stock_warehouses'),
  (13, '20260901_0005', 'Almacén que ve la POS',                     'col*',    'shows_in_pos'),
  (14, '20260901_0006', 'POS con varios almacenes (función)',        'fn',      'fn_pos_stock_warehouses'),
  (15, '20260901_0006', 'POS con varios almacenes (en el consumo)',  'consume', 'fn_resolve_area_warehouse'),
  -- Requisiciones
  (16, '20260902_0001', 'Requisiciones internas',                    'tabla',   'requisitions'),
  (17, '20260902_0001', 'Requisiciones internas (despacho)',         'fn',      'fn_requisition_dispatch'),
  -- Conteo físico
  (18, '20260902_0005', 'Insumo nuevo entra a conteos abiertos',     'trg',     'trg_inventory_items_join_open_counts'),
  -- Capas de costo
  (19, '20260902_0012', 'Capas de costo PEPS/UEPS',                  'tabla',   'inventory_cost_layers'),
  (20, '20260902_0012', 'Capas de costo (método por negocio)',       'col*',    'inventory_costing_method'),
  (21, '20260902_0013', 'Apertura de capas desde el conteo',         'fn',      'fn_inventory_seed_opening_layers'),
  -- Modificadores que descuentan insumos
  (22, '20260907_0001', 'Modificadores con insumos (tabla)',         'tabla',   'modifier_ingredients'),
  (23, '20260907_0002', 'Venta guarda el id del modificador',        'col',     'order_item_modifiers.modifier_id'),
  (24, '20260907_0003', 'Consumo descuenta modificadores',           'consume', 'modifier_ingredients'),
  (25, '20260907_0004', 'Modificador agotado (columna)',             'col',     'modifiers.is_sold_out'),
  (26, '20260907_0004', 'Modificador agotado (trigger)',             'trg',     'trg_movements_recompute_modifier_availability'),
  -- Órdenes anuladas
  (27, '20260910_0002', 'Anulada devuelve inventario (consumo)',     'consume', 'status_ext'),
  (28, '20260910_0002', 'Anulada devuelve inventario (trigger)',     'trg',     'trg_orders_reconcile_inventory_on_status'),
  -- Consumo unificado (resuelve las dos ramas)
  (31, '20260915_0002', 'Consumo unificado (cascada + modificadores + anuladas)', 'consume', 'UNIFICADA 20260915_0002'),
  -- Proveedores (empaque por suplidor)
  (29, '20260819_0003', 'Insumos por proveedor (empaque y código)',  'tabla',   'supplier_items'),
  (30, '20260819_0003', 'Condiciones de pago estructuradas',         'col',     'suppliers.payment_terms_type')
),
res as (
  select c.orden, c.migracion, c.pieza, c.tipo, c.objeto,
         case c.tipo
           when 'tabla' then to_regclass('public.' || c.objeto) is not null
           when 'col' then exists (
             select 1 from information_schema.columns ic
              where ic.table_schema = 'public'
                and ic.table_name   = split_part(c.objeto, '.', 1)
                and ic.column_name  = split_part(c.objeto, '.', 2))
           when 'col*' then exists (
             select 1 from information_schema.columns ic
              where ic.table_schema = 'public'
                and ic.column_name  = c.objeto)
           when 'fn' then exists (
             select 1 from pg_proc p
               join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = c.objeto)
           when 'trg' then exists (
             select 1 from pg_trigger t
              where not t.tgisinternal and t.tgname = c.objeto)
           when 'consume' then coalesce(
             (select src like '%' || c.objeto || '%' from consume), false)
           when 'avail' then coalesce(
             (select src like '%' || c.objeto || '%' from avail), false)
         end as presente
    from chk c
)
select orden,
       migracion,
       pieza,
       case tipo
         when 'consume' then 'consumo contiene «' || objeto || '»'
         when 'avail'   then 'auto-86 contiene «' || objeto || '»'
         else objeto
       end as que_se_mira,
       case when presente then 'APLICADA' else 'FALTA' end as estado
  from res
union all
select 90, '—', 'Función de consumo viva: largo y huella', '',
       'largo ' || length(src) || ' · md5 ' || left(md5(src), 12)
  from consume
union all
select 91, '—', 'Copias (sobrecargas) de la función de consumo', '',
       count(*)::text
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname = 'consume_inventory_from_order'
order by orden;


-- 2) BANDERAS DE LA PENDA ----------------------------------------------------
--    Lee las filas como JSON: si una columna no existe, simplemente no sale.
select 'business_settings' as origen, e.key as campo, e.value as valor
  from public.business_settings bs,
       jsonb_each(to_jsonb(bs)) e
 where bs.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and e.key in ('inventory_mode', 'warehouse_sections_enabled',
                 'inventory_costing_method', 'allow_negative_stock')
union all
select 'businesses', e.key, e.value
  from public.businesses b,
       jsonb_each(to_jsonb(b)) e
 where b.id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and e.key in ('inventory_mode', 'warehouse_sections_enabled',
                 'inventory_costing_method')
union all
select 'almacén: ' || w.name, e.key, e.value
  from public.warehouses w,
       jsonb_each(to_jsonb(w)) e
 where w.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and e.key in ('is_main', 'is_active', 'warehouse_type', 'production_area_id',
                 'keeper_employee_id', 'requires_requisition', 'shows_in_pos')
order by 1, 2;


-- 2b) ÓRDENES CON ESTADO NULL (todas las de los negocios).
--     En 20260910_0002, una orden con `status` o `status_ext` en NULL daba
--     «anulada = NULL» y la función le devolvía el inventario aunque estuviera
--     viva. La unificada (20260915_0002) ya no cae en eso; esto dice si el caso
--     existe en esta base.
select count(*)                                    as ordenes,
       count(*) filter (where o.status is null)     as status_null,
       count(*) filter (where o.status_ext is null) as status_ext_null
  from public.orders o;


-- 3) SOLO SI LO PIDO: definición viva completa del consumo.
select pg_get_functiondef(p.oid) as consume_inventory_from_order
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname = 'consume_inventory_from_order';


-- 4) SOLO SI LO PIDO: definición viva del auto-86 y de la vista de stock.
select pg_get_functiondef(p.oid) as fn_recompute_menu_items_availability
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname = 'fn_recompute_menu_items_availability';

select pg_get_viewdef(to_regclass('public.v_menu_items_stock'), true) as v_menu_items_stock;

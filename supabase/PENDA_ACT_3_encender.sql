-- =============================================================================
-- LA PENDA EXPRESS · ACTIVAR INVENTARIO — PASO 3: ENCENDER
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- ESCRIBE. Correr al FINAL, en este orden:
--   PASO 2 (stock puesto) → área FOODSHOP creada en la app con su impresora
--   → productos de tienda pasados a FOODSHOP → TRANSFERENCIAS hechas → ESTE.
--
-- DECISIONES DEL DUEÑO (12-oct):
--   · Se encienden TODAS las recetas (las 119, aunque digan «SIN revisar por
--     cocina»). Lo que salga mal se corrige receta por receta.
--   · VENDER EN NEGATIVO: el producto sigue en la caja aunque su insumo esté
--     en 0; el stock baja de cero y sale la etiqueta «Agotado».
--   · CADA ÁREA DESCUENTA DE SU ALMACÉN, y del Almacén Principal NO se
--     descuenta nada:
--        área COCINA   → almacén Cocina
--        área BAR      → almacén Bar
--        área FOODSHOP → almacén FoodShop  (y todo lo que no tenga área)
--        Almacén Principal: solo guarda; se le transfiere a las áreas.
--
-- CÓMO LO DECIDE EL SISTEMA (consume_inventory_from_order):
--   · un producto cuya área de producción sea la de un almacén de tipo
--     «production» descuenta de ESE almacén (fn_resolve_area_warehouse, solo
--     con `warehouse_sections_enabled`). Por eso Bar pasa a «production».
--   · lo demás descuenta de los almacenes que «salen en POS». Por eso queda
--     marcado SOLO el FoodShop: el Principal deja de vender.
--
-- QUÉ HACE:
--   1. Respaldo (productos, ajustes del negocio, almacenes).
--   2. is_inventory_tracked = true en todo producto con receta.
--   3. allow_negative_sale = true en todo producto que descuenta (con receta
--      o con vínculo directo): la caja BLOQUEA tocar un producto con stock
--      ≤ 0 si no lo permite (`catalog_product_list.dart`).
--   4. Devuelve a la caja lo que el auto-86 había apagado.
--   5. Almacenes: Bar = production con el área BAR (se creó sin área);
--      «sale en POS» solo el FoodShop.
--   6. Enciende el inventario por área.
-- =============================================================================

do $$
declare
  v_biz      uuid := '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';
  v_n1 int; v_n2 int; v_n3 int; v_n int;
  v_flag     boolean;
  v_area_fs  uuid;
  v_area_bar uuid;
begin
  ---------------------------------------------------------------------------
  -- Guardas
  ---------------------------------------------------------------------------
  if to_regclass('public._penda_act_plan') is null
     or not exists (select 1 from public._penda_act_plan where aplicado_en is not null) then
    raise exception 'El PASO 2 no se ha aplicado. Encender antes de poner el stock '
                    'haría descontar contra el inventario viejo. No se tocó nada.';
  end if;

  if to_regclass('public._penda_act_bk_productos') is not null then
    raise exception 'Ya existe _penda_act_bk_productos: el PASO 3 ya se corrió. '
                    'No se tocó nada.';
  end if;

  if to_regprocedure('public.fn_resolve_area_warehouse(uuid,uuid)') is null then
    raise exception 'Falta fn_resolve_area_warehouse (20260901_0006): sin ella el '
                    'consumo por área no existe. No se tocó nada.';
  end if;

  -- Cocina ya trae su área COCINA (PASO 5 de septiembre).
  if not exists (select 1 from public.warehouses w
                   join public.print_areas pa on pa.id = w.production_area_id
                  where w.business_id = v_biz and w.name = 'Cocina'
                    and coalesce(w.is_active, true) and upper(pa.name) = 'COCINA') then
    raise exception 'El almacén Cocina no tiene el área COCINA. No se tocó nada.';
  end if;

  -- El Bar se creó a mano en septiembre SIN área (12-oct: «general», sin
  -- área). Aquí se le pone la BAR; hace falta que el área exista y el almacén.
  select pa.id into v_area_bar
    from public.print_areas pa
   where pa.business_id = v_biz and upper(pa.name) = 'BAR'
   limit 1;
  if v_area_bar is null
     or not exists (select 1 from public.warehouses
                     where business_id = v_biz and name = 'Bar' and coalesce(is_active, true)) then
    raise exception 'Falta el área BAR o el almacén Bar. No se tocó nada.';
  end if;

  -- Sin el área FOODSHOP, los productos de tienda siguen en BAR y
  -- descontarían del almacén Bar.
  select pa.id into v_area_fs
    from public.print_areas pa
   where pa.business_id = v_biz and upper(pa.name) = 'FOODSHOP'
   limit 1;
  if v_area_fs is null then
    raise exception 'No existe el área FOODSHOP. Crearla en la app (Ajustes → Áreas) con '
                    'su impresora y pasarle los productos de tienda. No se tocó nada.';
  end if;

  select count(*) into v_n
    from public.menu_items m
   where m.business_id = v_biz and coalesce(m.is_active, true)
     and (exists (select 1 from public.menu_item_print_areas x
                   where x.menu_item_id = m.id and x.print_area_id = v_area_fs)
          or m.print_area_code = (select code from public.print_areas where id = v_area_fs));
  if v_n = 0 then
    raise exception 'El área FOODSHOP no tiene productos: los de tienda siguen en BAR y '
                    'descontarían del almacén Bar. Pasarlos primero. No se tocó nada.';
  end if;

  ---------------------------------------------------------------------------
  -- 1. Respaldo
  ---------------------------------------------------------------------------
  select warehouse_sections_enabled into v_flag
    from public.business_settings where business_id = v_biz;
  create table public._penda_act_bk_ajustes as
  select v_biz as business_id, v_flag as warehouse_sections_enabled;

  create table public._penda_act_bk_almacenes3 as
  select w.id, w.name, w.warehouse_type, w.shows_in_pos, w.production_area_id
    from public.warehouses w
   where w.business_id = v_biz;

  create table public._penda_act_bk_productos as
  select m.id, m.name, m.is_inventory_tracked, m.allow_negative_sale,
         m.is_active, m.auto_disabled
    from public.menu_items m
   where m.business_id = v_biz
     and (   exists (select 1 from public.recipes r where r.menu_item_id = m.id)
          or m.inventory_item_id is not null);

  ---------------------------------------------------------------------------
  -- 2. las recetas
  ---------------------------------------------------------------------------
  update public.menu_items m
     set is_inventory_tracked = true
   where m.business_id = v_biz
     and not coalesce(m.is_inventory_tracked, false)
     and exists (select 1 from public.recipes r
                  join public.recipe_ingredients ri on ri.recipe_id = r.id
                 where r.menu_item_id = m.id and ri.inventory_item_id is not null);
  get diagnostics v_n1 = row_count;

  ---------------------------------------------------------------------------
  -- 3. vender en negativo
  ---------------------------------------------------------------------------
  update public.menu_items m
     set allow_negative_sale = true
   where m.business_id = v_biz
     and coalesce(m.is_inventory_tracked, false)
     and not coalesce(m.allow_negative_sale, false)
     and (   exists (select 1 from public.recipes r where r.menu_item_id = m.id)
          or m.inventory_item_id is not null);
  get diagnostics v_n2 = row_count;

  ---------------------------------------------------------------------------
  -- 4. lo que el auto-86 había apagado vuelve a la caja
  ---------------------------------------------------------------------------
  update public.menu_items m
     set is_active = true, auto_disabled = false
   where m.business_id = v_biz
     and coalesce(m.auto_disabled, false)
     and not coalesce(m.is_active, true);
  get diagnostics v_n3 = row_count;

  ---------------------------------------------------------------------------
  -- 5. almacenes: Bar captura su área; solo el FoodShop sale en POS
  ---------------------------------------------------------------------------
  update public.warehouses
     set warehouse_type = 'production', production_area_id = v_area_bar
   where business_id = v_biz and name = 'Bar';

  update public.warehouses
     set shows_in_pos = (name = 'FoodShop')
   where business_id = v_biz
     and shows_in_pos is distinct from (name = 'FoodShop');

  ---------------------------------------------------------------------------
  -- 6. inventario por área
  ---------------------------------------------------------------------------
  update public.business_settings
     set warehouse_sections_enabled = true
   where business_id = v_biz;

  raise notice 'LISTO — % recetas encendidas, % productos a venta en negativo, % reactivados. '
               'Cada área descuenta de su almacén; el Principal ya no vende.', v_n1, v_n2, v_n3;
end
$$;


-- ═══ VERIFICAR (una sola consulta) ══════════════════════════════════════════
--   ESPERADO: Almacen Principal «no vende»; Cocina, Bar «área …»; FoodShop
--   «sale en POS»; y en los productos: sin_venta_en_negativo = 0,
--   apagados_por_auto86 = 0, por_area = true.
select 'almacén' as que, w.name as dato,
       case when w.warehouse_type = 'production' then 'descuenta su área: ' || coalesce(pa.name, '?')
            when w.shows_in_pos then 'sale en POS (lo que no tenga área de almacén)'
            else 'no vende' end as valor
  from public.warehouses w
  left join public.print_areas pa on pa.id = w.production_area_id
 where w.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
union all
select 'productos', 'descuentan · con receta · vínculo directo · sin venta en negativo · apagados por auto-86',
       count(*) filter (where m.is_inventory_tracked and coalesce(m.is_active, true)) || ' · ' ||
       count(*) filter (where m.is_inventory_tracked and coalesce(m.is_active, true)
                          and exists (select 1 from public.recipes r where r.menu_item_id = m.id)) || ' · ' ||
       count(*) filter (where m.is_inventory_tracked and coalesce(m.is_active, true)
                          and m.inventory_item_id is not null
                          and not exists (select 1 from public.recipes r where r.menu_item_id = m.id)) || ' · ' ||
       count(*) filter (where m.is_inventory_tracked and not coalesce(m.allow_negative_sale, false)
                          and (m.inventory_item_id is not null
                               or exists (select 1 from public.recipes r where r.menu_item_id = m.id))) || ' · ' ||
       count(*) filter (where coalesce(m.auto_disabled, false) and not coalesce(m.is_active, true))
  from public.menu_items m
 where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
union all
select 'negocio', 'inventario por área',
       (select bs.warehouse_sections_enabled::text from public.business_settings bs
         where bs.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6');


-- ═══ DESHACER ═══════════════════════════════════════════════════════════════
/*
update public.menu_items m
   set is_inventory_tracked = b.is_inventory_tracked,
       allow_negative_sale  = b.allow_negative_sale,
       is_active            = b.is_active,
       auto_disabled        = b.auto_disabled
  from public._penda_act_bk_productos b
 where b.id = m.id;
update public.warehouses w
   set warehouse_type = b.warehouse_type, shows_in_pos = b.shows_in_pos,
       production_area_id = b.production_area_id
  from public._penda_act_bk_almacenes3 b
 where b.id = w.id;
update public.business_settings bs
   set warehouse_sections_enabled = b.warehouse_sections_enabled
  from public._penda_act_bk_ajustes b
 where b.business_id = bs.business_id;
drop table public._penda_act_bk_productos;
drop table public._penda_act_bk_almacenes3;
drop table public._penda_act_bk_ajustes;
*/

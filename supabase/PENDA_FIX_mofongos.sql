-- =============================================================================
-- LA PENDA EXPRESS · ARREGLO — los mofongos salen desactivados en la caja
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- ESCRIBE (solo productos; no mueve inventario).
--
-- POR QUÉ SALEN EN GRIS: la caja bloquea un producto (lo pinta al 45%) cuando
-- descuenta inventario, NO permite venta en negativo y su existencia es ≤ 0
-- en el almacén de donde descuenta (catalog_product_list.dart). Desde el
-- PASO R2 el inventario por área está encendido: los mofongos (área COCINA)
-- miran el almacén Cocina, donde no hay mofongo. O el auto-86 los apagó
-- (is_active = false, auto_disabled = true).
--
-- QUÉ HACE (lo que el dueño ya decidió el 12-oct: VENDER EN NEGATIVO):
--   1. guarda cómo estaba cada producto que toca (`_penda_fix_mof_bk`);
--   2. venta en negativo a TODO producto que descuenta (receta o vínculo
--      directo) y no la tenía;
--   3. devuelve a la caja lo que el auto-86 apagó.
-- Al final muestra los mofongos ANTES y DESPUÉS.
--
-- DESPUÉS: en cada caja, salir y volver a entrar a la pantalla de ventas
-- (o reiniciar la app) para que baje el catálogo nuevo.
-- =============================================================================

do $$
declare
  v_biz uuid := '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';
  v_neg int; v_act int;
begin
  drop table if exists public._penda_fix_mof_bk;
  create table public._penda_fix_mof_bk as
  select m.id, m.name, m.is_active, m.auto_disabled, m.is_inventory_tracked,
         m.allow_negative_sale, now() as tomado_en
    from public.menu_items m
   where m.business_id = v_biz
     and (upper(m.name) like '%MOFONGO%'
          or (coalesce(m.is_inventory_tracked, false) and not coalesce(m.allow_negative_sale, false))
          or (coalesce(m.auto_disabled, false) and not coalesce(m.is_active, true)));

  update public.menu_items m
     set allow_negative_sale = true
   where m.business_id = v_biz
     and coalesce(m.is_inventory_tracked, false)
     and not coalesce(m.allow_negative_sale, false)
     and (m.inventory_item_id is not null
          or exists (select 1 from public.recipes r where r.menu_item_id = m.id));
  get diagnostics v_neg = row_count;

  update public.menu_items m
     set is_active = true, auto_disabled = false
   where m.business_id = v_biz
     and coalesce(m.auto_disabled, false)
     and not coalesce(m.is_active, true);
  get diagnostics v_act = row_count;

  raise notice 'LISTO — % productos pasan a venta en negativo, % reactivados (estaban '
               'apagados por el auto-86).', v_neg, v_act;
end
$$;


-- ═══ LOS MOFONGOS: ANTES → AHORA ════════════════════════════════════════════
--   Si «ahora» dice activo = sí y venta en negativo = sí y AÚN salen en gris,
--   es la caja con el catálogo viejo: salir y volver a entrar a ventas.
--   Si «activo» sigue en NO y «auto-86» en no, alguien lo desactivó a mano en
--   Productos (no fue el inventario).
select m.name                                                         as producto,
       case when b.is_active then 'sí' else 'NO' end
         || ' → ' || case when m.is_active then 'sí' else 'NO' end    as activo,
       case when b.auto_disabled then 'sí' else 'no' end              as estaba_por_auto86,
       case when b.allow_negative_sale then 'sí' else 'NO' end
         || ' → ' || case when m.allow_negative_sale then 'sí' else 'NO' end
                                                                      as venta_en_negativo,
       case when m.is_inventory_tracked then 'sí' else 'no' end       as descuenta,
       case when exists (select 1 from public.recipes r where r.menu_item_id = m.id)
            then 'receta' when m.inventory_item_id is not null then 'vínculo: ' || i.name
            else '—' end                                              as de_donde,
       coalesce((select pa.name from public.menu_item_print_areas x
                   join public.print_areas pa on pa.id = x.print_area_id
                  where x.menu_item_id = m.id limit 1), m.print_area_code, '(sin área)') as area,
       regexp_replace(round(coalesce((select st.quantity from public.inventory_stock st
                    join public.warehouses w on w.id = st.warehouse_id
                   where st.item_id = m.inventory_item_id and w.name = 'Cocina'
                     and w.business_id = m.business_id), 0), 2)::text, '\.?0+$', '') as en_cocina,
       regexp_replace(round(coalesce((select sum(st.quantity) from public.inventory_stock st
                    join public.warehouses w on w.id = st.warehouse_id
                   where st.item_id = m.inventory_item_id
                     and w.business_id = m.business_id), 0), 2)::text, '\.?0+$', '') as en_total
  from public.menu_items m
  join public._penda_fix_mof_bk b on b.id = m.id
  left join public.inventory_items i on i.id = m.inventory_item_id
 where upper(m.name) like '%MOFONGO%'
 order by m.name;

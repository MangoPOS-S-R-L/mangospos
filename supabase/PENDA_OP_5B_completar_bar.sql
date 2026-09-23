-- =============================================================================
-- LA PENDA EXPRESS · OPERACIÓN INVENTARIO — PASO 5B: completar el Bar
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- LOS ALMACENES YA ESTÁN CREADOS. El diagnóstico OP 0 los encontró así:
--   Almacen Principal  general · PRINCIPAL · sale en POS · 1112 insumos
--   Cocina             production · área COCINA · 4 insumos
--   FoodShop           general · sale en POS · 79 insumos
--   Bar                general · (sin sale en POS) · 0 insumos      ← falta esto
--   __IN_TRANSIT__     general · 4 insumos       ← de sistema, NO se toca
--
-- ESTO SOLO LE PONE `shows_in_pos` AL BAR. Nada más.
--
-- POR QUÉ IMPORTA HOY: la cascada de consumo solo alcanza las bodegas con
-- `shows_in_pos`. Sin la bandera, los 26 insumos que el Bar contó quedan
-- invisibles para `fn_resolve_consumption_warehouse`: la venta los busca en
-- FoodShop o en Principal y el stock del Bar nunca se mueve.
--
-- POR QUÉ NO LE PONGO EL ÁREA BAR, aunque el Bar sea almacén propio:
--   Con `warehouse_sections_enabled = false` (como está hoy) el área no cambia
--   nada: los productos caen a la cascada igual. Pero el día que alguien
--   prenda la bandera, un producto con área sale SOLO de la bodega de su área:
--
--       área BAR   1,354 productos ruteados  vs  26 insumos contados
--
--   Los otros 1,328 se irían a negativo y el auto-86 los apagaría en plena
--   venta. Darle el área ahora no aporta nada y arma esa trampa.
--   Cuando el conteo del Bar esté completo y quieran llevar transferencias,
--   es una sola línea (está abajo, comentada).
--
-- IDEMPOTENTE: sí. REVERSIBLE: sí.
-- =============================================================================

do $$
declare
  v_biz   uuid := '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';
  v_id    uuid;
  v_shows boolean;
begin
  select exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='warehouses'
                    and column_name='shows_in_pos') into v_shows;
  if not v_shows then
    raise exception 'La columna shows_in_pos no existe (falta 20260901_0006). '
                    'No se toco nada.';
  end if;

  select id into v_id from public.warehouses
   where business_id = v_biz and lower(btrim(name)) = 'bar' limit 1;
  if v_id is null then
    raise exception 'No hay almacen llamado "Bar" en este negocio. No se toco nada.';
  end if;

  update public.warehouses
     set warehouse_type = coalesce(warehouse_type, 'general'),
         is_active      = true
   where id = v_id;

  execute 'update public.warehouses set shows_in_pos = true where id = $1' using v_id;

  raise notice 'Bar completado: general + sale en POS. El area BAR queda SIN '
               'asignar a proposito (ver cabecera).';
end
$$;


-- ─── VERIFICAR ───────────────────────────────────────────────────────────────
--   ESPERADO: Principal, FoodShop y Bar con «sale en POS». Cocina con su area.
--   __IN_TRANSIT__ sin tocar.
select w.name,
       w.warehouse_type,
       w.is_main,
       coalesce((to_jsonb(w)->>'shows_in_pos')::boolean, false) as sale_en_pos,
       pa.name                                                  as area,
       (select count(*) from public.inventory_stock s
         where s.warehouse_id = w.id)                            as insumos_con_fila
from public.warehouses w
left join public.print_areas pa on pa.id = w.production_area_id
where w.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
order by w.is_main desc, w.name;

-- Y que la bandera de secciones siga apagada.
select coalesce((to_jsonb(bs)->>'warehouse_sections_enabled'), 'sin columna')
         as warehouse_sections_enabled
from public.business_settings bs
where bs.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';


-- ─── PARA DESPUÉS: amarrar el Bar al área BAR ────────────────────────────────
--   Solo cuando el conteo del Bar esté completo (hoy son 26 insumos contra
--   1,354 productos ruteados) Y se vayan a llevar transferencias.
/*
update public.warehouses
   set production_area_id = '7ecbecde-fea1-40fd-85e8-f4e9f4def860'   -- BAR
 where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and lower(btrim(name)) = 'bar'
   and production_area_id is null
   and not exists (select 1 from public.warehouses w2
                    where w2.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
                      and w2.production_area_id = '7ecbecde-fea1-40fd-85e8-f4e9f4def860');
*/


-- ─── DESHACER ────────────────────────────────────────────────────────────────
/*
update public.warehouses set shows_in_pos = false
 where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and lower(btrim(name)) = 'bar';
*/

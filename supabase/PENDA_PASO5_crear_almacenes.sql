-- =============================================================================
-- LA PENDA EXPRESS · PASO 5 — Crear los almacenes  (v3, final)
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- CREA 2 ALMACENES. No carga stock. NO prende la bandera.
-- No toca ventas ni comandas.
--
-- LO QUE CAMBIO EN CADA VERSION (y por que):
--   v1  intentaba amarrar FoodShop a un print_area "Food" que NO EXISTE.
--       Abortó sola, sin crear nada.
--   v2  FoodShop pasa a `general` + shows_in_pos: no prepara nada, solo
--       almacena y vende, asi que la venta lo alcanza por la CASCADA.
--   v3  EL BAR ESTA DENTRO DEL FOODSHOP, y los productos ruteados a BAR
--       SON los del FoodShop: el area de impresion y la ubicacion fisica
--       son la misma cosa con dos nombres. -> no lleva almacen propio.
--       Sus 1.354 productos tienen area BAR, pero como ninguna bodega
--       declara esa area, el resolvedor no encuentra "bodega del area" y
--       caen a la cascada: FoodShop primero, Principal despues. Que es
--       justo donde estan fisicamente. Las 26 lineas de BAR-DH se suman
--       al conteo del FoodShop.
--
-- EL MAPEO FINAL:
--   Almacen Principal  general      (YA EXISTE)  <- Diego/Furgon      326
--   Cocina             production   area COCINA  <- Almacen Cocina     53
--   FoodShop           general      shows_in_pos <- Rosayra 266
--                                                 + Winnifer 203
--                                                 + BAR-DH    26  = 495
--                                                                  ─────
--                                                                    874
--
-- =============================================================================
-- ⚠️  NO PRENDER `warehouse_sections_enabled` TODAVIA.
--
--     Con la bandera prendida, un producto que tiene area sale SOLO de la
--     bodega de esa area: no cae a la cascada. Los del BAR quedan a salvo
--     (no hay bodega de esa area -> caen a la cascada), pero COCINA no:
--
--         COCINA   202 productos ruteados  vs   53 insumos contados
--
--     Esos 202 descontarian solo de los 53 insumos de Cocina. Primero hay
--     que terminar de contar Cocina.
-- =============================================================================
-- DECISION PENDIENTE (no urge: solo importa con la bandera prendida)
--
--   FoodShop queda SIN production_area_id, o sea en la cascada: la venta
--   descuenta de donde haya stock, sin transferencias.
--
--   La alternativa es amarrarlo al area BAR. Es lo preciso —esos productos
--   viven y se consumen ahi— pero entonces descuentan SOLO de FoodShop y
--   hay que reponer desde el Principal con transferencias. Hoy no da:
--   495 insumos contados para 1.354 productos ruteados a BAR; el resto
--   se iria a negativo.
--
--   Cuando el conteo del FoodShop este completo y quieran llevar
--   transferencias, es una sola linea:
--
--     update public.warehouses
--        set production_area_id = '7ecbecde-fea1-40fd-85e8-f4e9f4def860'  -- BAR
--      where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
--        and name = 'FoodShop';
-- =============================================================================

do $$
declare
  v_biz       uuid := '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';
  v_area_coc  uuid := '230bf3db-2996-4fcb-a6ce-e2400e2d9cd7';  -- COCINA
  v_faltan    int;
  v_shows     boolean;
  v_creados   int := 0;
  v_saltados  int := 0;
  r           record;
begin
  ---------------------------------------------------------------------------
  -- Guarda 1: columnas de 20260901_0001.
  ---------------------------------------------------------------------------
  select 4 - count(*) into v_faltan
  from information_schema.columns
  where table_schema = 'public' and table_name = 'warehouses'
    and column_name in ('warehouse_type','production_area_id',
                        'keeper_employee_id','requires_requisition');
  if v_faltan > 0 then
    raise exception 'Faltan % columnas de warehouses (20260901_0001). No se creo nada.', v_faltan;
  end if;

  ---------------------------------------------------------------------------
  -- Guarda 2: las dos areas tienen que existir y ser de ESTE negocio.
  ---------------------------------------------------------------------------
  if not exists (select 1 from public.print_areas
                  where id = v_area_coc and business_id = v_biz) then
    raise exception 'El print_area COCINA (%) no existe en este negocio. No se creo nada.', v_area_coc;
  end if;

  -- ¿existe la columna shows_in_pos? (la trae 20260901_0006)
  select exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='warehouses'
                    and column_name='shows_in_pos') into v_shows;

  ---------------------------------------------------------------------------
  -- Los tres almacenes.
  ---------------------------------------------------------------------------
  for r in
    select * from (values
      ('Cocina',   'production', v_area_coc, false),
      -- Bar NO lleva almacen: esta dentro del FoodShop. Sus productos caen
      -- a la cascada porque ninguna bodega declara el area BAR.
      ('FoodShop', 'general',    null::uuid, true )   -- ubicacion, no area
    ) as t(nombre, tipo, area, en_pos)
  loop
    if exists (select 1 from public.warehouses w
               where w.business_id = v_biz
                 and lower(trim(w.name)) = lower(r.nombre)) then
      raise notice 'Almacen "%" ya existe: se salta', r.nombre;
      v_saltados := v_saltados + 1;
      continue;
    end if;

    if r.area is not null
       and exists (select 1 from public.warehouses w
                   where w.business_id = v_biz and w.production_area_id = r.area) then
      raise exception 'El area de "%" ya tiene almacen. Un area no puede tener dos. '
                      'No se creo nada.', r.nombre;
    end if;

    insert into public.warehouses
      (business_id, name, warehouse_type, production_area_id, is_main, is_active)
    values
      (v_biz, r.nombre, r.tipo, r.area, false, true);

    if v_shows and r.en_pos then
      execute 'update public.warehouses set shows_in_pos = true
                where business_id = $1 and lower(trim(name)) = lower($2)'
        using v_biz, r.nombre;
    end if;

    v_creados := v_creados + 1;
    raise notice 'Creado "%" (%)', r.nombre, r.tipo;
  end loop;

  ---------------------------------------------------------------------------
  -- El Principal: general, y visible en POS para que la cascada lo alcance.
  ---------------------------------------------------------------------------
  update public.warehouses
     set warehouse_type = coalesce(warehouse_type, 'general')
   where business_id = v_biz and is_main;

  if v_shows then
    execute 'update public.warehouses set shows_in_pos = true
              where business_id = $1 and is_main and shows_in_pos is distinct from true'
      using v_biz;
  end if;

  raise notice 'LISTO — creados: %, ya existian: %. La bandera sigue APAGADA.',
    v_creados, v_saltados;
end
$$;


-- ─── VERIFICAR ───────────────────────────────────────────────────────────────
--   ESPERADO: 3 filas. Principal y FoodShop general; Cocina production con
--   su area. Todos en 0 items: el stock va en el paso 6.
select w.name, w.warehouse_type, w.is_main,
       pa.name                                        as area_de_produccion,
       (select count(*) from public.inventory_stock s
         where s.warehouse_id = w.id)                  as items_con_stock
from public.warehouses w
left join public.print_areas pa on pa.id = w.production_area_id
where w.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
order by w.is_main desc, w.warehouse_type, w.name;

-- Y que la bandera siga apagada.
select warehouse_sections_enabled
from public.business_settings
where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';


-- ─── DESHACER ────────────────────────────────────────────────────────────────
/*
delete from public.warehouses w
 where w.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and w.name in ('Cocina','FoodShop')
   and not exists (select 1 from public.inventory_stock s     where s.warehouse_id = w.id)
   and not exists (select 1 from public.inventory_movements m where m.warehouse_id = w.id);
*/

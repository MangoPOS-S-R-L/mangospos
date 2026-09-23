-- =============================================================================
-- LA PENDA EXPRESS · PASO 5 — Crear los almacenes  (v4)
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- CREA / COMPLETA 3 ALMACENES. No carga stock. NO prende la bandera.
-- No toca ventas ni comandas. Idempotente: se puede correr de nuevo.
--
-- LO QUE CAMBIO EN CADA VERSION (y por que):
--   v1  intentaba amarrar FoodShop a un print_area "Food" que NO EXISTE.
--       Abortó sola, sin crear nada.
--   v2  FoodShop pasa a `general` + shows_in_pos: no prepara nada, solo
--       almacena y vende, asi que la venta lo alcanza por la CASCADA.
--   v3  el Bar se metia dentro del FoodShop (sin almacen propio).
--   v4  DECISION DEL DUEÑO (22-09): el Bar lleva almacen PROPIO y se queda
--       con el area BAR. Si ya lo creaste a mano, este script NO lo duplica:
--       lo ADOPTA y le completa lo que le falte (tipo, area, shows_in_pos).
--
-- EL MAPEO FINAL:
--   Almacen Principal  general      (YA EXISTE)  <- Diego/Furgon      326
--   Cocina             production   area COCINA  <- Almacen Cocina     53
--   FoodShop           general      shows_in_pos <- Rosayra 266
--                                                 + Winnifer 203  =  469
--   Bar                general      area BAR     <- BAR-DH            26
--                                                                   ─────
--                                                                     874
--
-- =============================================================================
-- ⚠️  NO PRENDER `warehouse_sections_enabled`. ESTO ES LO IMPORTANTE DE v4.
--
--     Con la bandera APAGADA (hoy) un producto con area igual cae a la
--     cascada, asi que darle area al Bar no cambia nada y no rompe nada.
--
--     Con la bandera PRENDIDA, un producto sale SOLO de la bodega de su
--     area. Y ahi el Bar es una bomba:
--
--         area BAR   1,354 productos ruteados  vs   26 insumos contados
--         area COCINA  202 productos ruteados  vs   53 insumos contados
--
--     Los 1,328 productos del Bar sin insumo en su bodega se irian a
--     negativo, y como `allow_negative_sale = false` el auto-86 los apaga
--     EN PLENA VENTA. Antes de prender la bandera hay que terminar de
--     contar Bar y Cocina, o quitarles el area a esas dos bodegas.
-- =============================================================================

do $$
declare
  v_biz       uuid := '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';
  v_area_coc  uuid := '230bf3db-2996-4fcb-a6ce-e2400e2d9cd7';  -- COCINA
  v_area_bar  uuid := '7ecbecde-fea1-40fd-85e8-f4e9f4def860';  -- BAR
  v_faltan    int;
  v_shows     boolean;
  v_creados   int := 0;
  v_adoptados int := 0;
  v_id        uuid;
  v_area_hoy  uuid;
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
  if not exists (select 1 from public.print_areas
                  where id = v_area_bar and business_id = v_biz) then
    raise exception 'El print_area BAR (%) no existe en este negocio. No se creo nada.', v_area_bar;
  end if;

  -- ¿existe la columna shows_in_pos? (la trae 20260901_0006)
  select exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='warehouses'
                    and column_name='shows_in_pos') into v_shows;

  ---------------------------------------------------------------------------
  -- Los tres almacenes. Si ya existe uno con ese nombre, se ADOPTA.
  ---------------------------------------------------------------------------
  for r in
    select * from (values
      ('Cocina',   'production', v_area_coc, false),
      ('FoodShop', 'general',    null::uuid, true ),  -- ubicacion, no area
      ('Bar',      'general',    v_area_bar, true )   -- decision del dueño, v4
    ) as t(nombre, tipo, area, en_pos)
  loop
    select w.id, w.production_area_id into v_id, v_area_hoy
      from public.warehouses w
     where w.business_id = v_biz
       and lower(trim(w.name)) = lower(r.nombre)
     limit 1;

    -- Un area no puede tener dos bodegas: el resolvedor tomaria una sola y
    -- la otra quedaria muerta. Se revisa ANTES de escribir.
    if r.area is not null
       and exists (select 1 from public.warehouses w
                   where w.business_id = v_biz
                     and w.production_area_id = r.area
                     and (v_id is null or w.id <> v_id)) then
      raise exception 'El area de "%" ya la tiene otra bodega. No se creo nada.', r.nombre;
    end if;

    if v_id is null then
      insert into public.warehouses
        (business_id, name, warehouse_type, production_area_id, is_main, is_active)
      values
        (v_biz, r.nombre, r.tipo, r.area, false, true)
      returning id into v_id;
      v_creados := v_creados + 1;
      raise notice 'Creado "%" (%)', r.nombre, r.tipo;
    else
      -- ADOPCION: solo se rellena lo que este vacio. Nunca se pisa una
      -- configuracion que alguien puso a proposito.
      update public.warehouses
         set warehouse_type     = coalesce(warehouse_type, r.tipo),
             production_area_id = coalesce(production_area_id, r.area),
             is_active          = true
       where id = v_id;
      v_adoptados := v_adoptados + 1;
      raise notice 'Adoptado "%" (ya existia) — area antes: %', r.nombre, v_area_hoy;
    end if;

    if v_shows and r.en_pos then
      execute 'update public.warehouses set shows_in_pos = true where id = $1'
        using v_id;
    end if;
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

  raise notice 'LISTO — creados: %, adoptados: %. La bandera sigue APAGADA.',
    v_creados, v_adoptados;
end
$$;


-- ─── VERIFICAR ───────────────────────────────────────────────────────────────
--   ESPERADO: 4 filas. Principal, FoodShop y Bar general; Cocina production.
--   Cocina con area COCINA y Bar con area BAR. Todos en 0 items: el stock
--   entra al cerrar los conteos (paso siguiente).
select w.name, w.warehouse_type, w.is_main,
       pa.name                                        as area_de_produccion,
       (select count(*) from public.inventory_stock s
         where s.warehouse_id = w.id)                  as items_con_stock
from public.warehouses w
left join public.print_areas pa on pa.id = w.production_area_id
where w.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
order by w.is_main desc, w.warehouse_type, w.name;

-- Y que la bandera siga apagada. Si esto sale `true`, APAGARLA antes de seguir.
select coalesce((to_jsonb(bs)->>'warehouse_sections_enabled'), 'sin columna')
         as warehouse_sections_enabled
from public.business_settings bs
where bs.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';


-- ─── DESHACER ────────────────────────────────────────────────────────────────
--   Solo borra las bodegas VACIAS que creo este script. Una bodega con stock
--   o con movimientos no se toca: borrarla dejaria el historial colgando.
/*
delete from public.warehouses w
 where w.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and w.name in ('Cocina','FoodShop','Bar')
   and not exists (select 1 from public.inventory_stock s     where s.warehouse_id = w.id)
   and not exists (select 1 from public.inventory_movements m where m.warehouse_id = w.id)
   and not exists (select 1 from public.physical_count_sessions p where p.warehouse_id = w.id);
*/

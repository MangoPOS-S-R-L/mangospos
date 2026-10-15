-- =============================================================================
-- LA PENDA EXPRESS · ACTIVAR INVENTARIO — PASO 1: PREPARAR el plan
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- NO TOCA EL INVENTARIO. Solo arma la tabla de trabajo `_penda_act_plan`
-- (una fila por almacén × insumo) y al final muestra el resumen. El PASO 2
-- aplica EXACTAMENTE lo que quedó en esa tabla. Se puede correr las veces que
-- haga falta mientras el PASO 2 no se haya corrido.
--
-- DECISIONES DEL DUEÑO (12-oct):
--   · Se usan SOLO los 4 conteos del 1-OCT. Los 5 del 1-sep
--     (PC-2026-000002..000006) NO se usan y se quedan ABIERTOS: el dueño los
--     guarda para un conteo posterior.
--   · Stock final = lo CONTADO + lo que se movió desde el congelado del 1-oct
--     (compras, ventas, mermas, transferencias, anulaciones de compra).
--   · Lo que NADIE contó queda solo con lo movido desde el congelado
--     (lo que no apareció en el conteo no existía).
--   · CADA ÁREA DESCUENTA DE SU ALMACÉN (dueño, 12-oct): cocina de Cocina,
--     bar de Bar, tienda de FoodShop. Del Almacén Principal NO se descuenta
--     nada: solo guarda, y se transfiere a las áreas. Eso lo enciende el
--     PASO 3, después de las transferencias.
--
-- CADA CONTEO VA A SU ALMACÉN:
--   PC-2026-000008  Almacén Principal · Santiago/Diego  → Almacen Principal
--   PC-2026-000009  FoodShop · Rosayra                  → FoodShop
--   PC-2026-000011  Cocina · Robinson                   → Cocina
--   PC-2026-000012  Conteo de bar 1/10/2026             → Bar
--
-- QUÉ SE REAPLICA DESDE EL CONGELADO (se SUMAN las compras y se RESTAN las
-- ventas, dueño 12-oct):
--   todo movimiento que no sea ajuste (compras, ventas, mermas,
--   transferencias, anulaciones de compra), más:
--   · los ajustes hechos DESPUÉS de terminar de contar. Son entradas reales:
--     las tandas que hace la cocina (CHIVO GUISADO +34/+30, SANCOCHO PENDA
--     +34) y compras metidas como ajuste (MENTAS HALLS +309);
--   · las salidas con motivo (rotura, vencido, limpieza, robo, donación,
--     consumo interno), las anulaciones de recepción y las bajas de lote.
-- QUÉ NO SE REAPLICA:
--   los ajustes manuales hechos MIENTRAS se contaba (entre el congelado y el
--   último número tecleado del 1-oct, p. ej. FRUIT SNACKS «conteo»): son
--   correcciones que el conteo ya reemplaza. La sección P3 los lista.
--
-- EL CUADRE (v_cuadre = true):
--   Hasta hoy la caja vende PRIMERO del Principal y después del FoodShop, y la
--   cocina nunca descontó de Cocina. Por eso lo que se vendió del anaquel del
--   FoodShop (o de la cocina) se restó del Principal, que queda NEGATIVO
--   mientras el otro almacén conserva lo contado. Un negativo es físicamente
--   imposible: el cuadre lo compensa con lo que el MISMO insumo tenga en otro
--   almacén (primero el Principal, luego FoodShop, Bar y Cocina), solo lo
--   justo para dejarlo en 0. El total de cada insumo no cambia.
--
-- POR QUÉ UNA SOLA FOTO: el stock de hoy y lo movido desde el 1-oct se leen
-- en la MISMA sentencia. Así, una venta que entre después (incluso mientras
-- corre el PASO 2) se conserva: el PASO 2 aplica diferencias, no pisa.
-- =============================================================================

do $$
declare
  v_biz     uuid    := '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';
  v_cuadre  boolean := true;
  v_n       int;
  v_fin_conteo timestamptz;   -- último número tecleado en los 4 conteos
begin
  ---------------------------------------------------------------------------
  -- Guardas
  ---------------------------------------------------------------------------
  if to_regclass('public._penda_act_plan') is not null then
    select count(*) into v_n from public._penda_act_plan where aplicado_en is not null;
    if v_n > 0 then
      raise exception 'El plan YA se aplicó (% filas con aplicado_en). No se rehace: '
                      'para volver atrás está el DESHACER del PASO 2.', v_n;
    end if;
    drop table public._penda_act_plan;
  end if;
  drop table if exists public._penda_act_cuadre;

  select count(*) into v_n
    from public.physical_count_sessions
   where business_id = v_biz and status = 'in_progress'
     and code in ('PC-2026-000008','PC-2026-000009','PC-2026-000011','PC-2026-000012');
  if v_n <> 4 then
    raise exception 'Se esperaban los 4 conteos del 1-oct abiertos (in_progress) y hay %. '
                    'No se armó nada.', v_n;
  end if;

  -- Abiertas solo pueden quedar, además de las 4, las 5 de septiembre (que se
  -- quedan abiertas). Cualquier otra es un conteo nuevo que nadie ha mirado.
  select count(*) into v_n
    from public.physical_count_sessions
   where business_id = v_biz and status in ('draft','in_progress')
     and code not in ('PC-2026-000008','PC-2026-000009','PC-2026-000011','PC-2026-000012',
                      'PC-2026-000002','PC-2026-000003','PC-2026-000004',
                      'PC-2026-000005','PC-2026-000006');
  if v_n > 0 then
    raise exception 'Hay % sesiones de conteo abiertas que no son las de octubre ni las '
                    'de septiembre. Revisar antes de seguir. No se armó nada.', v_n;
  end if;

  -- Hasta cuándo se estuvo contando: los ajustes de antes son correcciones
  -- del conteo, los de después son operación real.
  select max(l.updated_at) into v_fin_conteo
    from public.physical_count_lines l
    join public.physical_count_sessions s on s.id = l.session_id
   where s.business_id = v_biz and s.status = 'in_progress'
     and s.code in ('PC-2026-000008','PC-2026-000009','PC-2026-000011','PC-2026-000012')
     and l.counted_quantity is not null;
  if v_fin_conteo is null then
    raise exception 'Los 4 conteos no tienen ni un renglón contado. No se armó nada.';
  end if;

  select count(*) into v_n
    from public.warehouses
   where business_id = v_biz and coalesce(is_active, true)
     and name in ('Almacen Principal','Cocina','FoodShop','Bar');
  if v_n <> 4 then
    raise exception 'Faltan almacenes: hay % de 4 (Almacen Principal, Cocina, FoodShop, Bar). '
                    'No se armó nada.', v_n;
  end if;

  ---------------------------------------------------------------------------
  -- El plan, en UNA sola sentencia (una sola foto de stock + movimientos)
  ---------------------------------------------------------------------------
  create table public._penda_act_plan (
    warehouse_id    uuid not null,
    almacen         text not null,
    item_id         uuid not null,
    insumo          text,
    unidad          text,
    costo           numeric,
    session_id      uuid,          -- sesión a la que se le asienta el ajuste
    line_id         uuid,          -- renglón contado que se conserva
    lineas_contadas int  not null default 0,
    stock_hoy       numeric not null,
    contado         numeric,       -- null = nadie lo contó en este almacén
    neto            numeric not null,
    movs            int  not null,
    desde           timestamptz not null,
    final           numeric not null,   -- contado (o 0) + neto
    delta           numeric not null,   -- final − stock_hoy
    cuadre          numeric not null default 0,  -- + recibe del Principal / − entrega
    creado_en       timestamptz not null default now(),
    fin_conteo      timestamptz,
    mov_conteo      uuid,
    aplicado_en     timestamptz,
    primary key (warehouse_id, item_id)
  );

  insert into public._penda_act_plan
    (warehouse_id, almacen, item_id, insumo, unidad, costo, session_id, line_id,
     lineas_contadas, stock_hoy, contado, neto, movs, desde, final, delta)
  with
  mapa(code, almacen) as (values
    ('PC-2026-000008','Almacen Principal'),
    ('PC-2026-000009','FoodShop'),
    ('PC-2026-000011','Cocina'),
    ('PC-2026-000012','Bar')),
  ses as (
    select s.id, s.code, w.id as wid, w.name as almacen,
           coalesce(s.frozen_at, s.started_at) as desde
      from public.physical_count_sessions s
      join mapa m on m.code = s.code
      join public.warehouses w
        on w.business_id = s.business_id and w.name = m.almacen
       and coalesce(w.is_active, true)
     where s.business_id = v_biz and s.status = 'in_progress'
  ),
  alm as (
    -- por almacén: desde cuándo reaplicar y a qué sesión asentar lo no contado
    select wid, almacen, min(desde) as desde,
           (array_agg(id order by code desc))[1] as session_id
      from ses group by wid, almacen
  ),
  -- almacén físico → almacén del plan (hoy, uno a uno)
  fisico as (
    select a.wid as wid_fis, a.wid as wid_plan from alm a
  ),
  contado as (
    select se.wid, l.item_id,
           sum(l.counted_quantity) as qty,
           count(*)                as n,
           (array_agg(l.id order by se.code desc))[1] as line_id,
           (array_agg(se.id order by se.code desc))[1] as session_id
      from public.physical_count_lines l
      join ses se on se.id = l.session_id
     where l.counted_quantity is not null
     group by se.wid, l.item_id
  ),
  movido as (
    select f.wid_plan as wid, im.item_id,
           sum(im.quantity) as neto, count(*) as n
      from public.inventory_movements im
      join fisico f on f.wid_fis = im.warehouse_id
      join alm a on a.wid = f.wid_plan
     where im.business_id = v_biz
       and im.created_at >= a.desde
       and (   im.movement_type::text <> 'adjustment'
            or im.created_at > v_fin_conteo
            or coalesce(im.reference_type,'') in ('direct_receipt_cancel','lot_disposal')
            or (im.quantity < 0 and im.reason_code in
                  ('breakage','expiration','cleaning','theft','donation','internal_use')))
     group by f.wid_plan, im.item_id
  ),
  stock as (
    select st.warehouse_id as wid, st.item_id, st.quantity
      from public.inventory_stock st
      join fisico f on f.wid_fis = st.warehouse_id
  ),
  pares as (
    select wid, item_id from contado
    union select wid, item_id from movido
    union select wid, item_id from stock where quantity <> 0
  ),
  plan_alm as (
    select a.wid, a.almacen, a.session_id, a.desde, false as se_vacia from alm a
  )
  select p.wid, a.almacen, p.item_id, i.name, i.unit, coalesce(i.cost, 0),
         coalesce(c.session_id, a.session_id), c.line_id, coalesce(c.n, 0),
         coalesce(s.quantity, 0),
         c.qty,
         coalesce(m.neto, 0), coalesce(m.n, 0), a.desde,
         case when a.se_vacia then 0
              else coalesce(c.qty, 0) + coalesce(m.neto, 0) end,
         case when a.se_vacia then 0
              else coalesce(c.qty, 0) + coalesce(m.neto, 0) end - coalesce(s.quantity, 0)
    from pares p
    join plan_alm a on a.wid = p.wid
    join public.inventory_items i on i.id = p.item_id
    left join stock   s on s.wid = p.wid and s.item_id = p.item_id
    left join contado c on c.wid = p.wid and c.item_id = p.item_id
    left join movido  m on m.wid = p.wid and m.item_id = p.item_id;

  update public._penda_act_plan set fin_conteo = v_fin_conteo;

  ---------------------------------------------------------------------------
  -- El cuadre: cada negativo se compensa con lo que el MISMO insumo tenga en
  -- otro almacén. Se reparte por tramos: los negativos en fila (el más
  -- negativo primero) contra los positivos en fila (Principal, FoodShop,
  -- Cocina); cada par se lleva lo que sus tramos se solapan.
  ---------------------------------------------------------------------------
  create table public._penda_act_cuadre (
    item_id    uuid not null,
    desde_wid  uuid not null,
    desde      text not null,
    hacia_wid  uuid not null,
    hacia      text not null,
    qty        numeric not null check (qty > 0),
    costo      numeric
  );

  if v_cuadre then
    insert into public._penda_act_cuadre
      (item_id, desde_wid, desde, hacia_wid, hacia, qty, costo)
    with
    neg as (
      select item_id, warehouse_id, almacen, costo, -final as q,
             coalesce(sum(-final) over (partition by item_id order by final asc, warehouse_id
                        rows between unbounded preceding and 1 preceding), 0) as ini
        from public._penda_act_plan
       where final < 0
    ),
    pos as (
      select item_id, warehouse_id, almacen, final as q,
             coalesce(sum(final) over (partition by item_id order by orden, warehouse_id
                        rows between unbounded preceding and 1 preceding), 0) as ini
        from (select *, case almacen when 'Almacen Principal' then 1
                                     when 'FoodShop' then 2
                                     when 'Bar' then 3 else 4 end as orden
                from public._penda_act_plan
               where final > 0) x
    )
    select n.item_id, p.warehouse_id, p.almacen, n.warehouse_id, n.almacen,
           least(n.ini + n.q, p.ini + p.q) - greatest(n.ini, p.ini),
           n.costo
      from neg n
      join pos p on p.item_id = n.item_id
     where least(n.ini + n.q, p.ini + p.q) > greatest(n.ini, p.ini);

    update public._penda_act_plan p
       set cuadre = coalesce((select sum(c.qty) from public._penda_act_cuadre c
                               where c.item_id = p.item_id and c.hacia_wid = p.warehouse_id), 0)
                  - coalesce((select sum(c.qty) from public._penda_act_cuadre c
                               where c.item_id = p.item_id and c.desde_wid = p.warehouse_id), 0)
     where exists (select 1 from public._penda_act_cuadre c where c.item_id = p.item_id);
  end if;

  select count(*) into v_n from public._penda_act_plan;
  raise notice 'Plan armado: % pares (almacén, insumo). Revisar el resumen y correr el PASO 2.', v_n;
end
$$;


-- ═══ RESUMEN — una sola consulta ════════════════════════════════════════════
--   P1  por almacén: cuánto vale hoy y cuánto quedará
--   P2  lo que se reaplica desde el congelado, por tipo
--   P3  los ajustes de mientras se contaba, que NO se reaplican
--   P4  el cuadre: cuánto pasa de qué almacén a cuál
--   P5  los 15 cambios más grandes al costo (revisar que no haya disparates)
--   P6  Cocina aparte: insumos del área COCINA que quedan fuera de Cocina
--       (saldrán «Agotado» en la caja hasta que se transfieran)
--   P7  los conteos más caros, para revisar la unidad
with
biz as (select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as id),
p as (select *, final + cuadre as final_cuadrado from public._penda_act_plan),
alm as (select warehouse_id, min(desde) as desde, max(fin_conteo) as fin from p group by warehouse_id),

p1 as (
  select 1 as orden, 'P1 por almacén' as seccion, almacen as dato,
         concat_ws(' · ',
           count(*) || ' insumos',
           count(*) filter (where contado is not null) || ' contados',
           count(*) filter (where contado is null and stock_hoy <> 0) || ' NO contados con stock hoy',
           'hoy '   || to_char(sum(greatest(stock_hoy,0) * costo) filter (where stock_hoy <= 100000),
                               'FM999,999,999.00'),
           'queda ' || to_char(sum(greatest(final_cuadrado,0) * costo), 'FM999,999,999.00'),
           count(*) filter (where final_cuadrado < 0) || ' en negativo'
         ) as valor,
         0::numeric as peso
    from p group by almacen
),
p2 as (
  select 2, 'P2 se reaplica desde ' || to_char(min(a.desde), 'DD-Mon'),
         im.movement_type::text ||
           case when im.movement_type::text = 'adjustment'
                then ' (después de contar, desde ' ||
                     to_char(max(a.fin) at time zone 'America/Santo_Domingo', 'DD-Mon HH24:MI') || ')'
                else '' end,
         count(*) || ' movimientos · ' || count(distinct im.item_id) || ' insumos · neto '
           || round(sum(im.quantity), 2),
         0::numeric
    from public.inventory_movements im
    join alm a on a.warehouse_id = im.warehouse_id, biz
   where im.business_id = biz.id and im.created_at >= a.desde
     and (   im.movement_type::text <> 'adjustment'
          or im.created_at > a.fin
          or coalesce(im.reference_type,'') in ('direct_receipt_cancel','lot_disposal')
          or (im.quantity < 0 and im.reason_code in
                ('breakage','expiration','cleaning','theft','donation','internal_use')))
   group by im.movement_type
),
p3 as (
  select 3, 'P3 ajustes de MIENTRAS se contaba (no se reaplican)', x.dato, x.valor, x.peso from (
    select to_char(im.created_at, 'DD-Mon') || ' · ' || i.name as dato,
           concat_ws(' · ',
             trim(to_char(im.quantity, 'FM9999999999999990.00')) || ' ' || coalesce(i.unit,''),
             w.name,
             coalesce(im.reason_code, 'sin motivo'),
             nullif(left(coalesce(im.notes,''), 60), '')) as valor,
           abs(im.quantity * coalesce(i.cost,0)) as peso
      from public.inventory_movements im
      join alm a on a.warehouse_id = im.warehouse_id
      join public.inventory_items i on i.id = im.item_id
      join public.warehouses w on w.id = im.warehouse_id, biz
     where im.business_id = biz.id and im.created_at >= a.desde
       and im.movement_type::text = 'adjustment'
       and im.created_at <= a.fin
       and not (   coalesce(im.reference_type,'') in ('direct_receipt_cancel','lot_disposal')
                or (im.quantity < 0 and im.reason_code in
                      ('breakage','expiration','cleaning','theft','donation','internal_use')))
     order by abs(im.quantity * coalesce(i.cost,0)) desc nulls last
     limit 15
  ) x
),
p4 as (
  select 4, 'P4 cuadre', c.desde || ' → ' || c.hacia,
         count(*) || ' insumos · ' || round(sum(c.qty), 2) || ' unidades · '
           || to_char(sum(c.qty * coalesce(c.costo, 0)), 'FM999,999,999.00') || ' al costo',
         sum(c.qty * coalesce(c.costo, 0))
    from public._penda_act_cuadre c
   group by c.desde, c.hacia
),
p5 as (
  select 5, 'P5 cambios más grandes', x.dato, x.valor, x.peso from (
    select almacen || ' · ' || insumo as dato,
           concat_ws(' · ',
             'hoy ' || trim(to_char(stock_hoy, 'FM9999999999999990.00')),
             'contado ' || coalesce(trim(to_char(contado, 'FM9999999990.00')), 'NADIE'),
             'movido ' || trim(to_char(neto, 'FM9999999990.00')),
             'queda ' || trim(to_char(final_cuadrado, 'FM9999999990.00')) || ' ' || coalesce(unidad,''),
             to_char((final_cuadrado - stock_hoy) * costo, 'FM9,999,999,999,999.00') || ' al costo'
           ) as valor,
           abs((final_cuadrado - stock_hoy) * costo) as peso
      from p
     order by abs((final_cuadrado - stock_hoy) * costo) desc nulls last
     limit 15
  ) x
),
-- P6 · con COCINA APARTE, los productos de área COCINA descuentan del almacén
--      Cocina. Su insumo tiene que ESTAR en Cocina; si quedó en el Principal o
--      en el FoodShop, la caja lo marca «Agotado» (vende igual, en negativo)
--      hasta que se transfiera. Mismo criterio de área que
--      fn_resolve_area_warehouse: menu_item_print_areas, y si no tiene,
--      print_area_code.
cocina as (
  select w.id as wid, w.production_area_id as pa
    from public.warehouses w, biz
   where w.business_id = biz.id and w.name = 'Cocina'
),
prod_cocina as (
  select m.id, m.inventory_item_id
    from public.menu_items m, biz, cocina c
   where m.business_id = biz.id and coalesce(m.is_active, true)
     and c.pa in (
       select mipa.print_area_id from public.menu_item_print_areas mipa
        where mipa.menu_item_id = m.id
       union all
       select pa2.id from public.print_areas pa2
        where pa2.business_id = m.business_id and pa2.code = m.print_area_code
          and m.print_area_code is not null
          and not exists (select 1 from public.menu_item_print_areas x
                           where x.menu_item_id = m.id))
),
insumo_cocina as (
  select pc.inventory_item_id as item_id, 'vínculo directo' as via
    from prod_cocina pc
   where pc.inventory_item_id is not null
     and not exists (select 1 from public.recipes r where r.menu_item_id = pc.id)
  union
  select ri.inventory_item_id, 'ingrediente de receta'
    from prod_cocina pc
    join public.recipes r on r.menu_item_id = pc.id
    join public.recipe_ingredients ri on ri.recipe_id = r.id
   where ri.inventory_item_id is not null
),
ic as (
  select x.item_id, string_agg(distinct x.via, ' + ') as via,
         max(i.name) as insumo, max(coalesce(i.cost, 0)) as costo,
         coalesce((select sum(q.final_cuadrado) from p q
                    where q.item_id = x.item_id and q.almacen = 'Cocina'), 0) as en_cocina,
         coalesce((select sum(q.final_cuadrado) from p q
                    where q.item_id = x.item_id and q.almacen in ('Almacen Principal','FoodShop')), 0) as fuera
    from insumo_cocina x
    join public.inventory_items i on i.id = x.item_id
   group by x.item_id
),
p6 as (
  select 6, 'P6 Cocina aparte', x.dato, x.valor, x.peso from (
    select 'resumen' as dato,
           count(*) || ' insumos que gasta el área COCINA · '
           || count(*) filter (where en_cocina > 0) || ' con existencia en Cocina · '
           || count(*) filter (where en_cocina <= 0 and fuera > 0)
           || ' SOLO fuera de Cocina (transferir: '
           || coalesce(to_char(sum(fuera * costo) filter (where en_cocina <= 0 and fuera > 0),
                               'FM999,999,999.00'), '0') || ' al costo) · '
           || count(*) filter (where en_cocina <= 0 and fuera <= 0) || ' sin existencia en ningún lado'
             as valor,
           1e18::numeric as peso
      from ic
    union all
    select * from (
      select 'transferir · ' || insumo,
             via || ' · Cocina ' || regexp_replace(round(en_cocina, 2)::text, '\.?0+$', '')
             || ' · Principal+FoodShop ' || regexp_replace(round(fuera, 2)::text, '\.?0+$', '')
             || ' · ' || to_char(fuera * costo, 'FM999,999,999.00') || ' al costo',
             fuera * costo
        from ic
       where en_cocina <= 0 and fuera > 0
       order by fuera * costo desc
       limit 15
    ) t
  ) x
),

-- P7 · los conteos más caros: si el número se contó en otra unidad que la del
--      insumo (onzas contra galones, sobres contra cajas), aquí se nota.
p7 as (
  select 7, 'P7 revisar unidad (conteos más caros)', x.dato, x.valor, x.peso from (
    select almacen || ' · ' || insumo as dato,
           'contado ' || regexp_replace(round(contado, 2)::text, '\.?0+$', '') || ' ' || coalesce(unidad, '')
           || ' × costo ' || trim(to_char(costo, 'FM9999999990.00'))
           || ' = ' || to_char(contado * costo, 'FM999,999,999.00') as valor,
           contado * costo as peso
      from p
     where contado is not null
     order by contado * costo desc
     limit 15
  ) x
)

select seccion, dato, valor from (
  select * from p1 union all select * from p2 union all select * from p3
  union all select * from p4 union all select * from p5 union all select * from p6
  union all select * from p7
) todo
order by orden, peso desc, dato;

-- =============================================================================
-- LA PENDA EXPRESS · ÁREAS — PASO A2: PREPARAR el cambio de área
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- NO CAMBIA NINGÚN PRODUCTO. Arma `_penda_area_plan` (qué producto pasa a
-- qué área y por qué) y muestra el resumen. El PASO A3 aplica esa tabla.
--
-- POR QUÉ: con el inventario por área, el área del producto decide de qué
-- almacén descuenta (COCINA → Cocina, BAR → Bar, lo demás → FoodShop) y en
-- qué impresora sale su comanda (FoodShop → impresora CAJA).
--
-- DECISIONES DEL DUEÑO (12-oct):
--   · Al área FoodShop: la TIENDA, las CERVEZAS, las BOTELLAS CERRADAS
--     (whisky, ron, tequila, ginebra, vodka, vino) y los productos SIN ÁREA
--     de tienda y sin categoría (hoy no imprimen; empiezan a imprimir en CAJA).
--   · En el área BAR se queda lo que el BAR PREPARA (su comanda tiene que
--     seguir saliendo en la impresora del bar).
--
-- LAS REGLAS, en orden (gana la primera que aplica). Las categorías de Penda
-- están revueltas (galletas en TEQUILA, Suerox en FRAPPE), por eso no se
-- decide solo por categoría:
--   «reventa» = se vende tal cual: tiene vínculo directo con su insumo, o
--               tiene código de barras (EAN de 8 a 14 dígitos en el producto
--               o en el insumo; los SKU internos tipo 00000514 no cuentan).
--   1  TIENDA en BAR / Caja / sin área                         → FoodShop
--   2  TIENDA con área COCINA (salvo TABLAS y MANTEQUILLA)      → FoodShop
--   3  CERVEZAS en BAR / Caja / sin área                        → FoodShop
--   4  BAR/Caja · el nombre dice TRAGO, COPA o SHOT              se queda
--   5  BAR/Caja · tiene receta (se prepara)                      se queda
--   6  BAR/Caja · bebida preparada sin código de barras:         se queda
--      categoría de cócteles, tragos, café, jugos/frozen, frappé, o el
--      nombre dice JUGO, LIMONADA, FROZEN, COLADA, MOJITO, SANGRIA,
--      LICUADO, BATIDO, CAFE, CAPUCCINO, LATTE, EXPRESO, MOCHA…
--   7  BAR/Caja · reventa (botellas, snacks, postres empacados) → FoodShop
--   8  BAR/Caja · lo demás (el bar no lo prepara: flanes, tres
--      leches, pan, agua; no descuentan, solo cambia la impresora) → FoodShop
--   9  sin área · sin categoría o BEBIDAS                       → FoodShop
--   10 sin área · DESAYUNO, PA' COMER, GUARNICIONES, CROISSANTS → COCINA
--      (son platos: sin área, sus recetas descontarían del FoodShop)
--   11 COCINA · ZYN, KIDS POWER CRUNCH, DUETTO, PALETA          → FoodShop
--      (snacks de tienda con área equivocada; los quipes, tablas y
--      bruschettas tienen código porque se compran hechos, pero son de
--      cocina: por eso esta regla va por NOMBRE y no por código)
--   Un producto con DOS áreas o más no se toca (lo dice el resumen).
-- =============================================================================

do $$
declare
  v_biz  uuid := '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';
  v_fs   uuid;
  v_coc  uuid;
  v_n    int;
begin
  select id into v_fs  from public.print_areas
   where business_id = v_biz and upper(name) = 'FOODSHOP' limit 1;
  select id into v_coc from public.print_areas
   where business_id = v_biz and upper(name) = 'COCINA' limit 1;
  if v_fs is null or v_coc is null then
    raise exception 'Faltan las áreas FoodShop o COCINA. No se armó nada.';
  end if;

  if to_regclass('public._penda_area_plan') is not null then
    select count(*) into v_n from public._penda_area_plan where aplicado_en is not null;
    if v_n > 0 then
      raise exception 'El cambio de área YA se aplicó (% productos). Para volver atrás '
                      'está el DESHACER del PASO A3.', v_n;
    end if;
    drop table public._penda_area_plan;
  end if;

  create table public._penda_area_plan (
    menu_item_id  uuid primary key,
    producto      text,
    categoria     text,
    area_hoy      text,
    n_areas       int,
    regla         int,
    motivo        text,
    area_nueva_id uuid,           -- null = se queda como está
    area_nueva    text,
    vendidos_30d  numeric,
    creado_en     timestamptz not null default now(),
    aplicado_en   timestamptz
  );

  insert into public._penda_area_plan
    (menu_item_id, producto, categoria, area_hoy, n_areas, regla, motivo,
     area_nueva_id, area_nueva, vendidos_30d)
  with
  prod as (
    select m.id, m.name, upper(trim(coalesce(c.name, ''))) as cat,
           c.id is null as sin_cat,
           -- área según la misma regla que la caja: N:M manda, si no el código
           coalesce(
             (select string_agg(pa.name, ' + ' order by pa.name)
                from public.menu_item_print_areas x
                join public.print_areas pa on pa.id = x.print_area_id
               where x.menu_item_id = m.id),
             (select pa.name from public.print_areas pa
               where pa.business_id = m.business_id and pa.code = m.print_area_code
               limit 1),
             '(sin área)') as area,
           coalesce(
             nullif((select count(*) from public.menu_item_print_areas x
                      where x.menu_item_id = m.id), 0),
             case when m.print_area_code is not null then 1 else 0 end) as n_areas,
           exists (select 1 from public.recipes r where r.menu_item_id = m.id) as receta,
           m.inventory_item_id is not null as vinculo,
           (   coalesce(m.barcode, '') ~ '^[0-9]{8,14}$'
            or (coalesce(i.sku, '') ~ '^[0-9]{8,14}$' and i.sku !~ '^000')
            or coalesce(to_jsonb(i)->>'barcode', '') ~ '^[0-9]{8,14}$') as codigo
      from public.menu_items m
      left join public.categories c on c.id = m.category_id
      left join public.inventory_items i on i.id = m.inventory_item_id
     where m.business_id = v_biz and coalesce(m.is_active, true)
  ),
  ventas as (
    select oi.product_id, sum(coalesce(oi.qty, oi.quantity::numeric, 0)) as un
      from public.order_items oi
     where oi.created_at >= now() - interval '30 days'
       and oi.status <> 'void'
       and oi.product_id in (select id from prod)
     group by oi.product_id
  ),
  clasif as (
    select p.*,
           upper(p.area) in ('BAR','CAJA')       as en_bar,
           p.area = '(sin área)'                 as sin_area,
           upper(p.area) = 'COCINA'              as en_cocina,
           (p.cat in ('COCTELES','TRAGOS','CAFE','FRAPPE') or p.cat like 'JUGOS%') as cat_preparada,
           (p.vinculo and not p.receta) or p.codigo as reventa,
           upper(p.name) ~ '\m(TRAGO|TRAGOS|COPA|SHOT|SHOTS)\M' as nombre_trago,
           upper(p.name) ~ ('\m(JUGO|JUGOS|LIMONADA|FROZEN|COLADA|MOJITO|SANGRIA|LICUADO|'
                            'BATIDO|BATIDA|CAFE|CAFÉ|CAPUCCINO|CAPPUCCINO|LATTE|EXPRESO|'
                            'ESPRESSO|MOCHA|MOCACCINO|MACCHIATO|FRAPPE)\M'
                            '|CHOCOLATE CALIENTE') as nombre_preparado
      from prod p
  ),
  regla as (
    select c.*,
      case
        when c.n_areas > 1                                                  then 0
        when (c.en_bar or c.sin_area) and c.cat = 'TIENDA'                  then 1
        when c.en_cocina and c.cat = 'TIENDA'
             and upper(c.name) !~ '^(TABLA|MANTEQUILLA)'                    then 2
        when (c.en_bar or c.sin_area) and c.cat = 'CERVEZAS'                then 3
        when c.en_bar and c.nombre_trago                                    then 4
        when c.en_bar and c.receta                                          then 5
        when c.en_bar and (c.cat_preparada or c.nombre_preparado)
             and not c.codigo                                               then 6
        when c.en_bar and c.reventa                                         then 7
        when c.en_bar                                                       then 8
        when c.sin_area and (c.sin_cat or c.cat = 'BEBIDAS')                then 9
        when c.sin_area and c.cat in ('DESAYUNO','PA'' COMER','GUARNICIONES','CROISSANTS') then 10
        when c.en_cocina
             and upper(c.name) ~ '^(ZYN|KIDS POWER CRUNCH|DUETTO|PALETA)'   then 11
        else -1
      end as r
      from clasif c
  )
  select r.id, r.name, case when r.sin_cat then '(sin categoría)' else r.cat end,
         r.area, r.n_areas, r.r,
         case r.r
           when 0  then 'tiene varias áreas: no se toca'
           when 1  then 'tienda'
           when 2  then 'tienda con área cocina'
           when 3  then 'cervezas'
           when 4  then 'trago/copa/shot: se queda en el bar'
           when 5  then 'tiene receta: se prepara en el bar'
           when 6  then 'bebida preparada: se queda en el bar'
           when 7  then 'reventa (botella, snack, empacado)'
           when 8  then 'el bar no lo prepara (postres, pan, agua)'
           when 9  then 'sin área (sin categoría / bebidas)'
           when 10 then 'plato sin área → cocina'
           when 11 then 'snack de tienda con área cocina'
           else 'no cambia'
         end,
         case when r.r in (1,2,3,7,8,9,11) then v_fs
              when r.r = 10 then v_coc end,
         case when r.r in (1,2,3,7,8,9,11) then 'FoodShop'
              when r.r = 10 then 'COCINA' end,
         coalesce(v.un, 0)
    from regla r
    left join ventas v on v.product_id = r.id;

  select count(*) into v_n from public._penda_area_plan where area_nueva_id is not null;
  raise notice 'Plan de áreas armado: % productos cambian de área. Revisar el resumen.', v_n;
end
$$;


-- ═══ RESUMEN (una sola consulta) ════════════════════════════════════════════
select regla,
       motivo,
       area_hoy || ' → ' || coalesce(area_nueva, '(igual)')           as cambio,
       count(*)                                                       as productos,
       sum(vendidos_30d)::int                                         as vendidos_30d,
       left(string_agg(producto, ' · ' order by vendidos_30d desc, producto), 180) as ejemplos
  from public._penda_area_plan
 where regla <> -1
 group by regla, motivo, area_hoy, area_nueva
 order by regla, count(*) desc;


-- ═══ DETALLE — correr aparte para revisar uno por uno ═══════════════════════
--   Los que se QUEDAN en el bar y los que salen de COCINA: ahí están los
--   casos dudosos. Exportar a CSV desde Studio si hace falta.
/*
select regla, motivo, categoria, area_hoy, coalesce(area_nueva, '(igual)') as area_nueva,
       producto, vendidos_30d
  from public._penda_area_plan
 where regla in (0, 2, 4, 5, 6, 7, 8, 10, 11)
 order by regla, categoria, vendidos_30d desc, producto;
*/

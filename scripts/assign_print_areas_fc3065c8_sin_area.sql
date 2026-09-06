-- =============================================================================
-- Asignar área de producción a los productos QUE NO TIENEN
-- Business fc3065c8-cb40-45ad-bec1-aecb388001c1
--
-- ALCANCE: SOLO los productos sin área. Un producto ya ruteado (fila en
--   menu_item_print_areas hacia un área activa, o print_area_code que apunta
--   a un área activa del negocio) NO se toca. Al 2026-09-05 eran 326 de 711.
--
-- POR QUÉ HACE FALTA:
--   Sin área, "Enviar a cocina" se bloquea y NO sale ninguna comanda — falla
--   callado hasta que alguien intenta imprimir.
--
-- POR QUÉ POR CATEGORÍA Y NO POR SKU:
--   El script hermano (seed_business_fc3065c8_print_areas.sql) rutea por sku
--   y de sus ~640 filas solo empataron 385: el catálogo se reimportó con
--   otros skus. La categoría sí sobrevivió, así que es la llave estable.
--   Las 6 categorías que mezclan comida y bebida van producto por producto.
--
-- ESCRIBE LOS DOS MECANISMOS, A PROPÓSITO:
--   1. menu_item_print_areas (N:M) — fuente de verdad, permite 2 áreas.
--   2. menu_items.print_area_code (legacy) — NO es redundante:
--      fn_add_item_from_menu lo copia al order_item, y el lookup N:M se
--      salta entero sin red. Solo con N:M, un bache de red rutea mal.
--      En los combos de 2 áreas el legacy guarda la cocina (el plato).
--
-- ABORTA si algún producto sin área no queda cubierto por el reparto, y te
-- dice cuál. CONVERGENTE: re-ejecutarlo deja el mismo estado.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1) Codes de las áreas del negocio (verificados 2026-09-05)
-- ---------------------------------------------------------------------------
create temp table _area_cfg (rol text primary key, code text) on commit drop;
insert into _area_cfg (rol, code) values
  ('K', 'cocina'),   -- COCINA  -> impresora COCINA
  ('B', 'bar');      -- BAR     -> impresora COMANDAS

do $$
declare
  v_business uuid := 'fc3065c8-cb40-45ad-bec1-aecb388001c1';
  v_missing  text;
  v_have     text;
begin
  select string_agg(cfg.code, ', ') into v_missing
  from _area_cfg cfg
  where not exists (
    select 1 from public.print_areas a
    where a.business_id = v_business and a.code = cfg.code
      and coalesce(a.is_active, true)
  );
  if v_missing is not null then
    select string_agg(a.code || ' (' || a.name || ')', ', ' order by a.code)
      into v_have
    from public.print_areas a
    where a.business_id = v_business and coalesce(a.is_active, true);
    raise exception 'No existen estas áreas: %. El negocio tiene: %',
      v_missing, coalesce(v_have, '(ninguna)');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2) Universo: SOLO los productos sin área
--    (mismo predicado del diagnóstico — es el candado de este script)
-- ---------------------------------------------------------------------------
create temp table _sin_area on commit drop as
select m.id, m.name, m.category_id
from public.menu_items m
where m.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'::uuid
  and not exists (
    select 1 from public.menu_item_print_areas p
    join public.print_areas a on a.id = p.print_area_id
    where p.menu_item_id = m.id and coalesce(a.is_active, true)
  )
  and not exists (
    select 1 from public.print_areas a
    where a.business_id = m.business_id
      and a.code = m.print_area_code
      and coalesce(a.is_active, true)
  );

create index on _sin_area (category_id);

-- ---------------------------------------------------------------------------
-- 3) Reparto por CATEGORÍA (categorías 100% cocina o 100% bar)
-- ---------------------------------------------------------------------------
create temp table _cat_route (categoria text primary key, areas text) on commit drop;
insert into _cat_route (categoria, areas) values
  -- ---- COCINA (89 productos) ----
  ('PLATO FUERTE',              'K'),
  ('MOD. PLATOS',               'K'),
  ('ENTRADAS',                  'K'),
  ('DIA DE LA MADRES',          'K'),
  ('POSTRES',                   'K'),
  ('MENU DIAS DE LAS  MADRES',  'K'),   -- ojo: doble espacio, es el nombre real
  ('GUARNICIONES (SV)',         'K'),
  ('GUARNICIONES',              'K'),
  ('FUERTES ESPECIALES (SV)',   'K'),
  ('MENU NIÑO',                 'K'),
  ('BRUNCH',                    'K'),
  ('CORTES DE CARNE (SV)',      'K'),   -- incluye CREMA DULCE AMOR (postre mal categorizado)
  ('ENTRADAS (SV)',             'K'),
  ('POSTRES (SV)',              'K'),
  ('ALMUERZO SEMANAL',          'K'),
  ('SABADOS BOHEMIOS',          'K'),
  ('ENSALADAS',                 'K'),
  -- ---- BAR (217 productos) ----
  ('BEBIDAS S/A',               'B'),
  ('RONES (BOT)',               'B'),   -- incluye DESCORCHE (decisión del dueño)
  ('COCTELES',                  'B'),
  ('CERVEZAS',                  'B'),
  ('VINOS TINTOS (BOT)',        'B'),
  ('DIGESTIVOS (BOT)',          'B'),
  ('WHISKY (BOT)',              'B'),
  ('VINOS BLANCOS (BOT)',       'B'),
  ('TEQUILA (BOT)',             'B'),
  ('WHISKY (TRA)',              'B'),
  ('LICORES (TRAGO)',           'B'),
  ('VINOS (COPA)',              'B'),
  ('GINEBRA BOT',               'B'),
  ('TEQUILA (TRA)',             'B'),
  ('MOD. BEBIDAS',              'B'),
  ('ESPECIAL DE BEBIDAS (SV)',  'B'),
  ('COGNA',                     'B'),
  ('VODKA TRA',                 'B'),
  ('VODKA BOT',                 'B'),
  ('DIGESTIVOS (TRA)',          'B'),
  ('VINOS (BOT X COPA)',        'B'),
  ('CHAMPANE',                  'B'),
  ('GINEBRA (TRA)',             'B'),
  ('ESPUMANTES',                'B'),
  ('OFERTAS HH VIERNES',        'B'),
  ('VINOS ROSADOS (BOT)',       'B'),
  ('RONES (TRA)',               'B'),
  ('BITTERS',                   'B'),
  ('CIGARRILLOS',               'B');

-- ---------------------------------------------------------------------------
-- 4) Reparto por PRODUCTO — las 6 categorías que mezclan comida y bebida.
--    Estas categorías NO están arriba a propósito: si el nombre cambiara,
--    el guard del paso 5 aborta en vez de rutear mal por default.
--    'KB' = las dos áreas (combo comida + bebida, salen 2 comandas).
-- ---------------------------------------------------------------------------
create temp table _name_route (producto text primary key, areas text) on commit drop;
insert into _name_route (producto, areas) values
  -- EXTRAS (9)
  ('AGUACATE EXTRA',                    'K'),
  ('ENSALADA EXTRA',                    'K'),
  ('EXTRA CHICHARRON',                  'K'),
  ('HUEVO EXTRA',                       'K'),
  ('PAN SERVICIO EXTRA',                'K'),
  ('QUESO PARMESANO EXTRA',             'K'),
  ('SALSA EXTRA',                       'K'),
  ('EXTRA GINEBRA CASA',                'B'),
  ('ZUMO DE LIMON EXTRA',               'B'),
  -- MARTES TACOS TUESDAY (3)
  ('TACOS UNIDAD',                      'K'),
  ('2X1 ECOMARGARITAS',                 'B'),
  ('CORO TACOS + HENIKEN',              'KB'),
  -- JUEVES DE ENCENDIDA (2)
  ('2X1 DUMPLINGS 3 UNIDADES',          'K'),
  ('2X1 VODKA CINNAMON',                'B'),
  -- MIERCOLES DE ANTOJO (2)
  ('2X1 EN TRIO DE MINI BURGUERS',      'K'),
  ('2X1 MOSCOW MULE (MIERCOLES DE ANTOJO)', 'B'),
  -- LUNES UNIVERSITARIOS (2)
  ('2X1 CALAMARES A LA ROMANA',         'K'),
  ('2X1 COSTA AZUL (LUNES UNIVERSITARIOS)', 'B'),
  -- OFERTAS HXH (2)
  ('ECO MARGARITA 2X1',                 'B'),
  ('EL CORO TACOS + CORONA TUESDAY',    'KB');

-- ---------------------------------------------------------------------------
-- 5) Resolución: el nombre manda sobre la categoría
-- ---------------------------------------------------------------------------
create temp table _resuelto on commit drop as
select
  s.id       as menu_item_id,
  s.name     as producto,
  coalesce(nr.areas, cr.areas) as areas
from _sin_area s
left join _name_route nr on nr.producto = s.name
left join public.categories c
       on c.id = s.category_id
      and c.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'::uuid
left join _cat_route cr on cr.categoria = c.name;

-- Guard: nadie se queda sin ruta. Si el catálogo cambió (categoría renombrada,
-- producto nuevo), aborta y dice cuáles — mejor eso que rutear a ciegas.
do $$
declare v_huerfanos text; v_n int;
begin
  select count(*), string_agg(producto, ' | ' order by producto)
    into v_n, v_huerfanos
  from _resuelto where areas is null;
  if v_n > 0 then
    raise exception 'ABORTADO: % producto(s) sin área no están en el reparto: %',
      v_n, v_huerfanos;
  end if;
end $$;

-- Una fila por (producto, área) ya en UUIDs. Un 'KB' produce dos.
create temp table _target on commit drop as
select r.menu_item_id, a.id as print_area_id
from _resuelto r
join _area_cfg cfg on r.areas like '%' || cfg.rol || '%'
join lateral (
  select a2.id from public.print_areas a2
  where a2.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'::uuid
    and a2.code = cfg.code and coalesce(a2.is_active, true)
  order by a2.created_at asc limit 1
) a on true;

-- ---------------------------------------------------------------------------
-- 6) N:M — solo inserta. No borra nada: por construcción estos productos no
--    tienen filas hacia un área activa.
-- ---------------------------------------------------------------------------
insert into public.menu_item_print_areas (menu_item_id, print_area_id)
select t.menu_item_id, t.print_area_id from _target t
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- 7) Legacy print_area_code (en los combos KB gana la cocina, que es el plato)
--    is_beverage = true solo para los que van SOLO a barra.
-- ---------------------------------------------------------------------------
update public.menu_items mi
set print_area_code = cfg.code,
    is_beverage     = (r.areas = 'B'),
    updated_at      = now()
from _resuelto r
join _area_cfg cfg
  on cfg.rol = case when r.areas like '%K%' then 'K' else 'B' end
where mi.id = r.menu_item_id;

-- ---------------------------------------------------------------------------
-- 8) Control. Esperado:
--      tocados = 326 | a_cocina = 100 | a_bar = 224 | a_ambas = 2
--      restantes_sin_area = 0  <- de TODO el negocio
--      code_inexistente   = 0
-- ---------------------------------------------------------------------------
select
  (select count(*) from _resuelto)                            as tocados,
  (select count(*) from _resuelto where areas = 'K')          as a_cocina,
  (select count(*) from _resuelto where areas = 'B')          as a_bar,
  (select count(*) from _resuelto where areas = 'KB')         as a_ambas,
  (select count(*) from public.menu_items m
    where m.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'::uuid
      and not exists (select 1 from public.menu_item_print_areas p
                      join public.print_areas a on a.id = p.print_area_id
                      where p.menu_item_id = m.id and coalesce(a.is_active, true))
      and not exists (select 1 from public.print_areas a
                      where a.business_id = m.business_id and a.code = m.print_area_code
                        and coalesce(a.is_active, true))
   ) as restantes_sin_area,
  (select count(*) from public.menu_items m
    where m.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'::uuid
      and m.print_area_code is not null
      and not exists (select 1 from public.print_areas a
                      where a.business_id = m.business_id and a.code = m.print_area_code)
   ) as code_inexistente;

commit;

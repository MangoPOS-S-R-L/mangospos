-- =============================================================================
-- IMPORT — Cotizacion Vocatus S44868 (16/09/2026)
-- Negocio: 6d13ed3f-0fb9-40e3-a695-f4c09759fbfd
--
--   19 productos, 10 categorias.
--   COSTO  = el precio de la cotizacion, tal cual.
--   PRECIO = costo x 2.
--
-- CRITERIOS (si alguno no te cuadra, avisa antes de correrlo):
--
--   1. tax_mode = 'exclusive' — el ITBIS se suma por encima del precio.
--      El cliente paga 2 x costo x 1.18. Si quieres que el precio de gondola
--      sea el precio final, corre despues el UPDATE del pie de este archivo.
--
--   2. "Agua Cascada Vocatus 500Ml" entra EXENTA (sin vinculo a ITBIS).
--      No es un invento: la propia cotizacion la excluye. Total 10,560,450.00,
--      subtotal 8,953,652.55, ITBIS 1,606,797.45 -> la unica base exenta que
--      cuadra esa resta es 27,000.00, que es exactamente esa linea.
--      Sin fila en menu_item_taxes el producto vende con ITBIS 0.
--
--   3. Categorias: se les quita el sufijo " PRIORITY" (es la clasificacion
--      interna del suplidor, no del negocio):
--        RONES PRIORITY -> RONES, TEQUILAS PRIORITY -> TEQUILAS,
--        WHISKY PRIORITY -> WHISKY, SODAS Y/O TONICAS -> SODAS Y TONICAS.
--      Si ya existe la categoria (comparando sin tildes ni mayusculas) se
--      REUSA la que hay; no se crean duplicadas.
--
--   4. Dos nombres corregidos del origen:
--        "Old Parr 12 Anos 750Ml"   -> "Old Parr 12 Años 750Ml"
--        "Agua De Coco Goya 350 ml." -> "Agua De Coco Goya 350Ml"
--
--   5. NO toca inventario (is_inventory_tracked se queda como viene por
--      defecto). Si esto es una licorera y quieres descontar existencias,
--      eso es un paso aparte.
--
-- ANTI-DUPLICADOS: solo inserta un nombre que NO exista ya en el catalogo.
-- Si un producto ya existe, por defecto NO se toca y sale listado al final.
-- Para que ademas le grabe costo y precio, cambia el false de abajo por true.
--
-- Correr en Supabase Studio -> SQL Editor. Devuelve UN resultado.
-- Todo va en una transaccion: si algo falla, no queda nada a medias.
-- =============================================================================

begin;

-- 0) Interruptor --------------------------------------------------------------
create temp table _cfg on commit drop as
select false as actualizar_existentes,   -- <- ponlo en true para pisar costo/precio de los que ya existen
       'exclusive'::text as tax_mode;

-- 1) Guardas ------------------------------------------------------------------
do $$
declare v_have text;
begin
  if not exists (select 1 from public.businesses where id = '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd') then
    raise exception 'ABORTA: el negocio 6d13ed3f-0fb9-40e3-a695-f4c09759fbfd no existe';
  end if;

  if not exists (
    select 1 from public.taxes t
    where t.business_id = '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'
      and coalesce(t.is_active, true)
      and (t.name ilike '%itbis%' or t.rate = 18)
  ) then
    select coalesce(string_agg(t.name || ' ' || t.rate || '%', ', '), '(ninguno)') into v_have
      from public.taxes t where t.business_id = '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd';
    raise exception 'ABORTA: el negocio no tiene ITBIS activo. Tiene: %. Crealo en Ajustes -> Impuestos y vuelve a correr.', v_have;
  end if;
end $$;

-- 2) La cotizacion ------------------------------------------------------------
create temp table _f on commit drop as
select v.name, v.cat, v.cost::numeric(12,2) as cost,
       round(v.cost::numeric * 2, 2)::numeric(12,2) as price,
       v.exento, v.pos,
       upper(btrim(regexp_replace(translate(v.name, 'ÁÉÍÓÚÜÑÀÈÌÒÙÂÊÎÔÛáéíóúüñàèìòùâêîôû', 'AEIOUUNAEIOUAEIOUaeiouunaeiouaeiou'), '\s+', ' ', 'g'))) as k,
       upper(btrim(regexp_replace(translate(v.cat,  'ÁÉÍÓÚÜÑÀÈÌÒÙÂÊÎÔÛáéíóúüñàèìòùâêîôû', 'AEIOUUNAEIOUAEIOUaeiouunaeiouaeiou'), '\s+', ' ', 'g'))) as ck
from (values
  --  nombre                              categoria          costo      exento  pos
  ('Agua Cascada Vocatus 500Ml',        'AGUAS',              15.00,    true,   1),
  ('Evian Sparkling 330Ml',             'AGUAS',             175.00,    false,  2),
  ('Moet & Chandon Ice Imperial 750Ml', 'CHAMPAGNE',        5525.00,    false,  3),
  ('Red Bull 250Ml',                    'ENERGIZANTES',      100.00,    false,  4),
  ('Jugo Motts 32Oz',                   'JUGOS',             225.00,    false,  5),
  ('Agua De Coco Goya 350Ml',           'PROVISIONES',       125.00,    false,  6),
  ('Coca Cola 400Ml',                   'REFRESCOS',          30.00,    false,  7),
  ('Sprite 400Ml',                      'REFRESCOS',          25.00,    false,  8),
  ('Barcelo Imperial 750Ml',            'RONES',            1225.00,    false,  9),
  ('Barcelo Now 750Ml',                 'RONES',             770.00,    false, 10),
  ('Soda Amarga Canada Dry 400Ml',      'SODAS Y TONICAS',    40.00,    false, 11),
  ('Don Julio 1942 750Ml',              'TEQUILAS',        14095.00,    false, 12),
  ('Don Julio Reposado 750Ml',          'TEQUILAS',         4650.00,    false, 13),
  ('Johnnie Blue Label 750Ml',          'WHISKY',          19895.00,    false, 14),
  ('Johnnie Gold Label Reserva 750Ml',  'WHISKY',           3295.00,    false, 15),
  ('Johnnie Negro 750Ml',               'WHISKY',           2195.00,    false, 16),
  ('Johnnie Walker 18 750Ml',           'WHISKY',           5995.00,    false, 17),
  ('Old Parr 12 Años 750Ml',            'WHISKY',           1795.00,    false, 18),
  ('Old Parr 18 Años 750Ml',            'WHISKY',           4650.00,    false, 19)
) as v(name, cat, cost, exento, pos);

do $$
declare n int;
begin
  select count(*) into n from _f;
  if n <> 19 then raise exception 'ABORTA: la cotizacion trae 19 lineas y aqui hay %', n; end if;
  select count(*) into n from (select k from _f group by k having count(*) > 1) d;
  if n > 0 then raise exception 'ABORTA: % nombres repetidos dentro de la propia cotizacion', n; end if;
end $$;

-- 3) Catalogo actual ----------------------------------------------------------
create temp table _c on commit drop as
select mi.id, mi.name,
       upper(btrim(regexp_replace(translate(mi.name, 'ÁÉÍÓÚÜÑÀÈÌÒÙÂÊÎÔÛáéíóúüñàèìòùâêîôû', 'AEIOUUNAEIOUAEIOUaeiouunaeiouaeiou'), '\s+', ' ', 'g'))) as k
from public.menu_items mi
where mi.business_id = '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd';
create index on _c (k);

-- 4) Categorias: reusa las que hay, crea las que faltan ------------------------
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd', c.name,
       (select coalesce(max(x.position), 0) from public.categories x
         where x.business_id = '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd') + c.pos,
       true
from (select cat as name, ck, min(pos) as pos from _f group by cat, ck) c
where not exists (
  select 1 from public.categories x
  where x.business_id = '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'
    and upper(btrim(regexp_replace(translate(x.name, 'ÁÉÍÓÚÜÑÀÈÌÒÙÂÊÎÔÛáéíóúüñàèìòùâêîôû', 'AEIOUUNAEIOUAEIOUaeiouunaeiouaeiou'), '\s+', ' ', 'g'))) = c.ck
);

create temp table _catid on commit drop as
select c.ck, (
  select x.id from public.categories x
  where x.business_id = '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'
    and upper(btrim(regexp_replace(translate(x.name, 'ÁÉÍÓÚÜÑÀÈÌÒÙÂÊÎÔÛáéíóúüñàèìòùâêîôû', 'AEIOUUNAEIOUAEIOUaeiouunaeiouaeiou'), '\s+', ' ', 'g'))) = c.ck
  order by x.created_at asc limit 1
) as id
from (select distinct ck from _f) c;

do $$
declare n int;
begin
  select count(*) into n from _catid where id is null;
  if n > 0 then raise exception 'ABORTA: % categorias no se pudieron resolver', n; end if;
end $$;

-- 5) INSERTA los nuevos --------------------------------------------------------
insert into public.menu_items
  (business_id, category_id, name, price, cost, tax_mode, is_active, is_beverage, position)
select '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd', ci.id, f.name, f.price, f.cost,
       (select tax_mode from _cfg), true, true, f.pos
from _f f
join _catid ci on ci.ck = f.ck
where not exists (select 1 from _c x where x.k = f.k);

-- 6) Los que YA existian: solo si prendiste el interruptor ---------------------
update public.menu_items mi
set cost       = f.cost,
    price      = f.price,
    is_active  = true,
    updated_at = now()
from _f f, _c x, _cfg cfg
where x.k = f.k and mi.id = x.id and cfg.actualizar_existentes;

-- 7) Impuestos: ITBIS a las 18 gravadas ----------------------------------------
--    La exenta queda sin vinculo a proposito (menu_item_taxes es la UNICA
--    fuente del impuesto: sin fila, vende con ITBIS 0).
insert into public.menu_item_taxes (item_id, tax_id)
select mi.id, tt.id
from public.menu_items mi
join _f f on f.k = upper(btrim(regexp_replace(translate(mi.name, 'ÁÉÍÓÚÜÑÀÈÌÒÙÂÊÎÔÛáéíóúüñàèìòùâêîôû', 'AEIOUUNAEIOUAEIOUaeiouunaeiouaeiou'), '\s+', ' ', 'g')))
join lateral (
  select t.id from public.taxes t
  where t.business_id = mi.business_id
    and coalesce(t.is_active, true)
    and (t.name ilike '%itbis%' or t.rate = 18)
  order by (t.name ilike '%itbis%') desc, t.created_at asc limit 1
) tt on true
where mi.business_id = '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'
  and not f.exento
  and not exists (select 1 from public.menu_item_taxes z where z.item_id = mi.id and z.tax_id = tt.id);

-- 8) Menu (si el negocio tiene uno activo) -------------------------------------
insert into public.menu_item_links (menu_id, item_id, position)
select m.id, mi.id, f.pos
from public.menu_items mi
join _f f on f.k = upper(btrim(regexp_replace(translate(mi.name, 'ÁÉÍÓÚÜÑÀÈÌÒÙÂÊÎÔÛáéíóúüñàèìòùâêîôû', 'AEIOUUNAEIOUAEIOUaeiouunaeiouaeiou'), '\s+', ' ', 'g')))
join lateral (
  select m2.id from public.menus m2
  where m2.business_id = mi.business_id and coalesce(m2.is_active, true)
  order by m2.created_at asc limit 1
) m on true
where mi.business_id = '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'
  and not exists (select 1 from public.menu_item_links l where l.item_id = mi.id and l.menu_id = m.id);

-- 9) CANDADOS FINALES ----------------------------------------------------------
do $$
declare n int; ejemplos text;
begin
  -- 9a) ninguna de las 18 gravadas puede quedar sin ITBIS
  select count(*), string_agg(mi.name, ' | ')
    into n, ejemplos
  from public.menu_items mi
  join _f f on f.k = upper(btrim(regexp_replace(translate(mi.name, 'ÁÉÍÓÚÜÑÀÈÌÒÙÂÊÎÔÛáéíóúüñàèìòùâêîôû', 'AEIOUUNAEIOUAEIOUaeiouunaeiouaeiou'), '\s+', ' ', 'g')))
  where mi.business_id = '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'
    and not f.exento
    and not exists (
      select 1 from public.menu_item_taxes z
      join public.taxes t on t.id = z.tax_id
      where z.item_id = mi.id and (t.name ilike '%itbis%' or t.rate = 18)
    );
  if n > 0 then
    raise exception 'ABORTA: % productos quedarian sin impuesto: %', n, left(coalesce(ejemplos,''), 300);
  end if;

  -- 9b) no puede quedar un nombre repetido en el negocio
  select count(*), string_agg(d.nombre, ' | ')
    into n, ejemplos
  from (
    select upper(btrim(regexp_replace(translate(mi.name, 'ÁÉÍÓÚÜÑÀÈÌÒÙÂÊÎÔÛáéíóúüñàèìòùâêîôû', 'AEIOUUNAEIOUAEIOUaeiouunaeiouaeiou'), '\s+', ' ', 'g'))) as nombre
    from public.menu_items mi
    where mi.business_id = '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'
    group by 1 having count(*) > 1
  ) d;
  if n > 0 then
    raise exception 'ABORTA: quedarian % nombres duplicados: %', n, left(coalesce(ejemplos,''), 300);
  end if;
end $$;

-- 10) Resultado ----------------------------------------------------------------
select 1 as orden, 'INSERTADOS' as que,
       (select count(*)::text from _f f where not exists (select 1 from _c x where x.k = f.k)) as cuantos,
       (select coalesce(string_agg(f.name, ' | ' order by f.pos), '—')
          from _f f where not exists (select 1 from _c x where x.k = f.k)) as detalle
union all
select 2, 'YA EXISTIAN',
       (select count(*)::text from _f f join _c x on x.k = f.k),
       (select coalesce(string_agg(x.name || case when (select actualizar_existentes from _cfg)
                                                  then ' (actualizado)' else ' (NO tocado)' end, ' | ' order by x.name), '—')
          from _f f join _c x on x.k = f.k)
union all
select 3, 'CON ITBIS',
       (select count(distinct mi.id)::text
          from public.menu_items mi
          join _f f on f.k = upper(btrim(regexp_replace(translate(mi.name, 'ÁÉÍÓÚÜÑÀÈÌÒÙÂÊÎÔÛáéíóúüñàèìòùâêîôû', 'AEIOUUNAEIOUAEIOUaeiouunaeiouaeiou'), '\s+', ' ', 'g')))
          join public.menu_item_taxes z on z.item_id = mi.id
         where mi.business_id = '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'),
       'debe decir 18 (la 19 es el agua exenta)'
union all
select 4, 'TOTAL CATALOGO',
       (select count(*)::text from public.menu_items where business_id = '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'),
       (select count(*)::text || ' categorias' from public.categories where business_id = '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd')
order by orden;

commit;

-- =============================================================================
-- OPCIONAL — precio de gondola = precio final (ITBIS por dentro).
-- Solo si NO quieres que la caja le sume 18% encima al precio cargado.
-- =============================================================================
-- update public.menu_items set tax_mode = 'inclusive', updated_at = now()
-- where business_id = '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'
--   and created_at >= now() - interval '1 hour';

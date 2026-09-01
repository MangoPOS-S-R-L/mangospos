-- =============================================================================
-- LA PENDA EXPRESS — activar "Inventariable" POR TANDAS
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- POR QUÉ NO SE LLAMA AL RPC: `fn_menu_item_set_inventory_tracked` exige
-- `auth.uid()` con rol owner/admin/manager. Desde el SQL Editor no hay uid,
-- así que revienta con INSUFFICIENT_ROLE. Estas sentencias hacen EXACTAMENTE
-- lo mismo que la versión viva de esa función (20260613_0002): buscar o crear
-- el insumo y enlazarlo DIRECTO en `menu_items.inventory_item_id`, sin
-- self-recipe y sin movimientos de stock.
--
-- ORDEN: 0 (respaldo) → A → B → revisar C → C.
-- CORRER UNA SENTENCIA A LA VEZ.
--
-- OJO: activar el flag hace que ese producto EMPIECE A DESCONTAR stock al
-- venderse. Como el conteo va a fijar la existencia real de todos modos, el
-- orden correcto es: activar → congelar → contar.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0. RESPALDO (correr una sola vez). Sin esto no hay marcha atrás fina.
-- ---------------------------------------------------------------------------
create table if not exists public.zz_backup_inventariable_20260901 (
  menu_item_id              uuid primary key,
  was_tracked               boolean,
  was_inventory_item_id     uuid,
  tanda                     text,
  created_inventory_item_id uuid,
  registrado_en             timestamptz default now()
);


-- ---------------------------------------------------------------------------
-- TANDA A — los 8 que YA están enlazados y solo tienen el flag apagado.
-- No crea ni enlaza nada: el insumo ya existe y ya entra al conteo.
-- ---------------------------------------------------------------------------
with objetivo as (
  select mi.id, mi.is_inventory_tracked, mi.inventory_item_id
  from public.menu_items mi
  where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(mi.is_active, true)
    and not mi.is_inventory_tracked
    and mi.inventory_item_id is not null
),
respaldo as (
  insert into public.zz_backup_inventariable_20260901
    (menu_item_id, was_tracked, was_inventory_item_id, tanda)
  select id, is_inventory_tracked, inventory_item_id, 'A' from objetivo
  on conflict (menu_item_id) do nothing
  returning menu_item_id
)
update public.menu_items mi
   set is_inventory_tracked = true
 where mi.id in (select id from objetivo);


-- ---------------------------------------------------------------------------
-- TANDA B — los 17 que REUSAN un insumo existente (mismo SKU o mismo nombre).
-- Enlaza + prende el flag. Tampoco crea fichas nuevas.
--
-- El emparejamiento es el mismo del RPC: SKU exacto primero, nombre exacto
-- normalizado después. NO se usa parecido: un enlace cruzado hace que vender
-- Doritos descuente Cheetos.
-- ---------------------------------------------------------------------------
with prod as (
  select mi.id, mi.name, mi.sku, mi.is_inventory_tracked, mi.inventory_item_id,
         lower(btrim(mi.name)) as nombre_norm,
         nullif(btrim(mi.sku), '') as sku_norm
  from public.menu_items mi
  where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(mi.is_active, true)
    and not mi.is_inventory_tracked
    and mi.inventory_item_id is null
),
ins as (
  select ii.id, ii.created_at,
         lower(btrim(ii.name)) as nombre_norm,
         nullif(btrim(ii.sku), '') as sku_norm
  from public.inventory_items ii
  where ii.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(ii.is_active, true)
),
match as (
  select p.id as menu_item_id, p.is_inventory_tracked, i.id as insumo_id
  from prod p
  join lateral (
    select x.id from ins x
     where (x.sku_norm is not null and x.sku_norm = p.sku_norm)
        or x.nombre_norm = p.nombre_norm
     order by (x.sku_norm is not null and x.sku_norm = p.sku_norm) desc,
              x.created_at asc
     limit 1
  ) i on true
),
respaldo as (
  insert into public.zz_backup_inventariable_20260901
    (menu_item_id, was_tracked, was_inventory_item_id, tanda)
  select menu_item_id, is_inventory_tracked, null, 'B' from match
  on conflict (menu_item_id) do nothing
  returning menu_item_id
)
update public.menu_items mi
   set is_inventory_tracked = true,
       inventory_item_id    = m.insumo_id
  from match m
 where mi.id = m.menu_item_id;


-- ---------------------------------------------------------------------------
-- TANDA B2 — enlazar por CÓDIGO CRUZADO (barcode↔sku entre las dos fichas).
--
-- POR QUÉ EXISTE: el RPC empareja sku↔sku y nombre↔nombre. En este catálogo
-- el mismo EAN vive en campos distintos (en el producto suele estar en
-- `barcode`, en el insumo en `sku`) y con NOMBRES distintos, así que se le
-- escapan. Medido 2026-09-01: 4 pares —CARLES DE QUESO ↔ PAPITAS DE QUESO
-- CARLES y los tres TAKIS—. Son el mismo producto: crearles ficha nueva
-- duplicaría el maestro.
--
-- Mínimo 6 dígitos para que un SKU interno corto ("1028") no case con nada.
-- Si un código apunta a dos insumos distintos, ese producto se SALTA: es un
-- código mal cargado y hay que arreglarlo a mano, no elegir al azar.
-- ---------------------------------------------------------------------------
with prod_cod as (
  select mi.id, mi.is_inventory_tracked, cod
  from public.menu_items mi
  cross join lateral (
    values (nullif(btrim(mi.barcode), '')), (nullif(btrim(mi.sku), ''))
  ) as c(cod)
  where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(mi.is_active, true)
    and not mi.is_inventory_tracked
    and mi.inventory_item_id is null
    and c.cod is not null
    and c.cod ~ '^[0-9]{6,14}$'
),
ins_cod as (
  select ii.id, cod
  from public.inventory_items ii
  cross join lateral (
    values (nullif(btrim(ii.barcode), '')), (nullif(btrim(ii.sku), ''))
  ) as c(cod)
  where ii.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(ii.is_active, true)
    and c.cod is not null
    and c.cod ~ '^[0-9]{6,14}$'
),
unico as (
  select p.id as menu_item_id,
         min(p.is_inventory_tracked::int)::boolean as was_tracked,
         min(i.id::text)::uuid as insumo_id,
         count(distinct i.id) as cuantos
  from prod_cod p
  join ins_cod i on i.cod = p.cod
  group by p.id
  having count(distinct i.id) = 1
),
respaldo as (
  insert into public.zz_backup_inventariable_20260901
    (menu_item_id, was_tracked, was_inventory_item_id, tanda)
  select menu_item_id, was_tracked, null, 'B2' from unico
  on conflict (menu_item_id) do nothing
  returning menu_item_id
)
update public.menu_items mi
   set is_inventory_tracked = true,
       inventory_item_id    = u.insumo_id
  from unico u
 where mi.id = u.menu_item_id;


-- ---------------------------------------------------------------------------
-- REVISAR ANTES DE LA TANDA C — qué se va a crear.
-- Corré esto y mirá la lista. Si algo no está físicamente en el anaquel como
-- esa unidad, sacalo de la regla de abajo.
-- ---------------------------------------------------------------------------
select mi.name, mi.price, mi.cost, mi.sku, mi.barcode, c.name as categoria
from public.menu_items mi
left join public.categories c on c.id = mi.category_id
where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and coalesce(mi.is_active, true)
  and not mi.is_inventory_tracked
  and mi.inventory_item_id is null
  and (
    coalesce(btrim(mi.barcode), '') <> ''
    or (coalesce(btrim(mi.sku), '') ~ '^[0-9]{8,14}$'
        and coalesce(btrim(mi.sku), '') !~ '^000')
  )
order by mi.name;


-- ---------------------------------------------------------------------------
-- TANDA C — REVENTA: crea el insumo, lo enlaza y prende el flag.
--
-- La regla del `where` es editable: es la misma de la consulta de arriba.
-- Lo que NO entra a propósito: cafés, jugos, platos, cócteles, guarniciones y
-- servicios (SKU interno). Esos necesitan RECETA, no stock propio, y meterlos
-- acá llenaría el conteo de renglones que nadie puede contar.
--
-- Se hace en bucle y no en un INSERT masivo porque hay productos con el mismo
-- nombre: un join por nombre después de insertar emparejaría mal.
-- ---------------------------------------------------------------------------
do $$
declare
  r record;
  v_id uuid;
  v_n int := 0;
  v_saltados int := 0;
begin
  -- Los nombres normalizados de los insumos se calculan UNA vez. Sin esto el
  -- guard de abajo evalúa dos regexp por cada par producto×insumo (~983 ×
  -- 1,088 = más de un millón) y el cierre se arriesga a morir por
  -- statement_timeout a mitad de camino.
  create temp table if not exists _ins_norm on commit drop as
    select id,
           lower(regexp_replace(name, '[^a-zA-Z0-9]', '', 'g')) as limpio
    from public.inventory_items
    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
      and coalesce(is_active, true);
  create index on _ins_norm (left(limpio, 1), length(limpio));

  for r in
    with prod as (
      select mi.id, mi.business_id, mi.name, mi.sku, mi.barcode,
             coalesce(mi.cost, 0) as cost, mi.is_inventory_tracked,
             lower(regexp_replace(mi.name, '[^a-zA-Z0-9]', '', 'g')) as limpio
      from public.menu_items mi
      where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
        and coalesce(mi.is_active, true)
        and not mi.is_inventory_tracked
        and mi.inventory_item_id is null
        and (
          coalesce(btrim(mi.barcode), '') <> ''
          or (coalesce(btrim(mi.sku), '') ~ '^[0-9]{8,14}$'
              and coalesce(btrim(mi.sku), '') !~ '^000')
        )
    )
    select p.*,
           -- GUARD ANTI-DUPLICADO: ya hay un insumo que se LLAMA casi igual.
           -- Los códigos no chocan (solo 4 pares), pero "PRINGLES QUESO 40G"
           -- vs "PRINGLES QUESO 40 G" sí duplicaría el maestro. Mismo criterio
           -- con el que se fusionaron duplicados el 2026-08-30: idéntico sin
           -- espacios, o similarity >= 0.72 acotada por inicial y largo.
           exists (
             select 1 from _ins_norm i
              where left(i.limpio, 1) = left(p.limpio, 1)
                and abs(length(i.limpio) - length(p.limpio)) <= 4
                and (i.limpio = p.limpio
                     or similarity(i.limpio, p.limpio) >= 0.72)
           ) as ya_hay_parecido
    from prod p
    order by p.name
  loop
    if r.ya_hay_parecido then
      -- No se crea: sale en la consulta de abajo para enlazarlo a mano.
      v_saltados := v_saltados + 1;
      continue;
    end if;

    insert into public.inventory_items
      (business_id, sku, name, unit, cost, is_active, barcode)
    values
      (r.business_id,
       nullif(btrim(coalesce(r.sku, '')), ''),
       r.name,
       'unidad',
       r.cost,
       true,
       nullif(btrim(coalesce(r.barcode, '')), ''))
    returning id into v_id;

    update public.menu_items
       set inventory_item_id = v_id,
           is_inventory_tracked = true
     where id = r.id;

    insert into public.zz_backup_inventariable_20260901
      (menu_item_id, was_tracked, was_inventory_item_id, tanda,
       created_inventory_item_id)
    values (r.id, r.is_inventory_tracked, null, 'C', v_id)
    on conflict (menu_item_id) do update
      set created_inventory_item_id = excluded.created_inventory_item_id;

    v_n := v_n + 1;
  end loop;

  raise notice 'Tanda C: % productos activados, % salteados por nombre parecido',
    v_n, v_saltados;
end $$;


-- ---------------------------------------------------------------------------
-- LO QUE EL GUARD DE LA TANDA C SALTEÓ — revisar a mano.
--
-- Son productos de reventa que se PARECEN a un insumo que ya existe. Cada uno
-- es una de dos cosas: (a) el mismo artículo con el nombre escrito distinto
-- —se enlaza al insumo que ya está, sin crear nada—, o (b) dos cosas
-- diferentes que se llaman parecido (los sabores de una misma marca son el
-- caso típico) —esos van a la tanda D—.
-- ---------------------------------------------------------------------------
with prod as (
  select mi.id, mi.name,
         lower(regexp_replace(mi.name, '[^a-zA-Z0-9]', '', 'g')) as limpio
  from public.menu_items mi
  where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(mi.is_active, true)
    and not mi.is_inventory_tracked
    and mi.inventory_item_id is null
    and (
      coalesce(btrim(mi.barcode), '') <> ''
      or (coalesce(btrim(mi.sku), '') ~ '^[0-9]{8,14}$'
          and coalesce(btrim(mi.sku), '') !~ '^000')
    )
),
ins as (
  select ii.id, ii.name,
         lower(regexp_replace(ii.name, '[^a-zA-Z0-9]', '', 'g')) as limpio
  from public.inventory_items ii
  where ii.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(ii.is_active, true)
)
select p.name as producto_no_creado,
       i.name as insumo_parecido,
       i.id   as insumo_id,
       case when p.limpio = i.limpio then 'idéntico sin espacios'
            else 'parecido ' || round(similarity(p.limpio, i.limpio)::numeric, 2)::text
       end    as coincidencia
from prod p
join ins i
  on left(p.limpio, 1) = left(i.limpio, 1)
 and abs(length(p.limpio) - length(i.limpio)) <= 4
 and (p.limpio = i.limpio or similarity(p.limpio, i.limpio) >= 0.72)
order by (p.limpio = i.limpio) desc, p.name;


-- ---------------------------------------------------------------------------
-- TANDA D — los que la regla automática no agarra pero SÍ son mercancía.
--
-- Para qué: hay reventa con SKU interno (PRESIDENTE NORMAL 22OZ - FIESTA,
-- THE ONE 22ONZ, SAN PELLEGRINO, CARLES PLATANITOS, QUESO DE HOJA, FUNDA DE
-- HIELO…). La regla del código no las ve y hay que decirlo a mano.
--
-- CÓMO: elegí UNA de las dos formas de armar `objetivo` — por categoría
-- completa o por lista de nombres — y borrá la otra. Hace lo mismo que la
-- tanda C: crea el insumo, lo enlaza y prende el flag.
-- ---------------------------------------------------------------------------
do $$
declare
  r record;
  v_id uuid;
  v_n int := 0;
begin
  for r in
    select mi.id, mi.business_id, mi.name, mi.sku, mi.barcode,
           coalesce(mi.cost, 0) as cost, mi.is_inventory_tracked
    from public.menu_items mi
    left join public.categories c on c.id = mi.category_id
    where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
      and coalesce(mi.is_active, true)
      and not mi.is_inventory_tracked
      and mi.inventory_item_id is null
      and (
        -- (a) POR CATEGORÍA: bloques que son tienda de punta a punta.
        c.name in ('TIENDA', 'CERVEZAS', 'VINOS')

        -- (b) POR NOMBRE EXACTO: los sueltos. Agregá o quitá los que quieras.
        or mi.name in (
          'PRESIDENTE NORMAL 22OZ - FIESTA',
          'THE ONE 22ONZ',
          'SAN PELLEGRINO ARANCIA & F. INDIA',
          'CARLES PLATANITOS PICANTES 54GR.',
          'QUESO DE HOJA',
          'FUNDA DE HIELO'
        )
      )
    order by mi.name
  loop
    insert into public.inventory_items
      (business_id, sku, name, unit, cost, is_active, barcode)
    values
      (r.business_id,
       nullif(btrim(coalesce(r.sku, '')), ''),
       r.name,
       'unidad',
       r.cost,
       true,
       nullif(btrim(coalesce(r.barcode, '')), ''))
    returning id into v_id;

    update public.menu_items
       set inventory_item_id = v_id,
           is_inventory_tracked = true
     where id = r.id;

    insert into public.zz_backup_inventariable_20260901
      (menu_item_id, was_tracked, was_inventory_item_id, tanda,
       created_inventory_item_id)
    values (r.id, r.is_inventory_tracked, null, 'D', v_id)
    on conflict (menu_item_id) do update
      set created_inventory_item_id = excluded.created_inventory_item_id;

    v_n := v_n + 1;
  end loop;
  raise notice 'Tanda D: % productos activados', v_n;
end $$;


-- ---------------------------------------------------------------------------
-- TANDA D2 — las fugas que quedaron después de todo (2026-09-01).
--
-- De los 731 no inventariables, se listaron los que VENDIERON en 90 días
-- (consulta 6 del diagnóstico). Casi todos son cocina y cafetería, que van
-- por receta. Estos cuatro son mercancía de reventa que la regla del código
-- no vio porque tienen SKU interno:
--
--   CANADA DRY AGUA TONICA           71 vendidas
--   PALETA CHOCO CREMA               42
--   VASOS GRANDES DE BROWNIES WORLD  14
--   WELCH´S PEQUEÑA 25 G             13
--
-- LOS POSTRES DE PROVEEDOR QUEDAN COMENTADOS a propósito: FLAN, CHEESECAKE,
-- CAPRICHO RED VELVET y COCO HORNEADO vienen de fuera, pero si se compra el
-- bizcocho ENTERO y se vende POR REBANADA, eso es una receta (1 bizcocho =
-- N porciones), no stock propio — inventariarlos 1:1 haría que cada rebanada
-- descuente un bizcocho completo. Descomentar solo los que se venden en la
-- misma unidad en que se compran.
-- ---------------------------------------------------------------------------
do $$
declare
  r record;
  v_id uuid;
  v_n int := 0;
begin
  for r in
    select mi.id, mi.business_id, mi.name, mi.sku, mi.barcode,
           coalesce(mi.cost, 0) as cost, mi.is_inventory_tracked
    from public.menu_items mi
    where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
      and coalesce(mi.is_active, true)
      and not mi.is_inventory_tracked
      and mi.inventory_item_id is null
      and mi.name in (
        'CANADA DRY AGUA TONICA',
        'PALETA CHOCO CREMA',
        'VASOS GRANDES DE BROWNIES WORLD',
        'WELCH´S PEQUEÑA 25 G'
        -- , 'FLAN'
        -- , 'CAPRICHO RED VELVET'
        -- , 'COCO HORNEADO'
        -- , 'COCO HORNEADO D"ELYN PEUEÑO'
        -- , 'CHEESECAKE VARIADO'
      )
    order by mi.name
  loop
    insert into public.inventory_items
      (business_id, sku, name, unit, cost, is_active, barcode)
    values
      (r.business_id,
       nullif(btrim(coalesce(r.sku, '')), ''),
       r.name,
       'unidad',
       r.cost,
       true,
       nullif(btrim(coalesce(r.barcode, '')), ''))
    returning id into v_id;

    update public.menu_items
       set inventory_item_id = v_id,
           is_inventory_tracked = true
     where id = r.id;

    insert into public.zz_backup_inventariable_20260901
      (menu_item_id, was_tracked, was_inventory_item_id, tanda,
       created_inventory_item_id)
    values (r.id, r.is_inventory_tracked, null, 'D2', v_id)
    on conflict (menu_item_id) do update
      set created_inventory_item_id = excluded.created_inventory_item_id;

    v_n := v_n + 1;
  end loop;
  raise notice 'Tanda D2: % productos activados', v_n;
end $$;

-- OJO: después de esta tanda hay que volver a correr la consulta 2 de
-- RECARGAR_conteo_penda.sql, o las fichas nuevas no entran en las sesiones
-- que ya están congeladas.


-- ---------------------------------------------------------------------------
-- VERIFICAR después de cada tanda
-- ---------------------------------------------------------------------------
select tanda, count(*) as productos,
       count(created_inventory_item_id) as insumos_creados
from public.zz_backup_inventariable_20260901
group by tanda
order by tanda;


-- ---------------------------------------------------------------------------
-- REVERTIR (todo, o una tanda: agregar  and b.tanda = 'C'  a las dos)
--
-- El borrado de insumos solo toca los que NO tienen movimientos: si ya se
-- vendió o se contó algo contra esa ficha, se queda (borrarla falsearía el
-- kardex). Esos hay que desactivarlos a mano si molestan.
-- ---------------------------------------------------------------------------
-- update public.menu_items mi
--    set is_inventory_tracked = coalesce(b.was_tracked, false),
--        inventory_item_id    = b.was_inventory_item_id
--   from public.zz_backup_inventariable_20260901 b
--  where mi.id = b.menu_item_id;
--
-- delete from public.inventory_items ii
--  using public.zz_backup_inventariable_20260901 b
--  where ii.id = b.created_inventory_item_id
--    and not exists (select 1 from public.inventory_movements m
--                     where m.item_id = ii.id);

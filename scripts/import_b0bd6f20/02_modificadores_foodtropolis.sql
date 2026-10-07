-- ============================================================================
-- LA COCINA MEXICANA AUTENTICA (b0bd6f20) — MODIFICADORES DE FOODTROPOLIS
--
-- Se corre DESPUÉS de IMPORT_COMPLETO.sql (corrido en prod el 07-oct).
-- Deja los modificadores igual que en FOODTROPOLIS (800e4643), de donde se
-- clonaron los productos de esta sucursal.
--
-- QUÉ HACE
--   1. Copia los 19 grupos de Foodtropolis tal cual están AL MOMENTO de
--      correrlo: nombre, mínimo/máximo, tipo, orden y opciones con su precio.
--      "Extras" ya existía aquí (el de la carga): se iguala al de Foodtropolis
--      (15 opciones) y se quitan las opciones que allá no existen.
--   2. Los liga a los mismos productos, por nombre (BURRITO ← Proteina 3, SIN,
--      Extras; SODA CAN ← Canada Dry, Dr.Pepper, Squirt...).
--   3. SIN y Extras van también a los platos nuevos del CSV: a todo lo que
--      tenía el grupo Extras de la carga (38 productos de cocina).
--   4. Sabores que Foodtropolis no tiene (decisión del 07-oct):
--      REFRESCOS (Sabor Soda) + Rojo, Uva, Merengue $50, Sangría Señorial y
--      Boing Mango $200; JUGOS NATURALES (Sabores Jugos) + Fruit Punch $150.
--   5. Quita lo de la carga que choca con Foodtropolis:
--      - grupos "Tostadas · Tipo", "Soda Can · Sabor", "Refrescos Sabores ·
--        Sabor", "Jarritos · Sabor" y "Refresco · Sabor";
--      - productos REFRESCO y los jugos sueltos (Cereza, Chinola, Limón,
--        Fruit Punch): ahora son opciones de REFRESCOS / JUGOS NATURALES.
--      Se BORRAN si nunca se vendieron; si ya se vendieron, se desactivan.
--   6. SODA CAN, REFRESCOS y JUGOS NATURALES vuelven a $0, como en
--      Foodtropolis: el precio lo pone la opción (Coca Cola 20oz $100...).
--      Con precio en el producto se cobraría DOS veces.
--
-- NO TOCA impuestos, áreas, categorías ni los demás precios.
--
-- TODO O NADA y SE PUEDE RE-CORRER: una transacción; lo que ya está igual no
-- se vuelve a escribir. El reporte del final debe decir ✓ (⚠ es un aviso).
-- ============================================================================

begin;

create or replace function pg_temp.norm(t text) returns text
language sql immutable as $f$
  select translate(lower(regexp_replace(btrim(t), '\s+', ' ', 'g')),
                   'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun')
$f$;

create or replace function pg_temp.k(t text) returns text
language sql immutable as $f$
  select btrim(regexp_replace(
           translate(lower(t), 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun'),
           '[^a-z0-9]+', ' ', 'g'))
$f$;

drop table if exists _ft_cfg;
create temp table _ft_cfg as
select '800e4643-d35a-4795-b9c3-f70c71bc1187'::uuid as origen,
       'b0bd6f20-850c-4e9a-85ae-4cd619e1a0ee'::uuid as destino;

-- Grupos de la carga que reemplaza Foodtropolis.
drop table if exists _ft_quitar_grupos;
create temp table _ft_quitar_grupos (name text not null);
insert into _ft_quitar_grupos (name) values
  ('Tostadas · Tipo'), ('Soda Can · Sabor'), ('Refrescos Sabores · Sabor'),
  ('Jarritos · Sabor'), ('Refresco · Sabor');

-- Productos de la carga que ahora son opciones de REFRESCOS / JUGOS NATURALES.
drop table if exists _ft_quitar_productos;
create temp table _ft_quitar_productos (name text not null);
insert into _ft_quitar_productos (name) values
  ('REFRESCO'), ('JUGO DE CEREZA'), ('JUGO DE CHINOLA'), ('JUGO DE LIMÓN'),
  ('JUGO DE FRUIT PUNCH');

-- Productos que en Foodtropolis valen $0: el precio va en la opción.
drop table if exists _ft_precio_cero;
create temp table _ft_precio_cero (name text not null);
insert into _ft_precio_cero (name) values ('SODA CAN'), ('REFRESCOS'), ('JUGOS NATURALES');

-- Sabores que Foodtropolis no tiene, en el grupo de Foodtropolis que toca.
drop table if exists _ft_agregar;
create temp table _ft_agregar (grupo text not null, name text not null, price numeric(12,2) not null, orden int not null);
insert into _ft_agregar (grupo, name, price, orden) values
  ('Sabor Soda', 'Rojo', 50, 101),
  ('Sabor Soda', 'Uva', 50, 102),
  ('Sabor Soda', 'Merengue', 50, 103),
  ('Sabor Soda', 'Sangría Señorial', 200, 104),
  ('Sabor Soda', 'Boing Mango', 200, 105),
  ('Sabores Jugos', 'Fruit Punch', 150, 101);

drop table if exists _ft_map;
create temp table _ft_map (src uuid primary key, dst uuid not null, name text not null, nuevo boolean not null);
drop table if exists _ft_resultado;
create temp table _ft_resultado (que text not null, name text not null, accion text not null);

do $$
declare
  v_src  uuid;
  v_dst  uuid;
  v_g    record;
  v_id   uuid;
  v_ex   uuid;
  v_n    int;
  v_list text;
  v_tiene_modifier_id boolean;
begin
  select origen, destino into v_src, v_dst from _ft_cfg;

  -- =========================================================================
  -- 1) GUARDAS
  -- =========================================================================

  if not exists (select 1 from public.businesses where id = v_src) then
    raise exception 'No existe el negocio de Foodtropolis %.', v_src;
  end if;
  if not exists (select 1 from public.businesses where id = v_dst) then
    raise exception 'No existe el negocio %.', v_dst;
  end if;
  if not exists (select 1 from public.modifier_groups where business_id = v_src) then
    raise exception 'Foodtropolis no tiene grupos de modificadores.';
  end if;

  select string_agg(n, ', ') into v_list
  from (select pg_temp.norm(name) as n from public.modifier_groups
        where business_id = v_src group by 1 having count(*) > 1) d;
  if v_list is not null then
    raise exception 'Foodtropolis tiene grupos con el mismo nombre: %', v_list;
  end if;

  select string_agg(n, ', ') into v_list
  from (select pg_temp.norm(g.name) as n from public.modifier_groups g
        where g.business_id = v_dst
          and pg_temp.norm(g.name) in (select pg_temp.norm(name) from public.modifier_groups
                                       where business_id = v_src)
        group by 1 having count(*) > 1) d;
  if v_list is not null then
    raise exception 'Este negocio tiene grupos repetidos con nombre de Foodtropolis: %', v_list;
  end if;

  if exists (select 1 from _ft_quitar_grupos q
             join public.modifier_groups g
               on g.business_id = v_src and pg_temp.norm(g.name) = pg_temp.norm(q.name)) then
    raise exception 'Un grupo a quitar se llama igual que uno de Foodtropolis.';
  end if;

  select string_agg(a.grupo, ', ') into v_list
  from (select distinct grupo from _ft_agregar) a
  where not exists (select 1 from public.modifier_groups g
                    where g.business_id = v_src and pg_temp.norm(g.name) = pg_temp.norm(a.grupo));
  if v_list is not null then
    raise exception 'Foodtropolis no tiene el grupo % para agregarle sabores.', v_list;
  end if;

  -- Una columna con un uuid (fuera de las llaves) apuntaría a algo de
  -- Foodtropolis: no se copia a ciegas.
  select string_agg(distinct j.key, ', ') into v_list
  from public.modifier_groups g, jsonb_each_text(to_jsonb(g)) j
  where g.business_id = v_src and j.key not in ('id', 'business_id')
    and j.value ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
  if v_list is null then
    select string_agg(distinct j.key, ', ') into v_list
    from public.modifiers m
    join public.modifier_groups g on g.id = m.group_id and g.business_id = v_src,
         jsonb_each_text(to_jsonb(m)) j
    where j.key not in ('id', 'business_id', 'group_id')
      and j.value ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
  end if;
  if v_list is not null then
    raise exception 'Los modificadores de Foodtropolis traen columnas con uuid (%): no se copian.', v_list;
  end if;

  -- En Foodtropolis estos valen $0. Si no, el modelo es otro: no adivino.
  select string_agg(format('%s $%s', mi.name, mi.price), ', ') into v_list
  from _ft_precio_cero z
  join public.menu_items mi
    on mi.business_id = v_src and mi.is_active and pg_temp.k(mi.name) = pg_temp.k(z.name)
  where mi.price <> 0;
  if v_list is not null then
    raise exception 'En Foodtropolis estos no valen $0: %. Revisar antes de copiar.', v_list;
  end if;

  -- Nombres de producto que se repiten aquí: no sabría a cuál ligar.
  select string_agg(n, ', ') into v_list
  from (select pg_temp.k(name) as n from public.menu_items
        where business_id = v_dst and is_active group by 1 having count(*) > 1) d;
  if v_list is not null then
    raise exception 'Productos activos repetidos en este negocio: %', v_list;
  end if;

  v_tiene_modifier_id := exists (
    select 1 from pg_attribute
    where attrelid = 'public.order_item_modifiers'::regclass
      and attname = 'modifier_id' and not attisdropped);

  -- =========================================================================
  -- 2) GRUPOS: el de aquí con el mismo nombre se iguala; si no hay, se copia.
  -- =========================================================================

  for v_g in
    select g.* from public.modifier_groups g where g.business_id = v_src
  loop
    select id into v_id
    from public.modifier_groups
    where business_id = v_dst and pg_temp.norm(name) = pg_temp.norm(v_g.name);

    if v_id is null then
      v_id := gen_random_uuid();
      insert into public.modifier_groups
      select (jsonb_populate_record(
                null::public.modifier_groups,
                to_jsonb(g) || jsonb_build_object('id', v_id, 'business_id', v_dst,
                                                  'created_at', now()))).*
      from public.modifier_groups g
      where g.id = v_g.id;
      insert into _ft_map values (v_g.id, v_id, v_g.name, true);
    else
      update public.modifier_groups d
      set name = s.name, min_select = s.min_select, max_select = s.max_select,
          is_active = s.is_active, display_type = s.display_type,
          selection_mode = s.selection_mode, is_required = s.is_required,
          free_qty = s.free_qty, max_qty_per_option = s.max_qty_per_option,
          sort_order = s.sort_order
      from public.modifier_groups s
      where s.id = v_g.id and d.id = v_id
        and (d.name, d.min_select, d.max_select, d.is_active, d.display_type, d.selection_mode,
             d.is_required, d.free_qty, d.max_qty_per_option, d.sort_order)
            is distinct from
            (s.name, s.min_select, s.max_select, s.is_active, s.display_type, s.selection_mode,
             s.is_required, s.free_qty, s.max_qty_per_option, s.sort_order);
      insert into _ft_map values (v_g.id, v_id, v_g.name, false);
    end if;
  end loop;

  -- =========================================================================
  -- 3) OPCIONES: iguales a Foodtropolis + los sabores agregados.
  -- =========================================================================

  -- Las que ya están (por nombre dentro del grupo) se igualan.
  update public.modifiers d
  set name = s.name, price_delta = s.price_delta, is_active = s.is_active,
      sort_order = s.sort_order, default_selected = s.default_selected
  from public.modifiers s
  join _ft_map m on m.src = s.group_id
  where d.group_id = m.dst and pg_temp.norm(d.name) = pg_temp.norm(s.name)
    and (d.name, d.price_delta, d.is_active, d.sort_order, d.default_selected)
        is distinct from (s.name, s.price_delta, s.is_active, s.sort_order, s.default_selected);

  -- Las que faltan se copian.
  insert into public.modifiers
  select (jsonb_populate_record(
            null::public.modifiers,
            to_jsonb(s) || jsonb_build_object('id', gen_random_uuid(), 'business_id', v_dst,
                                              'group_id', m.dst, 'created_at', now()))).*
  from public.modifiers s
  join _ft_map m on m.src = s.group_id
  where not exists (select 1 from public.modifiers d
                    where d.group_id = m.dst and pg_temp.norm(d.name) = pg_temp.norm(s.name));

  -- Sabores que Foodtropolis no tiene.
  update public.modifiers d
  set price_delta = a.price, is_active = true, sort_order = a.orden
  from _ft_agregar a
  join _ft_map m on pg_temp.norm(m.name) = pg_temp.norm(a.grupo)
  where d.group_id = m.dst and pg_temp.norm(d.name) = pg_temp.norm(a.name)
    and (d.price_delta, d.is_active, d.sort_order) is distinct from (a.price, true, a.orden);

  insert into public.modifiers (id, business_id, group_id, name, price_delta, is_active, sort_order)
  select gen_random_uuid(), v_dst, m.dst, a.name, a.price, true, a.orden
  from _ft_agregar a
  join _ft_map m on pg_temp.norm(m.name) = pg_temp.norm(a.grupo)
  where not exists (select 1 from public.modifiers d
                    where d.group_id = m.dst and pg_temp.norm(d.name) = pg_temp.norm(a.name));

  -- Las que sobran (las del Extras de la carga): se borran si nunca se
  -- vendieron; si ya se vendieron, se desactivan.
  for v_g in
    select d.id, d.name
    from public.modifiers d
    join _ft_map m on m.dst = d.group_id
    where not exists (select 1 from public.modifiers s
                      where s.group_id = m.src and pg_temp.norm(s.name) = pg_temp.norm(d.name))
      and not exists (select 1 from _ft_agregar a
                      where pg_temp.norm(a.grupo) = pg_temp.norm(m.name)
                        and pg_temp.norm(a.name) = pg_temp.norm(d.name))
  loop
    begin
      if v_tiene_modifier_id then
        execute 'select count(*) from public.order_item_modifiers where modifier_id = $1'
          into v_n using v_g.id;
      else
        v_n := 0;
      end if;
      if v_n > 0 then
        raise foreign_key_violation;
      end if;
      delete from public.modifiers where id = v_g.id;
      insert into _ft_resultado values ('opción', v_g.name, 'borrada');
    exception when foreign_key_violation then
      update public.modifiers set is_active = false where id = v_g.id and is_active;
      insert into _ft_resultado values ('opción', v_g.name, 'desactivada (ya se vendió)');
    end;
  end loop;

  -- =========================================================================
  -- 4) LIGAS: las de Foodtropolis, por nombre de producto. Y SIN + Extras a
  --    todo lo que ya tenía el Extras de la carga.
  -- =========================================================================

  insert into public.menu_item_groups
  select (jsonb_populate_record(
            null::public.menu_item_groups,
            to_jsonb(y) || jsonb_build_object('id', gen_random_uuid(), 'menu_item_id', d.id,
                                              'group_id', m.dst, 'created_at', now()))).*
  from public.menu_item_groups y
  join _ft_map m on m.src = y.group_id
  join public.menu_items s on s.id = y.menu_item_id and s.is_active
  join public.menu_items d
    on d.business_id = v_dst and d.is_active and pg_temp.k(d.name) = pg_temp.k(s.name)
  where not exists (select 1 from public.menu_item_groups x
                    where x.menu_item_id = d.id and x.group_id = m.dst);

  select dst into v_ex from _ft_map where pg_temp.norm(name) = 'extras';
  insert into public.menu_item_groups (menu_item_id, group_id)
  select distinct y.menu_item_id, m.dst
  from public.menu_item_groups y
  join public.menu_items mi on mi.id = y.menu_item_id and mi.is_active
  join _ft_map m on pg_temp.norm(m.name) in ('sin', 'extras')
  where y.group_id = v_ex
    and not exists (select 1 from public.menu_item_groups x
                    where x.menu_item_id = y.menu_item_id and x.group_id = m.dst);

  -- =========================================================================
  -- 5) GRUPOS DE LA CARGA QUE YA NO VAN
  -- =========================================================================

  for v_g in
    select g.id, g.name from public.modifier_groups g
    join _ft_quitar_grupos q on pg_temp.norm(q.name) = pg_temp.norm(g.name)
    where g.business_id = v_dst
  loop
    delete from public.menu_item_groups where group_id = v_g.id;
    begin
      if v_tiene_modifier_id then
        execute 'select count(*) from public.order_item_modifiers om
                 join public.modifiers m on m.id = om.modifier_id where m.group_id = $1'
          into v_n using v_g.id;
      else
        v_n := 0;
      end if;
      if v_n > 0 then
        raise foreign_key_violation;
      end if;
      delete from public.modifiers where group_id = v_g.id;
      delete from public.modifier_groups where id = v_g.id;
      insert into _ft_resultado values ('grupo', v_g.name, 'borrado');
    exception when foreign_key_violation then
      update public.modifier_groups set is_active = false where id = v_g.id;
      insert into _ft_resultado values ('grupo', v_g.name, 'desligado y desactivado (ya se vendió)');
    end;
  end loop;

  -- =========================================================================
  -- 6) PRODUCTOS DE LA CARGA QUE YA NO VAN
  -- =========================================================================

  for v_g in
    select mi.id, mi.name from public.menu_items mi
    join _ft_quitar_productos q on pg_temp.k(q.name) = pg_temp.k(mi.name)
    where mi.business_id = v_dst
  loop
    begin
      if exists (select 1 from public.order_items oi where oi.product_id = v_g.id) then
        raise foreign_key_violation;
      end if;
      delete from public.menu_item_groups      where menu_item_id = v_g.id;
      delete from public.menu_item_taxes       where item_id = v_g.id;
      delete from public.menu_item_print_areas where menu_item_id = v_g.id;
      delete from public.menu_item_links       where item_id = v_g.id;
      delete from public.menu_items            where id = v_g.id;
      insert into _ft_resultado values ('producto', v_g.name, 'borrado');
    exception when foreign_key_violation then
      update public.menu_items set is_active = false, updated_at = now()
      where id = v_g.id and is_active;
      insert into _ft_resultado values ('producto', v_g.name, 'desactivado (ya se vendió)');
    end;
  end loop;

  -- =========================================================================
  -- 7) PRECIO EN $0 donde lo pone la opción
  -- =========================================================================

  update public.menu_items mi set price = 0, updated_at = now()
  from _ft_precio_cero z
  where mi.business_id = v_dst and pg_temp.k(mi.name) = pg_temp.k(z.name) and mi.price <> 0;

  -- =========================================================================
  -- 8) VERIFICACIÓN: cualquier fallo revierte TODO.
  -- =========================================================================

  if (select count(*) from _ft_map) <> (select count(*) from public.modifier_groups
                                        where business_id = v_src) then
    raise exception 'No se copiaron todos los grupos de Foodtropolis. Revertido.';
  end if;

  select count(*) into v_n
  from public.modifiers s
  join _ft_map m on m.src = s.group_id
  where (select count(*) from public.modifiers d
         where d.group_id = m.dst and pg_temp.norm(d.name) = pg_temp.norm(s.name)
           and d.price_delta = s.price_delta and d.is_active = s.is_active) <> 1;
  if v_n > 0 then
    raise exception '% opciones de Foodtropolis no quedaron iguales. Revertido.', v_n;
  end if;

  select count(*) into v_n
  from public.menu_item_groups y
  join _ft_map m on m.src = y.group_id
  join public.menu_items s on s.id = y.menu_item_id and s.is_active
  join public.menu_items d
    on d.business_id = v_dst and d.is_active and pg_temp.k(d.name) = pg_temp.k(s.name)
  where not exists (select 1 from public.menu_item_groups x
                    where x.menu_item_id = d.id and x.group_id = m.dst);
  if v_n > 0 then
    raise exception '% ligas de Foodtropolis no quedaron. Revertido.', v_n;
  end if;

  if exists (select 1 from public.menu_items mi
             join _ft_quitar_productos q on pg_temp.k(q.name) = pg_temp.k(mi.name)
             where mi.business_id = v_dst and mi.is_active) then
    raise exception 'Quedó activo un producto que había que quitar. Revertido.';
  end if;

  if exists (select 1 from public.menu_item_groups y
             join public.modifier_groups g on g.id = y.group_id
             join _ft_quitar_grupos q on pg_temp.norm(q.name) = pg_temp.norm(g.name)
             where g.business_id = v_dst) then
    raise exception 'Quedó ligado un grupo que había que quitar. Revertido.';
  end if;

  raise notice 'OK: % grupos de Foodtropolis (% nuevos), % opciones/grupos/productos quitados. Commit.',
    (select count(*) from _ft_map), (select count(*) from _ft_map where nuevo),
    (select count(*) from _ft_resultado);
end $$;

commit;

-- ============================================================================
-- REPORTE: ✓ = bien · ⚠ = aviso para decidir · ✗ = revisar
-- ============================================================================

with
cfg as (select * from _ft_cfg),
fg as (select g.* from public.modifier_groups g where g.business_id = (select origen from cfg)),
dg as (select m.src, d.* from _ft_map m join public.modifier_groups d on d.id = m.dst),
ligas_ft as (
  select s.name as producto, m.dst, d.id as dst_item
  from public.menu_item_groups y
  join _ft_map m on m.src = y.group_id
  join public.menu_items s on s.id = y.menu_item_id and s.is_active
  left join public.menu_items d
    on d.business_id = (select destino from cfg) and d.is_active
   and pg_temp.k(d.name) = pg_temp.k(s.name)
),
prod as (
  select mi.* from public.menu_items mi
  where mi.business_id = (select destino from cfg) and mi.is_active
),
grupos_de as (
  select p.id, p.name, p.price,
         coalesce((select string_agg(g.name, ', ' order by g.sort_order, g.name)
                   from public.menu_item_groups y
                   join public.modifier_groups g on g.id = y.group_id
                   where y.menu_item_id = p.id), '—') as grupos
  from prod p
),
ext as (select dst from _ft_map where pg_temp.norm(name) = 'extras'),
sin as (select dst from _ft_map where pg_temp.norm(name) = 'sin'),
r(orden, concepto, encontrado, esperado, estado) as (
  select 1, 'Grupos de Foodtropolis aquí',
         format('%s de %s (%s nuevos, %s igualados: %s)', (select count(*) from dg), (select count(*) from fg),
                (select count(*) from _ft_map where nuevo), (select count(*) from _ft_map where not nuevo),
                coalesce((select string_agg(name, ', ') from _ft_map where not nuevo), '—')),
         (select count(*) from fg)::text,
         case when (select count(*) from dg) = (select count(*) from fg) then '✓' else '✗ REVISAR' end
  union all
  select 2, 'Opciones distintas a Foodtropolis (nombre, precio, activa)',
         (select count(*) from public.modifiers s join dg on dg.src = s.group_id
          where (select count(*) from public.modifiers d
                 where d.group_id = dg.id and pg_temp.norm(d.name) = pg_temp.norm(s.name)
                   and d.price_delta = s.price_delta and d.is_active = s.is_active) <> 1)::text,
         '0',
         case when (select count(*) from public.modifiers s join dg on dg.src = s.group_id
                    where (select count(*) from public.modifiers d
                           where d.group_id = dg.id and pg_temp.norm(d.name) = pg_temp.norm(s.name)
                             and d.price_delta = s.price_delta and d.is_active = s.is_active) <> 1) = 0
              then '✓' else '✗ REVISAR' end
  union all
  select 3, 'Ligas de Foodtropolis replicadas',
         format('%s de %s', (select count(*) from ligas_ft l
                             where exists (select 1 from public.menu_item_groups x
                                           where x.menu_item_id = l.dst_item and x.group_id = l.dst)),
                (select count(*) from ligas_ft where dst_item is not null)),
         'todas',
         case when not exists (select 1 from ligas_ft l
                               where l.dst_item is not null
                                 and not exists (select 1 from public.menu_item_groups x
                                                 where x.menu_item_id = l.dst_item and x.group_id = l.dst))
              then '✓' else '✗ REVISAR' end
  union all
  select 4, 'Productos de Foodtropolis con modificadores que aquí no existen',
         coalesce((select string_agg(distinct producto, ', ') from ligas_ft where dst_item is null), 'ninguno'),
         'ninguno',
         case when exists (select 1 from ligas_ft where dst_item is null) then '⚠ AVISO' else '✓' end
  union all
  select 5, 'Platos con SIN y Extras',
         format('SIN %s · Extras %s',
                (select count(*) from public.menu_item_groups y join prod p on p.id = y.menu_item_id
                 where y.group_id = (select dst from sin)),
                (select count(*) from public.menu_item_groups y join prod p on p.id = y.menu_item_id
                 where y.group_id = (select dst from ext))),
         'los mismos (38)',
         case when (select count(*) from public.menu_item_groups y join prod p on p.id = y.menu_item_id
                    where y.group_id = (select dst from sin))
                 = (select count(*) from public.menu_item_groups y join prod p on p.id = y.menu_item_id
                    where y.group_id = (select dst from ext))
               and (select count(*) from public.menu_item_groups y join prod p on p.id = y.menu_item_id
                    where y.group_id = (select dst from ext)) > 0
              then '✓' else '✗ REVISAR' end
  union all
  select 6, 'Extras (como Foodtropolis)',
         (select string_agg(m.name || ' $' || m.price_delta, ', ' order by m.sort_order, m.name)
          from public.modifiers m where m.group_id = (select dst from ext) and m.is_active),
         (select count(*) from public.modifiers s join dg on dg.src = s.group_id
          where dg.id = (select dst from ext))::text || ' opciones',
         case when (select count(*) from public.modifiers m where m.group_id = (select dst from ext) and m.is_active)
                 = (select count(*) from public.modifiers s join dg on dg.src = s.group_id
                    where dg.id = (select dst from ext))
              then '✓' else '✗ REVISAR' end
  union all
  select 7, 'Sabores agregados (no están en Foodtropolis)',
         (select string_agg(format('%s · %s $%s', a.grupo, a.name, a.price), ', ' order by a.grupo, a.orden)
          from _ft_agregar a
          join _ft_map m on pg_temp.norm(m.name) = pg_temp.norm(a.grupo)
          join public.modifiers d
            on d.group_id = m.dst and pg_temp.norm(d.name) = pg_temp.norm(a.name)
           and d.is_active and d.price_delta = a.price),
         (select count(*) from _ft_agregar)::text || ' sabores',
         case when (select count(*) from _ft_agregar a
                    join _ft_map m on pg_temp.norm(m.name) = pg_temp.norm(a.grupo)
                    join public.modifiers d
                      on d.group_id = m.dst and pg_temp.norm(d.name) = pg_temp.norm(a.name)
                     and d.is_active and d.price_delta = a.price) = (select count(*) from _ft_agregar)
              then '✓' else '✗ REVISAR' end
  union all
  select 8, 'Bebidas con el precio en la opción',
         (select string_agg(format('%s $%s ← %s', g.name, g.price, g.grupos), ' · ' order by g.name)
          from grupos_de g join _ft_precio_cero z on pg_temp.k(z.name) = pg_temp.k(g.name)),
         '$0 y sus grupos de Foodtropolis',
         case when not exists (select 1 from grupos_de g
                               join _ft_precio_cero z on pg_temp.k(z.name) = pg_temp.k(g.name)
                               where g.price <> 0 or g.grupos = '—')
              then '✓' else '✗ REVISAR' end
  union all
  select 9, 'Ejemplo: REFRESCOS + Coca Cola 20oz',
         coalesce((select format('%s + %s = %s', p.price, m.price_delta, p.price + m.price_delta)
                   from prod p
                   join public.menu_item_groups y on y.menu_item_id = p.id
                   join public.modifiers m on m.group_id = y.group_id
                   where pg_temp.k(p.name) = 'refrescos' and pg_temp.k(m.name) = 'coca cola 20oz'
                   limit 1), '—'),
         '0.00 + 100.00 = 100.00',
         case when coalesce((select p.price + m.price_delta = 100
                             from prod p
                             join public.menu_item_groups y on y.menu_item_id = p.id
                             join public.modifiers m on m.group_id = y.group_id
                             where pg_temp.k(p.name) = 'refrescos' and pg_temp.k(m.name) = 'coca cola 20oz'
                             limit 1), false) then '✓' else '✗ REVISAR' end
  union all
  select 10, 'Quitado de la carga',
         coalesce((select string_agg(format('%s %s: %s', que, name, accion), ' · ') from _ft_resultado),
                  'nada (ya estaba quitado)'),
         'informativo', '✓'
  union all
  select 11, 'Grupos de la carga que siguen activos y ligados',
         coalesce((select string_agg(g.name, ', ')
                   from public.modifier_groups g
                   join _ft_quitar_grupos q on pg_temp.norm(q.name) = pg_temp.norm(g.name)
                   where g.business_id = (select destino from cfg) and g.is_active), 'ninguno'),
         'ninguno',
         case when exists (select 1 from public.modifier_groups g
                           join _ft_quitar_grupos q on pg_temp.norm(q.name) = pg_temp.norm(g.name)
                           where g.business_id = (select destino from cfg) and g.is_active)
              then '✗ REVISAR' else '✓' end
  union all
  select 12, 'SODA CAN se puede vender en $0',
         'sus 3 grupos (Canada Dry, Dr.Pepper, Squirt) son opcionales: si no marcan ninguno, sale en $0',
         'igual que en Foodtropolis', '⚠ AVISO'
  union all
  select 13, 'JARRITOS con Mundet',
         coalesce((select format('JARRITOS $%s + Sidral Manzana $%s = $%s (en Foodtropolis JARRITOS vale $%s)',
                                 p.price, m.price_delta, p.price + m.price_delta,
                                 (select f.price from public.menu_items f
                                  where f.business_id = (select origen from cfg) and f.is_active
                                    and pg_temp.k(f.name) = 'jarritos' limit 1))
                   from prod p
                   join public.menu_item_groups y on y.menu_item_id = p.id
                   join public.modifiers m on m.group_id = y.group_id
                   where pg_temp.k(p.name) = 'jarritos' and pg_temp.k(m.name) = 'sidral manzana'
                   limit 1), '—'),
         'el Sidral solo vale $200 en el CSV', '⚠ AVISO'
  union all
  select 14, 'TODO lo activo sigue con área e impuestos',
         format('%s de %s', (select count(*) from prod p
                             where exists (select 1 from public.menu_item_print_areas x where x.menu_item_id = p.id)
                               and exists (select 1 from public.menu_item_taxes t where t.item_id = p.id)),
                (select count(*) from prod)),
         'todos menos Carne Cocida (sin impuesto)',
         case when (select count(*) from prod p
                    where not exists (select 1 from public.menu_item_print_areas x where x.menu_item_id = p.id)
                       or (not exists (select 1 from public.menu_item_taxes t where t.item_id = p.id)
                           and pg_temp.k(p.name) <> 'carne cocida natural xlb')) = 0
              then '✓' else '✗ REVISAR' end
)
select concepto, encontrado, esperado, estado
from r
order by orden;

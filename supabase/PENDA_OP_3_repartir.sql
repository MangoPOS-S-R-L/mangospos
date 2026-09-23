-- =============================================================================
-- LA PENDA EXPRESS · OPERACIÓN INVENTARIO — PASO 3: repartir el conteo
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- ESCRIBE. No cierra nada. Idempotente: se puede correr de nuevo.
-- Guarda el estado anterior en `_penda_op3_backup` para poder deshacer.
--
-- HACE DOS COSAS Y NADA MÁS:
--
--   1. CONSOLIDA los insumos que Winnifer y Rosayra contaron los dos.
--      Las dos sesiones son del MISMO FoodShop. Al cerrar, la segunda pisa
--      a la primera (v_applied = contado − stock vivo), así que uno de los
--      dos conteos se pierde. Se SUMAN en la sesión de Rosayra y la línea
--      de Winnifer queda en NULL.
--
--      ¿POR QUÉ SUMAR Y NO QUEDARSE CON UNO? Porque se repartieron el
--      trabajo: de 469 líneas contadas entre las dos, solo se solapan un
--      puñado. Eso es una costura entre dos zonas, no dos pasadas completas
--      sobre el mismo estante. Si fueran dos pasadas completas habría
--      cientos de solapes, no cinco.
--      Si la cocina dice que SÍ contaron lo mismo dos veces, cambiar
--      v_modo a 'max' abajo.
--
--   2. REAPUNTA cada sesión a su almacén:
--        PC-2026-000002  Diego · Furgón        → Almacen Principal
--        PC-2026-000003  Almacén de Cocina     → Cocina
--        PC-2026-000004  Food Shop · Winnifer  → FoodShop
--        PC-2026-000005  Food Shop · Rosayra   → FoodShop
--        PC-2026-000006  Bar · DH              → Bar
--
-- POR QUÉ ESTO NO ES OPCIONAL — el caso CARIBAS PLATANITOS:
--   hoy tiene 16,571,952,679 unidades en FoodShop (el ajuste de GLORIBEL del
--   11-sep) y 8 en Principal. Rosayra lo contó en 4.
--     * CON reparto:  Rosayra cierra contra FoodShop → 4 − 16,571,952,679
--                     deja FoodShop en 4. El disparate se borra solo.
--     * SIN reparto:  Rosayra cierra contra Principal → Principal queda en 4
--                     y FoodShop SE QUEDA CON LOS 16 MIL MILLONES para
--                     siempre, porque ninguna sesión apunta ahí.
--   El reparto no es cosmético: es lo que limpia el ajuste.
-- =============================================================================

do $$
declare
  v_biz   uuid := '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';
  v_modo  text := 'sumar';        -- 'sumar' | 'max'
  v_win   uuid;                   -- PC-2026-000004
  v_ros   uuid;                   -- PC-2026-000005
  v_n     int;
  r       record;
begin
  ---------------------------------------------------------------------------
  -- Guarda 1: los cuatro almacenes tienen que existir (PASO 5).
  ---------------------------------------------------------------------------
  select count(*) into v_n
    from public.warehouses
   where business_id = v_biz and coalesce(is_active,true)
     and name in ('Almacen Principal','Cocina','FoodShop','Bar');
  if v_n <> 4 then
    raise exception 'Faltan almacenes: se encontraron % de 4 (Almacen Principal, '
                    'Cocina, FoodShop, Bar). Correr PASO 5 primero. No se toco nada.', v_n;
  end if;

  ---------------------------------------------------------------------------
  -- Guarda 2: las cinco sesiones siguen abiertas. Una cerrada no se reabre,
  -- asi que si alguna ya cerro hay que parar y mirar que paso.
  ---------------------------------------------------------------------------
  select count(*) into v_n
    from public.physical_count_sessions
   where business_id = v_biz and status in ('draft','in_progress')
     and code in ('PC-2026-000002','PC-2026-000003','PC-2026-000004',
                  'PC-2026-000005','PC-2026-000006');
  if v_n <> 5 then
    raise exception 'Se esperaban 5 sesiones abiertas y hay %. No se toco nada.', v_n;
  end if;

  ---------------------------------------------------------------------------
  -- Respaldo. Antes de tocar: se guarda el estado de TODO lo que se cambia.
  ---------------------------------------------------------------------------
  create table if not exists public._penda_op3_backup (
    hecho_en    timestamptz default now(),
    que         text,
    session_id  uuid,
    code        text,
    item_id     uuid,
    valor_antes numeric,
    wh_antes    uuid
  );

  select id into v_win from public.physical_count_sessions
   where business_id = v_biz and code = 'PC-2026-000004';
  select id into v_ros from public.physical_count_sessions
   where business_id = v_biz and code = 'PC-2026-000005';

  ---------------------------------------------------------------------------
  -- 1. CONSOLIDAR Winnifer -> Rosayra
  ---------------------------------------------------------------------------
  v_n := 0;
  for r in
    select lw.item_id,
           lw.counted_quantity as qw,
           lr.counted_quantity as qr
      from public.physical_count_lines lw
      join public.physical_count_lines lr
        on lr.session_id = v_ros and lr.item_id = lw.item_id
     where lw.session_id = v_win
       and lw.counted_quantity is not null
       and lr.counted_quantity is not null
  loop
    insert into public._penda_op3_backup (que, session_id, code, item_id, valor_antes)
    values ('linea Winnifer', v_win, 'PC-2026-000004', r.item_id, r.qw),
           ('linea Rosayra',  v_ros, 'PC-2026-000005', r.item_id, r.qr);

    update public.physical_count_lines
       set counted_quantity = case when v_modo = 'sumar'
                                   then r.qr + r.qw
                                   else greatest(r.qr, r.qw) end
     where session_id = v_ros and item_id = r.item_id;

    -- La de Winnifer se vacia: ya esta contada del otro lado. No se borra
    -- la fila porque la sesion tiene una linea por cada insumo del catalogo.
    update public.physical_count_lines
       set counted_quantity = null
     where session_id = v_win and item_id = r.item_id;

    v_n := v_n + 1;
  end loop;
  raise notice 'Consolidados (modo %): % insumos que contaron las dos.', v_modo, v_n;

  ---------------------------------------------------------------------------
  -- 2. REAPUNTAR cada sesion a su almacen
  ---------------------------------------------------------------------------
  v_n := 0;
  for r in
    select s.id, s.code, s.warehouse_id as wh_antes, w.id as wh_nuevo, w.name
      from public.physical_count_sessions s
      join (values
              ('PC-2026-000002','Almacen Principal'),
              ('PC-2026-000003','Cocina'),
              ('PC-2026-000004','FoodShop'),
              ('PC-2026-000005','FoodShop'),
              ('PC-2026-000006','Bar')
           ) as m(code, destino) on m.code = s.code
      join public.warehouses w
        on w.business_id = v_biz and w.name = m.destino and coalesce(w.is_active,true)
     where s.business_id = v_biz
       and s.status in ('draft','in_progress')
       and s.warehouse_id is distinct from w.id
  loop
    insert into public._penda_op3_backup (que, session_id, code, wh_antes)
    values ('sesion reapuntada', r.id, r.code, r.wh_antes);

    update public.physical_count_sessions
       set warehouse_id = r.wh_nuevo
     where id = r.id;

    v_n := v_n + 1;
    raise notice 'Reapuntada % -> %', r.code, r.name;
  end loop;

  raise notice 'LISTO — % sesiones reapuntadas. NO se cerro ninguna.', v_n;
end
$$;


-- ─── VERIFICAR ───────────────────────────────────────────────────────────────
--   ESPERADO: cada sesion en su almacen, y CERO insumos contados dos veces
--   contra el mismo almacen.
select s.code,
       coalesce(s.notes,'')                                        as conteo,
       w.name                                                      as almacen,
       count(l.*) filter (where l.counted_quantity is not null)     as contadas
from public.physical_count_sessions s
join public.warehouses w on w.id = s.warehouse_id
left join public.physical_count_lines l on l.session_id = s.id
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.status in ('draft','in_progress')
group by s.code, s.notes, w.name
order by s.code;

-- Tiene que devolver CERO filas: ya no queda nada que se pise al cerrar.
select i.name,
       string_agg(s.code || '=' || l.counted_quantity, ' · ' order by s.code) as choque
from public.physical_count_lines l
join public.physical_count_sessions s on s.id = l.session_id
join public.inventory_items i on i.id = l.item_id
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.status in ('draft','in_progress')
  and l.counted_quantity is not null
group by i.name, s.warehouse_id
having count(*) > 1;


-- ─── DESHACER ────────────────────────────────────────────────────────────────
/*
do $$
declare r record;
begin
  for r in select * from public._penda_op3_backup order by hecho_en desc loop
    if r.que = 'sesion reapuntada' then
      update public.physical_count_sessions set warehouse_id = r.wh_antes where id = r.session_id;
    else
      update public.physical_count_lines set counted_quantity = r.valor_antes
       where session_id = r.session_id and item_id = r.item_id;
    end if;
  end loop;
  drop table public._penda_op3_backup;
  raise notice 'Deshecho.';
end $$;
*/

-- =============================================================================
-- El Nido: liberar las mesas trabadas (MODIFICA DATOS) — 2026-10-16
-- =============================================================================
-- Pedido del dueño (16-oct): «todas las mesas hay que liberarlas».
--
-- Anula, solo en El Nido - Mountain Coffee, las cuentas que vieron los
-- diagnósticos del 16-oct (review_el_nido_open_empty_tables.sql y
-- review_el_nido_followup_20261016.sql):
--   revision  4 cuentas en revisión con productos POR CONFIRMAR que un equipo
--             2.0.7 agregó a cuentas ya cobradas (MESA 7, MESA 4, 2DO NIVEL
--             Mesa 5, MESA 1). Motivo en order_review_events (resolved_void).
--   venta     la venta rápida quick#3 abandonada desde el 11/10 (2 productos
--             por confirmar, RD$713.90). Si NO se quiere anular, borrar su
--             línea en `objetivos`.
--   vacia     las cuentas vacías de esas mesas, TERRAZA - MESA 10 y el carril
--             quick.
--
-- CANDADOS (se re-verifican al correr; si algo cambió, esa cuenta se SALTA):
--   * misma sesión, y la sesión sigue abierta;
--   * la cuenta sigue abierta y SIN cobros (fn_void_order_if_unpaid lo exige
--     con la fila bloqueada);
--   * vacia: ningún producto vivo; revision/venta: solo productos por
--     confirmar (nada enviado a cocina) y ninguno agregado desde el 16/10;
--   * todo bajo el candado de la mesa (el mismo de fn_open_table).
-- La anulación es la de la app: fn_void_order_if_unpaid → fn_close_order_and_table,
-- que cierra la sesión y deja la mesa disponible cuando no queda cuenta viva.
-- Lo enviado a cocina no se toca. Nada de esto descontó inventario (nunca se
-- confirmó a cocina).
--
-- Correr con la operación tranquila (nadie dentro de esas mesas). La tabla final
-- muestra qué pasó con cada cuenta y cómo quedó cada mesa.
-- =============================================================================

drop table if exists pg_temp._limpieza_nido;
create temp table _limpieza_nido (
  mesa text, cuenta text, tipo text, resultado text
);

do $$
declare
  v_business constant uuid := 'd2aea1c8-f927-479c-9581-b236d6df3955';
  v_desde    constant timestamptz := '2026-10-16 00:00:00-04';
  v_motivo   constant text := 'Productos agregados por un equipo con app 2.0.7 a una cuenta ya cobrada; '
                              'anulado a pedido del dueño (16-oct-2026) para liberar la mesa';
  t          record;
  v_order    uuid;
  v_matches  int;
  v_table    uuid;
  v_mesa     text;
  v_open     boolean;
  v_bad      int;
  v_res      text;
begin
  for t in
    select *
      from (values
        -- sesión                                  cuenta      tipo
        ('e16b24eb-5681-4dba-b4b8-7e145a8bd37d'::uuid, '523b30e5', 'revision'), -- TERRAZA - MESA 7
        ('e16b24eb-5681-4dba-b4b8-7e145a8bd37d'::uuid, '3253e75e', 'vacia'),
        ('1387de18-cca9-4551-a841-d3ee4787b8f3'::uuid, 'f9e7c8d1', 'revision'), -- TERRAZA - MESA 4
        ('1387de18-cca9-4551-a841-d3ee4787b8f3'::uuid, '06ea1880', 'vacia'),
        ('b7e86d20-07a9-479c-8c1a-39d1c5d9df68'::uuid, '5cdd4255', 'revision'), -- 2DO NIVEL - Mesa 5
        ('b7e86d20-07a9-479c-8c1a-39d1c5d9df68'::uuid, 'b74a059f', 'vacia'),
        ('bd36597a-7323-48dd-85e6-3d6efe5d74ce'::uuid, 'b3c314d1', 'revision'), -- TERRAZA - MESA 1
        ('bd36597a-7323-48dd-85e6-3d6efe5d74ce'::uuid, '29e45e1f', 'vacia'),
        ('6ac25131-2c41-4ace-9210-c1df4067d2be'::uuid, 'a69ce627', 'vacia'),    -- TERRAZA - MESA 10
        ('026f9f76-163c-43c9-b39c-18c41239ab52'::uuid, '083bc787', 'vacia'),    -- quick
        ('cc05f05d-e695-4b29-a98e-4e39786c600e'::uuid, '9daddff0', 'venta')     -- quick#3
      ) as x(session_id, prefijo, tipo)
     order by session_id, case tipo when 'vacia' then 2 else 1 end
  loop
    -- Mesa y negocio de la sesión.
    select ts.table_id, dt.code, ts.closed_at is null
      into v_table, v_mesa, v_open
      from public.table_sessions ts
      join public.dining_tables dt on dt.id = ts.table_id
      join public.zones z on z.id = dt.zone_id
     where ts.id = t.session_id
       and coalesce(ts.business_id, z.business_id) = v_business;

    if v_table is null then
      insert into _limpieza_nido values (null, t.prefijo, t.tipo, 'SALTADA: la sesión no es de El Nido');
      continue;
    end if;

    -- Candado de la mesa ANTES de leer (mismo que fn_open_table y el barrido).
    perform pg_advisory_xact_lock(hashtextextended(v_table::text, 0));

    select count(*), min(o.id::text)::uuid
      into v_matches, v_order
      from public.orders o
     where o.session_id = t.session_id
       and o.id::text like t.prefijo || '%';

    if v_matches <> 1 then
      insert into _limpieza_nido values (v_mesa, t.prefijo, t.tipo,
        'SALTADA: ' || v_matches || ' cuentas con ese prefijo en la sesión');
      continue;
    end if;

    if exists (select 1 from public.orders o
                where o.id = v_order
                  and (o.closed_at is not null or o.status_ext::text in ('paid', 'void'))) then
      insert into _limpieza_nido values (v_mesa, t.prefijo, t.tipo, 'ya estaba cerrada');
      continue;
    end if;

    if t.tipo = 'vacia' then
      select count(*) into v_bad
        from public.order_items oi
       where oi.order_id = v_order
         and oi.status::text <> 'void';
      if v_bad > 0 then
        insert into _limpieza_nido values (v_mesa, t.prefijo, t.tipo,
          'SALTADA: ahora tiene ' || v_bad || ' producto(s); alguien está usando la mesa');
        continue;
      end if;
    else
      select count(*) into v_bad
        from public.order_items oi
       where oi.order_id = v_order
         and oi.status::text <> 'void'
         and (oi.status::text <> 'draft' or oi.created_at >= v_desde);
      if v_bad > 0 then
        insert into _limpieza_nido values (v_mesa, t.prefijo, t.tipo,
          'SALTADA: tiene ' || v_bad || ' producto(s) enviados a cocina o agregados hoy');
        continue;
      end if;
    end if;

    v_res := public.fn_void_order_if_unpaid(v_order);

    if v_res = 'voided' and t.tipo = 'revision' then
      insert into public.order_review_events (
        order_id, business_id, event, session_id, table_id, reason
      ) values (v_order, v_business, 'resolved_void', t.session_id, v_table, v_motivo);
    end if;

    insert into _limpieza_nido values (v_mesa, t.prefijo, t.tipo,
      case v_res
        when 'voided' then 'ANULADA'
        when 'has_payments' then 'SALTADA: tiene cobros'
        else 'SALTADA: ' || v_res
      end);
  end loop;
end $$;

-- Resultado: una fila por cuenta tratada + el estado final de cada mesa de El Nido
-- que siga abierta.
select 1 as n, mesa, cuenta, tipo, resultado
  from _limpieza_nido
union all
select 2, dt.code, null, 'MESA AÚN ABIERTA',
       'abierta desde ' || to_char(ts.opened_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI')
       || ' · cuentas vivas: ' || (select count(*) from public.orders o
                                    where o.session_id = ts.id and o.closed_at is null
                                      and o.status_ext::text not in ('paid', 'void'))
  from public.table_sessions ts
  join public.dining_tables dt on dt.id = ts.table_id
  join public.zones z on z.id = dt.zone_id
 where coalesce(ts.business_id, z.business_id) = 'd2aea1c8-f927-479c-9581-b236d6df3955'
   and ts.closed_at is null
 order by 1, 2, 3;

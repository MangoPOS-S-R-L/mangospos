-- CORRECCIÓN del cierre de LA PENDA EXPRESS del 02/10/2026 23:07.
--
-- Qué pasó: el dinero de la caja de eri@penda.com (1ce99958…, abierta 15:10,
-- 93 cobros) se contó a las 23:07, pero el conteo se firmó en OTRA caja que
-- pruebacaja@penda.com abrió a las 23:01 y que no tuvo ni un cobro. La de Eri
-- quedó abierta y la de pruebacaja salió con "sobrante" de 106,199.
--
-- Qué hace (todo o nada):
--   1. Cierra la caja de Eri con la hora y el conteo de las 23:07
--      (end_amount, notas y modo de cierre de la caja de pruebacaja), con la
--      diferencia de efectivo calculada como lo hace fn_close_cash_session.
--   2. Copia a la caja de Eri el conteo firmado (cash_count_blind). El
--      original NO se puede tocar (es inmutable después de firmarse) y se queda
--      donde está como evidencia.
--   3. Deja la caja de pruebacaja en cero (fondo, cierre y diferencia) con una
--      nota de ANULADA, para que Reportes no cuente dos fondos ni el sobrante
--      falso. No se borra.
--   4. Deja rastro en audit_logs (si la tabla no acepta la fila, sigue igual).
--
-- Se niega a hacer nada si: la caja de Eri ya no está abierta, le entraron
-- cobros después de las 23:07, la de pruebacaja no es exactamente una, tiene
-- cobros o movimientos, o su conteo no es 37,555.
do $$
declare
  c_eri    constant uuid := '1ce99958-b507-46ad-8518-801a5b46ede4';
  c_prueba_email constant text := 'pruebacaja@penda.com';
  v_eri    public.cash_register_sessions%rowtype;
  v_prueba public.cash_register_sessions%rowtype;
  v_eri_business    uuid;
  v_prueba_business uuid;
  v_n      int;
  v_expected numeric;
  v_cols   text;
  v_copied int := 0;
  v_note   text;
begin
  -- La caja de Eri, bloqueada mientras dura la corrección.
  select * into v_eri
  from public.cash_register_sessions
  where id = c_eri
  for update;
  if not found then
    raise exception 'No existe la caja %: no se hizo nada', c_eri;
  end if;
  if v_eri.status <> 'open' or v_eri.closed_at is not null then
    raise exception 'La caja de Eri ya no está abierta (status %, cerrada %): ¿ya se corrigió? No se hizo nada',
      v_eri.status, v_eri.closed_at;
  end if;

  -- La caja vacía de pruebacaja: abierta y cerrada esa noche. Debe ser UNA.
  select count(*) into v_n
  from public.cash_register_sessions s
  join auth.users u on u.id = s.user_id
  where lower(u.email) = c_prueba_email
    and s.opened_at >= timestamptz '2026-10-02 22:00-04'
    and s.closed_at between timestamptz '2026-10-02 22:00-04'
                        and timestamptz '2026-10-03 00:30-04';
  if v_n <> 1 then
    raise exception 'Se esperaba 1 caja de % abierta y cerrada esa noche y hay %: no se hizo nada',
      c_prueba_email, v_n;
  end if;

  select s.* into v_prueba
  from public.cash_register_sessions s
  join auth.users u on u.id = s.user_id
  where lower(u.email) = c_prueba_email
    and s.opened_at >= timestamptz '2026-10-02 22:00-04'
    and s.closed_at between timestamptz '2026-10-02 22:00-04'
                        and timestamptz '2026-10-03 00:30-04'
  for update of s;

  -- Mismo negocio.
  select business_id into v_eri_business
  from public.cash_registers where id = v_eri.cash_register_id;
  select business_id into v_prueba_business
  from public.cash_registers where id = v_prueba.cash_register_id;
  if v_eri_business is distinct from v_prueba_business then
    raise exception 'Las dos cajas son de negocios distintos: no se hizo nada';
  end if;

  -- El conteo de la caja de pruebacaja es el de la foto.
  if coalesce(v_prueba.end_amount, -1) <> 37555 then
    raise exception 'El conteo de la caja de pruebacaja es % y no 37,555: no es la caja de la foto. No se hizo nada',
      v_prueba.end_amount;
  end if;

  -- La caja de pruebacaja no tuvo cobros ni movimientos.
  if exists (select 1 from public.payments where session_id = v_prueba.id)
     or exists (select 1 from public.cash_transactions where session_id = v_prueba.id) then
    raise exception 'La caja de pruebacaja SÍ tiene cobros o movimientos: no se hizo nada';
  end if;

  -- A la caja de Eri no le entró nada después del conteo.
  if exists (select 1 from public.payments
             where session_id = c_eri and created_at > v_prueba.closed_at)
     or exists (select 1 from public.cash_transactions
                where session_id = c_eri and created_at > v_prueba.closed_at) then
    raise exception 'A la caja de Eri le entraron cobros o movimientos después de las 23:07: no se hizo nada';
  end if;

  if exists (select 1 from public.cash_count_blind where cash_register_session_id = c_eri) then
    raise exception 'La caja de Eri ya tiene un conteo firmado: no se hizo nada';
  end if;

  -- Efectivo esperado, misma fórmula que fn_get_cash_session_summary
  -- (fondo + ventas en efectivo no anuladas + depósitos − retiros − gastos).
  select coalesce(v_eri.start_amount, 0)
       + coalesce(sum(c.amount) filter (
           where c.type = 'sale'
             and not exists (select 1 from public.payments p
                             where p.order_id = c.related_order_id
                               and p.status in ('cancelled', 'void'))), 0)
       + coalesce(sum(c.amount) filter (where c.type = 'deposit'), 0)
       - coalesce(sum(c.amount) filter (where c.type = 'withdrawal'), 0)
       - coalesce(sum(c.amount) filter (where c.type = 'expense'), 0)
  into v_expected
  from public.cash_transactions c
  where c.session_id = c_eri;

  v_note := format(
    'CORRECCION 03/10: el conteo de las %s se firmo por error en la caja %s '
    '(%s, abierta %s, sin cobros); se traslado a esta caja via SQL',
    to_char(v_prueba.closed_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI'),
    v_prueba.id, c_prueba_email,
    to_char(v_prueba.opened_at at time zone 'America/Santo_Domingo', 'HH24:MI'));

  -- 1. Cerrar la caja de Eri con el conteo de las 23:07.
  update public.cash_register_sessions
  set status          = 'closed',
      closed_at       = v_prueba.closed_at,
      end_amount      = v_prueba.end_amount,
      difference      = v_prueba.end_amount - v_expected,
      notes           = concat_ws(' | ', nullif(trim(coalesce(v_prueba.notes, '')), ''), v_note),
      close_mode_used = v_prueba.close_mode_used
  where id = c_eri;

  -- 2. Copiar el conteo firmado (todas las columnas que existan en la BD viva,
  --    salvo las que cambian aquí).
  select string_agg(quote_ident(column_name), ', ' order by ordinal_position)
  into v_cols
  from information_schema.columns
  where table_schema = 'public' and table_name = 'cash_count_blind'
    and column_name not in ('id', 'cash_register_session_id', 'opening_float', 'supervisor_note')
    and is_generated = 'NEVER'
    and coalesce(is_identity, 'NO') = 'NO';

  execute format(
    'insert into public.cash_count_blind (cash_register_session_id, opening_float, supervisor_note, %1$s)
     select $1, $2, concat_ws('' | '', nullif(trim(coalesce(supervisor_note, '''')), ''''), $3), %1$s
     from public.cash_count_blind
     where cash_register_session_id = $4', v_cols)
  using c_eri, coalesce(v_eri.start_amount, 0), v_note, v_prueba.id;
  get diagnostics v_copied = row_count;

  -- 3. La caja de pruebacaja queda en cero y marcada. La nota NO repite
  --    "Efectivo:"/"Tarjeta:" con montos: Reportes los leería como reportado.
  update public.cash_register_sessions
  set start_amount = 0,
      end_amount   = 0,
      difference   = 0,
      notes        = format(
        'ANULADA 03/10: caja abierta por error a las %s sin cobros (fondo digitado %s). '
        'Su conteo pertenece a la caja %s de eri@penda.com y se traslado alli.',
        to_char(v_prueba.opened_at at time zone 'America/Santo_Domingo', 'HH24:MI'),
        coalesce(v_prueba.start_amount, 0), c_eri)
  where id = v_prueba.id;

  -- 4. Rastro de auditoría (tolerante: si audit_logs difiere, no tumba nada).
  begin
    insert into public.audit_logs (business_id, user_id, action, reason, ref_table, ref_id)
    values (v_eri_business, v_eri.user_id, 'cash_session_close_correction', v_note,
            'cash_register_sessions', c_eri);
  exception when others then
    raise notice 'No se pudo escribir en audit_logs (%); la corrección sí se hizo.', sqlerrm;
  end;

  raise notice 'OK: caja de Eri cerrada con % (esperado %, diferencia efectivo %); conteos copiados: %',
    v_prueba.end_amount, v_expected, v_prueba.end_amount - v_expected, v_copied;
end $$;

-- Resultado: las dos cajas como las va a ver Reportes y la reimpresión.
select
  u.email                                                                    as cajero,
  s.id                                                                       as caja,
  s.status,
  to_char(s.opened_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI') as abrio,
  to_char(s.closed_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI') as cerro,
  s.start_amount                                                             as fondo,
  (public.fn_get_cash_session_summary(s.id) ->> 'expected_cash')::numeric    as esperado_efectivo,
  s.end_amount                                                               as contado_efectivo,
  s.difference                                                               as dif_efectivo,
  (public.fn_get_cash_session_summary(s.id) ->> 'expected_card')::numeric    as esperado_tarjeta,
  (select b.card_amount from public.cash_count_blind b
    where b.cash_register_session_id = s.id
    order by b.attempt_number desc limit 1)                                  as contado_tarjeta,
  (public.fn_get_cash_session_summary(s.id) ->> 'transaction_count')::int    as transacciones,
  s.notes
from public.cash_register_sessions s
join auth.users u on u.id = s.user_id
where s.id = '1ce99958-b507-46ad-8518-801a5b46ede4'
   or (lower(u.email) = 'pruebacaja@penda.com'
       and s.opened_at >= timestamptz '2026-10-02 22:00-04'
       and s.opened_at <  timestamptz '2026-10-03 00:30-04')
order by s.opened_at;

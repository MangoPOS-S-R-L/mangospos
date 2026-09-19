-- =============================================================================
-- TRANSFERIR caja abierta de un usuario a otro, SIN cerrarla
-- Negocio: 6d13ed3f-0fb9-40e3-a695-f4c09759fbfd
--
-- Qué hace: cambia SOLO el dueño (cash_register_sessions.user_id) de la caja
-- abierta. Todo lo ya registrado se queda en la misma sesión, porque cobros
-- (payments), movimientos (cash_transactions) y abonos (credit_payments)
-- cuelgan del session_id, no del usuario, y el cierre suma por session_id.
-- Fondo, hora de apertura y equipo no se tocan. Cada cobro conserva quién lo
-- hizo (processed_by).
--
-- ANTES: correr DIAGNOSTICO_transferir_caja_6d13ed3f.sql. Las DOS líneas
-- marcadas con <<< aceptan un correo o un id: el id de la cuenta (auth.users)
-- o el id de la ficha de empleado (employees.id, se traduce a su cuenta).
--
-- 2026-09-18: de elprodigioenlaarena@gmail.com (dueño) a johan@arena.com
-- (Johan Osma, cashier; ficha de empleado 9606d43d → cuenta a5f77a1e).
--
-- Para DESHACER: correr este mismo script con origen y destino invertidos.
-- =============================================================================
do $$
declare
  c_business_id constant uuid := '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd';
  c_from        constant text := 'elprodigioenlaarena@gmail.com';          -- <<< quien tiene la caja hoy
  c_to          constant text := 'johan@arena.com';                        -- <<< quien la recibe (Johan Osma, cajero)

  v_inputs      text[] := array[trim(c_from), trim(c_to)];
  v_labels      text[] := array['ORIGEN', 'DESTINO'];
  v_ids         uuid[] := array[null, null]::uuid[];
  v_input       text;
  v_id          uuid;
  v_emp_found   boolean;

  v_from_id     uuid;
  v_to_id       uuid;
  v_from_email  text;
  v_to_email    text;
  v_session_id  uuid;
  v_register    text;
  v_count       int;
  v_blocking    text;
begin
  -- 1) Cuentas de origen y destino (la caja se amarra a auth.users).
  --    Acepta correo, id de cuenta o id de ficha de empleado de este negocio.
  for i in 1..2 loop
    v_input := v_inputs[i];
    v_id := null;

    if v_input ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      select u.id into v_id from auth.users u where u.id = v_input::uuid;

      if v_id is null then
        select true, e.user_id into v_emp_found, v_id
          from public.employees e
         where e.id = v_input::uuid
           and e.business_id = c_business_id;

        if v_emp_found and v_id is null then
          raise exception 'El % (%) es un empleado solo con PIN, sin usuario de acceso: no se le puede asignar caja.', v_labels[i], v_input;
        end if;
      end if;
    else
      select u.id into v_id from auth.users u where lower(u.email) = lower(v_input);
    end if;

    if v_id is null then
      raise exception 'No se encontró el % (%): no es un correo de cuenta, ni un id de cuenta, ni una ficha de empleado de este negocio.', v_labels[i], v_input;
    end if;

    v_ids[i] := v_id;
  end loop;

  v_from_id := v_ids[1];
  v_to_id   := v_ids[2];
  select email into v_from_email from auth.users where id = v_from_id;
  select email into v_to_email   from auth.users where id = v_to_id;

  if v_from_id = v_to_id then
    raise exception 'Origen y destino son el mismo usuario (%).', v_to_email;
  end if;

  -- 2) El destino debe tener acceso al negocio
  if not exists (select 1 from public.businesses b
                  where b.id = c_business_id and b.owner_id = v_to_id)
     and not exists (select 1 from public.user_businesses ub
                      where ub.business_id = c_business_id and ub.user_id = v_to_id) then
    raise exception '% no tiene acceso a este negocio. Agrégalo como usuario del negocio primero.', v_to_email;
  end if;

  -- 3) La caja abierta del origen en ESTE negocio (bloqueada contra un cierre simultáneo)
  select count(*) into v_count
    from public.cash_register_sessions s
    join public.cash_registers r on r.id = s.cash_register_id
   where r.business_id = c_business_id
     and s.user_id = v_from_id
     and s.status = 'open'
     and s.closed_at is null;

  if v_count = 0 then
    raise exception '% no tiene ninguna caja abierta en este negocio.', v_from_email;
  elsif v_count > 1 then
    raise exception '% tiene % cajas abiertas en este negocio; hay que indicar cuál transferir.', v_from_email, v_count;
  end if;

  select s.id, r.name into v_session_id, v_register
    from public.cash_register_sessions s
    join public.cash_registers r on r.id = s.cash_register_id
   where r.business_id = c_business_id
     and s.user_id = v_from_id
     and s.status = 'open'
     and s.closed_at is null
   for update of s;

  -- 4) El destino no puede tener otra caja abierta (una por usuario, en cualquier negocio)
  select string_agg(coalesce(b.business_name, '?') || ' / ' || coalesce(r.name, '?'), '; ')
    into v_blocking
    from public.cash_register_sessions s
    left join public.cash_registers r on r.id = s.cash_register_id
    left join public.businesses b on b.id = r.business_id
   where s.user_id = v_to_id
     and s.status = 'open'
     and s.closed_at is null;

  if v_blocking is not null then
    raise exception '% ya tiene una caja abierta (%). Debe cerrarla antes de recibir esta.', v_to_email, v_blocking;
  end if;

  -- 5) Transferir: solo cambia el dueño
  update public.cash_register_sessions
     set user_id = v_to_id
   where id = v_session_id
     and status = 'open'
     and closed_at is null;

  get diagnostics v_count = row_count;
  if v_count <> 1 then
    raise exception 'La caja cambió de estado mientras se transfería; no se tocó nada.';
  end if;

  -- 6) Rastro de auditoría. Si audit_logs difiere en esta BD, no tumba la transferencia.
  begin
    insert into public.audit_logs (business_id, user_id, action, reason, ref_table, ref_id)
    values (c_business_id, v_from_id, 'cash_session_transfer',
            format('Caja "%s" transferida de %s (%s) a %s (%s) por soporte vía SQL',
                   v_register, v_from_email, v_from_id, v_to_email, v_to_id),
            'cash_register_sessions', v_session_id);
  exception when others then
    raise notice 'No se pudo escribir en audit_logs (%); la transferencia sí se hizo.', sqlerrm;
  end;

  raise notice 'OK: caja "%" (sesión %) ahora es de %', v_register, v_session_id, v_to_email;
end $$;

-- Resultado: cómo quedaron las cajas abiertas del negocio
select s.id                                        as session_id,
       r.name                                      as caja,
       u.email                                     as dueno_actual,
       to_char(s.opened_at at time zone 'America/Santo_Domingo', 'DD/MM/YYYY HH24:MI') as abierta,
       s.start_amount                              as fondo,
       (select count(*) from public.payments py
         where py.session_id = s.id and py.status = 'completed')                     as cobros,
       (select coalesce(sum(py.amount), 0) from public.payments py
         where py.session_id = s.id and py.status = 'completed')                     as total_cobrado,
       (select count(*) from public.cash_transactions ct where ct.session_id = s.id) as movimientos
from public.cash_register_sessions s
join public.cash_registers r on r.id = s.cash_register_id
left join auth.users u on u.id = s.user_id
where r.business_id = '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'
  and s.status = 'open'
  and s.closed_at is null
order by s.opened_at;

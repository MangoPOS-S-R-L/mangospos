-- =============================================================================
-- 20261010_0009 — T07: estado durable de la emisión fiscal, también incierta
-- =============================================================================
--
-- PROBLEMA (emit-document + alanube_emit_outbox, revisados el 2026-10-10):
--   - Un envío a Alanube sin respuesta clara (tiempo agotado, red, 5xx, 409
--     «duplicado», o 2xx que no se pudo guardar) se trataba como «no enviado»:
--     se volvía a mandar a ciegas con el mismo e-NCF.
--   - Si ese reenvío choca («ya existe») o se agotan los intentos, el
--     comprobante quedaba 'rejected', aunque el primero pudo llegar a la DGII.
--     Y un 'rejected' no recibe nota de crédito al anular la venta.
--   - Una fila que quedó en 'processing' (función cortada a la mitad) no se
--     recuperaba nunca.
--
-- QUÉ HACE.
--   1. alanube_emit_outbox: estado 'uncertain' y columnas para saber QUÉ pasó
--      (send_started_at se guarda ANTES del POST; lease_expires_at, último
--      HTTP, resultado, respuesta cruda y la resolución).
--      fiscal_documents.ecf_status admite 'uncertain' (se conservan los demás
--      valores que tenga la base viva).
--   2. fn_alanube_outbox_recover_stale: 'processing' vencido → 'pending' si el
--      POST no llegó a salir (reenviar es seguro); → 'uncertain' si salió.
--   3. Lo incierto NUNCA se reenvía solo. Se resuelve:
--      - fn_alanube_adopt_uncertain: el webhook de Alanube trae el e-NCF
--        (documentNumber); si coincide con UN solo documento incierto, adopta
--        su id de Alanube y la emisión queda hecha.
--      - fn_resolve_uncertain_emission (dueño, admin o gerente):
--        found_in_alanube (con su id) o not_in_alanube (se reenvía con el
--        mismo e-NCF y la misma llave de idempotencia).
--   4. Un comprobante incierto no se anula hasta resolverlo: podría existir
--      ante la DGII y necesitar su nota de crédito.
--
-- Reintentar la emisión no toca cobros ni inventario: emit-document solo lee
-- la venta y escribe fiscal_documents/outbox (verificado en el código).
--
-- Va con la versión nueva de supabase/functions/emit-document y
-- alanube-webhook (publicarlas DESPUÉS de esta migración: usan sus columnas y
-- funciones). IDEMPOTENTE. Reversa: ..._ROLLBACK.sql.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Columnas y estados
-- ---------------------------------------------------------------------------
alter table public.alanube_emit_outbox
  add column if not exists send_started_at  timestamptz,
  add column if not exists lease_expires_at timestamptz,
  add column if not exists last_http_status integer,
  add column if not exists last_outcome     text,
  add column if not exists response         jsonb,
  add column if not exists resolution       text,
  add column if not exists resolution_note  text,
  add column if not exists resolved_by      uuid,
  add column if not exists resolved_at      timestamptz;

comment on column public.alanube_emit_outbox.send_started_at is
  'T07: se guarda justo ANTES del POST a Alanube. Con él, una respuesta perdida '
  'es incierta (pudo llegar); sin él, reenviar es seguro.';

-- Amplía un CHECK de valores conservando los que tenga la base viva.
create or replace function public.fn_tmp_widen_text_check(
  p_table regclass, p_column text, p_value text, p_default_name text)
returns void language plpgsql as $$
declare
  v_name   text;
  v_def    text;
  v_values text[];
begin
  select c.conname, pg_get_constraintdef(c.oid) into v_name, v_def
    from pg_constraint c
   where c.conrelid = p_table and c.contype = 'c'
     and pg_get_constraintdef(c.oid) ~ ('\m' || p_column || '\M')
   limit 1;
  if v_name is null then
    return;  -- sin CHECK: nada que ampliar
  end if;
  -- Valores sueltos ('pending'::text, …) o en arreglo ('{pending,sent}').
  select array_agg(distinct v) into v_values
    from regexp_matches(v_def, '''([^'']+)''', 'g') as m,
         unnest(case when m[1] like '{%}' then string_to_array(btrim(m[1], '{}'), ',')
                     else array[m[1]] end) as v;
  if p_value = any (coalesce(v_values, '{}')) then
    return;
  end if;
  execute format('alter table %s drop constraint %I', p_table, v_name);
  execute format('alter table %s add constraint %I check (%I = any (%L::text[]))',
                 p_table, coalesce(v_name, p_default_name), p_column,
                 coalesce(v_values, '{}') || p_value);
end $$;

select public.fn_tmp_widen_text_check('public.alanube_emit_outbox', 'status', 'uncertain',
                                      'alanube_emit_outbox_status_check');
select public.fn_tmp_widen_text_check('public.fiscal_documents', 'ecf_status', 'uncertain',
                                      'fiscal_documents_ecf_status_check');
drop function public.fn_tmp_widen_text_check(regclass, text, text, text);

create index if not exists idx_emit_outbox_uncertain
  on public.alanube_emit_outbox (business_id, updated_at)
  where status = 'uncertain';

-- ---------------------------------------------------------------------------
-- 2. Recuperar reclamos vencidos
-- ---------------------------------------------------------------------------
create or replace function public.fn_alanube_outbox_recover_stale(
  p_lease interval default interval '5 minutes'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pending   integer := 0;
  v_uncertain integer := 0;
begin
  with stale as (
    select o.id
      from public.alanube_emit_outbox o
     where o.status = 'processing'
       and coalesce(o.lease_expires_at, o.last_attempt_at + p_lease,
                    o.updated_at + p_lease) < now()
     for update skip locked
  ), moved as (
    update public.alanube_emit_outbox o
       set status = case when o.send_started_at is not null then 'uncertain' else 'pending' end,
           next_attempt_at = case when o.send_started_at is not null then null else now() end,
           last_outcome = case when o.send_started_at is not null
                               then 'claim_expired_after_send' else 'claim_expired_before_send' end,
           error = coalesce(o.error, 'La emisión se cortó a la mitad.')
      from stale
     where o.id = stale.id
    returning o.fiscal_document_id, o.status
  ), docs as (
    update public.fiscal_documents fd
       set ecf_status = 'uncertain',
           last_error = 'No se sabe si Alanube recibió este comprobante: se cortó '
                        'después de enviarlo. No se reenvía solo.'
      from moved
     where fd.id = moved.fiscal_document_id
       and moved.status = 'uncertain'
       and fd.alanube_document_id is null
    returning fd.id
  )
  select count(*) filter (where status = 'pending'),
         count(*) filter (where status = 'uncertain')
    into v_pending, v_uncertain
    from moved;
  return jsonb_build_object('to_pending', v_pending, 'to_uncertain', v_uncertain);
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Resolver lo incierto
-- ---------------------------------------------------------------------------
-- El webhook trae el e-NCF del documento: si coincide con UN solo documento
-- incierto sin id de Alanube, es ese (la respuesta del envío se perdió).
create or replace function public.fn_alanube_adopt_uncertain(
  p_ncf_number          text,
  p_alanube_document_id text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ids uuid[];
begin
  if coalesce(trim(p_ncf_number), '') = '' or coalesce(trim(p_alanube_document_id), '') = '' then
    return null;
  end if;
  select array_agg(fd.id) into v_ids
    from public.fiscal_documents fd
   where fd.ncf_number = trim(p_ncf_number)
     and fd.ecf_status = 'uncertain'
     and fd.alanube_document_id is null;
  if coalesce(cardinality(v_ids), 0) <> 1 then
    return null;  -- ninguno, o ambiguo (mismo e-NCF en dos negocios)
  end if;
  update public.fiscal_documents
     set alanube_document_id = trim(p_alanube_document_id),
         ecf_status = 'sent',
         submitted_at = coalesce(submitted_at, now()),
         last_error = null
   where id = v_ids[1];
  update public.alanube_emit_outbox
     set status = 'done', next_attempt_at = null, error = null,
         resolution = 'webhook_match', resolved_at = now()
   where fiscal_document_id = v_ids[1];
  return v_ids[1];
end;
$$;

create or replace function public.fn_resolve_uncertain_emission(
  p_fiscal_document_id  uuid,
  p_resolution          text,
  p_alanube_document_id text default null,
  p_note                text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_outbox public.alanube_emit_outbox%rowtype;
  v_role   text;
begin
  select * into v_outbox
    from public.alanube_emit_outbox
   where fiscal_document_id = p_fiscal_document_id
   for update;
  if not found then
    raise exception 'EMISSION_NOT_FOUND';
  end if;

  if coalesce(auth.role(), '') <> 'service_role'
     and not (session_user in ('postgres', 'supabase_admin') and nullif(auth.role(), '') is null) then
    v_role := public.user_business_role(auth.uid(), v_outbox.business_id);
    if coalesce(v_role, '') not in ('owner', 'admin', 'manager') then
      raise exception 'RESOLVE_DENIED: solo el dueño, un administrador o un gerente'
        using errcode = '42501';
    end if;
  end if;

  if v_outbox.status <> 'uncertain' then
    if v_outbox.resolution = p_resolution then
      return jsonb_build_object('status', v_outbox.status, 'resolution', p_resolution,
                                'replayed', true);
    end if;
    raise exception 'EMISSION_NOT_UNCERTAIN: %', v_outbox.status;
  end if;

  case p_resolution
    when 'found_in_alanube' then
      if coalesce(trim(p_alanube_document_id), '') = '' then
        raise exception 'ALANUBE_ID_REQUIRED';
      end if;
      update public.fiscal_documents
         set alanube_document_id = trim(p_alanube_document_id),
             ecf_status = 'sent',
             submitted_at = coalesce(submitted_at, now()),
             last_error = null
       where id = p_fiscal_document_id;
      update public.alanube_emit_outbox
         set status = 'done', next_attempt_at = null, error = null
       where id = v_outbox.id;
    when 'not_in_alanube' then
      -- Confirmado que Alanube no lo tiene: se reenvía con el MISMO e-NCF y la
      -- misma llave de idempotencia (el id del documento).
      update public.fiscal_documents
         set ecf_status = 'pending', last_error = null
       where id = p_fiscal_document_id;
      update public.alanube_emit_outbox
         set status = 'pending', next_attempt_at = now(), send_started_at = null,
             lease_expires_at = null, error = null
       where id = v_outbox.id;
    else
      raise exception 'RESOLUTION_UNKNOWN: %', p_resolution;
  end case;

  update public.alanube_emit_outbox
     set resolution = p_resolution,
         resolution_note = nullif(trim(coalesce(p_note, '')), ''),
         resolved_by = auth.uid(),
         resolved_at = now()
   where id = v_outbox.id;

  return jsonb_build_object('status', case when p_resolution = 'found_in_alanube'
                                           then 'done' else 'pending' end,
                            'resolution', p_resolution, 'replayed', false);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Un comprobante incierto no se anula hasta resolverlo
-- ---------------------------------------------------------------------------
create or replace function public.fn_guard_uncertain_ecf_cancel()
returns trigger
language plpgsql
as $$
begin
  if old.status = 'active' and new.status is distinct from old.status
     and coalesce(new.ecf_status, old.ecf_status) = 'uncertain' then
    raise exception 'ECF_UNCERTAIN: no se sabe si este comprobante electrónico llegó a '
                    'la DGII. Resuélvelo antes de anular la venta.'
      using errcode = 'MP440';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_zz_guard_uncertain_ecf_cancel on public.fiscal_documents;
create trigger trg_zz_guard_uncertain_ecf_cancel
  before update of status on public.fiscal_documents
  for each row execute function public.fn_guard_uncertain_ecf_cancel();

revoke all on function public.fn_alanube_outbox_recover_stale(interval) from public, anon, authenticated;
revoke all on function public.fn_alanube_adopt_uncertain(text, text) from public, anon, authenticated;
revoke all on function public.fn_resolve_uncertain_emission(uuid, text, text, text) from public, anon;
grant execute on function public.fn_alanube_outbox_recover_stale(interval) to service_role;
grant execute on function public.fn_alanube_adopt_uncertain(text, text) to service_role;
grant execute on function public.fn_resolve_uncertain_emission(uuid, text, text, text) to authenticated, service_role;

commit;

-- Reversa de 20261010_0009. Antes: volver a publicar la versión anterior de
-- emit-document y alanube-webhook (la nueva usa estas columnas y funciones).
-- Lo que quedó incierto pasa a 'failed' / ecf_status 'pending' con la nota:
-- revisarlo a mano en el portal de Alanube antes de reenviar nada.
begin;
update public.alanube_emit_outbox
   set status = 'failed',
       error = 'Incierto al revertir 20261010_0009: revisar en Alanube antes de reenviar.'
 where status = 'uncertain';
update public.fiscal_documents
   set ecf_status = 'pending',
       last_error = 'Incierto al revertir 20261010_0009: revisar en Alanube antes de reenviar.'
 where ecf_status = 'uncertain';

drop trigger if exists trg_zz_guard_uncertain_ecf_cancel on public.fiscal_documents;
drop function if exists public.fn_guard_uncertain_ecf_cancel();
drop function if exists public.fn_resolve_uncertain_emission(uuid, text, text, text);
drop function if exists public.fn_alanube_adopt_uncertain(text, text);
drop function if exists public.fn_alanube_outbox_recover_stale(interval);
drop index if exists public.idx_emit_outbox_uncertain;

create or replace function public.fn_tmp_narrow_text_check(
  p_table regclass, p_column text, p_value text)
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
    return;
  end if;
  -- Valores sueltos ('pending'::text, …) o en arreglo ('{pending,sent}').
  select array_agg(distinct v) into v_values
    from regexp_matches(v_def, '''([^'']+)''', 'g') as m,
         unnest(case when m[1] like '{%}' then string_to_array(btrim(m[1], '{}'), ',')
                     else array[m[1]] end) as v;
  if not (p_value = any (coalesce(v_values, '{}'))) then
    return;
  end if;
  execute format('alter table %s drop constraint %I', p_table, v_name);
  execute format('alter table %s add constraint %I check (%I = any (%L::text[]))',
                 p_table, v_name, p_column, array_remove(v_values, p_value));
end $$;
select public.fn_tmp_narrow_text_check('public.alanube_emit_outbox', 'status', 'uncertain');
select public.fn_tmp_narrow_text_check('public.fiscal_documents', 'ecf_status', 'uncertain');
drop function public.fn_tmp_narrow_text_check(regclass, text, text);

alter table public.alanube_emit_outbox
  drop column if exists send_started_at,
  drop column if exists lease_expires_at,
  drop column if exists last_http_status,
  drop column if exists last_outcome,
  drop column if exists response,
  drop column if exists resolution,
  drop column if exists resolution_note,
  drop column if exists resolved_by,
  drop column if exists resolved_at;
commit;

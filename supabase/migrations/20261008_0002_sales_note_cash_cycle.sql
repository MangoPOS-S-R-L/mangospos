-- Notas de venta: solo consumo (B02/E32) pagado completamente en efectivo.
-- Tras sales_note_limit notas, el siguiente consumo en efectivo es factura.
-- El contador es por negocio y cambia al emitir el documento, nunca al abrir
-- el modal ni con abonos. Una factura de consumo en efectivo reinicia el ciclo;
-- tarjeta, transferencia y crédito fiscal (B01/E31) no cambian el contador.
-- Conserva las funciones fiscales y de cobro VIVAS, incluyendo el NCF offline.
-- Aplicar después de 20260910_0001_sales_notes.sql. No reescribe documentos.

begin;

alter table public.business_settings
  add column if not exists sales_note_limit integer not null default 3,
  add column if not exists sales_note_count integer not null default 0;

alter table public.fiscal_documents
  add column if not exists sales_note_cycle_applied boolean not null default false;

do $$
begin
  if not exists (select 1 from pg_constraint
                 where conrelid = 'public.business_settings'::regclass
                   and conname = 'business_settings_sales_note_limit_positive') then
    alter table public.business_settings
      add constraint business_settings_sales_note_limit_positive
      check (sales_note_limit > 0);
  end if;
  if not exists (select 1 from pg_constraint
                 where conrelid = 'public.business_settings'::regclass
                   and conname = 'business_settings_sales_note_count_nonnegative') then
    alter table public.business_settings
      add constraint business_settings_sales_note_count_nonnegative
      check (sales_note_count >= 0);
  end if;
end;
$$;

comment on column public.business_settings.sales_note_limit is
  'Cantidad de notas de venta de consumo en efectivo antes de exigir factura (default 3).';
comment on column public.business_settings.sales_note_count is
  'Notas emitidas en el ciclo actual. Solo los triggers de documentos lo actualizan; una factura de consumo en efectivo lo reinicia.';
comment on column public.fiscal_documents.sales_note_cycle_applied is
  'Marca de idempotencia del ciclo de notas. Una factura preemitida con abonos solo reinicia el ciclo cuando su contenedor está cerrado y todos sus pagos son efectivo/consumo.';

-- El tipo y TODOS los métodos se resuelven de los pagos completados del scope.
-- Un abono con tarjeta hace fiscal todo el cobro, aunque el último sea efectivo.
-- La clasificación sigue los códigos DGII que usa el sistema: consumo B02/E32,
-- crédito fiscal B01/E31. NULL solicitado conserva el default fiscal del negocio.
create or replace function public.fn_sales_note_policy_scope(
  p_order_id uuid,
  p_check_id uuid default null
)
returns table (business_id uuid, eligible boolean, scope_closed boolean)
language sql
volatile
security definer
set search_path = public
as $$
  select
    coalesce(ts.business_id, z.business_id),
    coalesce(paid.eligible, false),
    case when p_check_id is null then o.closed_at is not null
         else coalesce(oc.is_closed, false) end
  from public.orders o
  left join public.table_sessions ts on ts.id = o.session_id
  left join public.dining_tables dt on dt.id = ts.table_id
  left join public.zones z on z.id = dt.zone_id
  left join public.order_checks oc
    on oc.id = p_check_id and oc.order_id = o.id
  left join lateral (
    select
      bool_and(coalesce(
        lower(trim(coalesce(pm.code, ''))) = 'cash'
        and p.business_id = coalesce(ts.business_id, z.business_id)
        and pm.business_id = coalesce(ts.business_id, z.business_id)
        and coalesce(p.requested_ncf_type, oc.requested_ncf_type,
                     fs.default_ncf_type,
                     case when coalesce(fs.ecf_enabled, false)
                          then 'E32'::public.ncf_type
                          else 'B02'::public.ncf_type end)
            in ('B02'::public.ncf_type, 'E32'::public.ncf_type)
      , false)) and count(distinct p.business_id) = 1 as eligible
    from public.payments p
    left join public.payment_methods pm on pm.id = p.payment_method_id
    left join public.fiscal_settings fs on fs.business_id = p.business_id
    where p.order_id = o.id
      and p.check_id is not distinct from p_check_id
      and p.status = 'completed'
  ) paid on true
  where o.id = p_order_id
    and (p_check_id is null or oc.id is not null)
    and not exists (
      select 1 from public.payments p
      left join public.payment_methods pm on pm.id = p.payment_method_id
      where p.order_id = o.id and p.check_id is not distinct from p_check_id
        and p.status = 'completed'
        and (p.business_id is distinct from coalesce(ts.business_id, z.business_id)
             or pm.business_id is distinct from coalesce(ts.business_id, z.business_id))
    );
$$;

-- Mantener el emisor de notas vivo sin copiar su implementación: el wrapper
-- añade autorización y candado ANTES del lookup idempotente y la numeración.
-- Usa el mismo advisory lock que la numeración original para evitar inversión
-- de candados con llamadas directas o cajas que cierran órdenes distintas.
do $$
begin
  if to_regprocedure('public.fn_issue_sales_note_unchecked(uuid,uuid)') is null then
    alter function public.fn_issue_sales_note(uuid, uuid)
      rename to fn_issue_sales_note_unchecked;
  end if;
end;
$$;

create or replace function public.fn_issue_sales_note(
  p_order_id uuid,
  p_check_id uuid default null
)
returns public.sales_notes
language plpgsql
security definer
set search_path = public
as $$
declare
  v_scope record;
  v_note public.sales_notes;
begin
  select * into v_scope
  from public.fn_sales_note_policy_scope(p_order_id, p_check_id);
  if not found or v_scope.business_id is null then
    raise exception 'SALES_NOTE_SCOPE_NOT_FOUND';
  end if;
  if not (coalesce(auth.role(), '') = 'service_role'
          or (session_user in ('postgres', 'supabase_admin')
              and nullif(auth.role(), '') is null)
          or coalesce(public.is_member_of_business(v_scope.business_id), false)) then
    raise exception 'UNAUTHORIZED_BUSINESS' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(
    hashtextextended(v_scope.business_id::text || ':sales_note_number', 0));
  select * into v_note from public.sales_notes sn
  where sn.order_id = p_order_id and sn.check_id is not distinct from p_check_id
    and sn.business_id = v_scope.business_id and sn.status = 'active';
  if found then return v_note; end if;
  if not v_scope.scope_closed or not v_scope.eligible then
    raise exception 'SALES_NOTE_REQUIRES_CASH_CONSUMER_FINAL';
  end if;
  return public.fn_issue_sales_note_unchecked(p_order_id, p_check_id);
end;
$$;

-- La factura obtiene el candado del ciclo ANTES de generate_ncf. Sin este
-- orden, una llamada fiscal directa podría retener ncf_sequences mientras
-- espera a una caja que ya retiene el ciclo y necesita generar ese NCF.
do $$
begin
  if to_regprocedure('public.issue_fiscal_document_unchecked(uuid,uuid)') is null then
    alter function public.issue_fiscal_document(uuid, uuid)
      rename to issue_fiscal_document_unchecked;
  end if;
end;
$$;

create or replace function public.issue_fiscal_document(
  _order_id uuid,
  _payment_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business_id uuid;
  v_check_id uuid;
  v_scope record;
begin
  select coalesce(ts.business_id, z.business_id) into v_business_id
  from public.payments p
  join public.orders o on o.id = p.order_id
  left join public.table_sessions ts on ts.id = o.session_id
  left join public.dining_tables dt on dt.id = ts.table_id
  left join public.zones z on z.id = dt.zone_id
  where p.id = _payment_id and p.order_id = _order_id
    and p.business_id = coalesce(ts.business_id, z.business_id);
  if v_business_id is null then
    raise exception 'NO_PAYMENTS_FOR_SCOPE';
  end if;
  select check_id into v_check_id from public.payments where id = _payment_id;
  select * into v_scope from public.fn_sales_note_policy_scope(_order_id, v_check_id);
  if not found or v_scope.business_id is distinct from v_business_id then
    raise exception 'SALES_DOCUMENT_BUSINESS_OUT_OF_SCOPE' using errcode = '42501';
  end if;
  if not (coalesce(auth.role(), '') = 'service_role'
          or (session_user in ('postgres', 'supabase_admin')
              and nullif(auth.role(), '') is null)
          or coalesce(public.is_member_of_business(v_business_id), false)) then
    raise exception 'UNAUTHORIZED_BUSINESS' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(
    hashtextextended(v_business_id::text || ':sales_note_number', 0));
  if exists (
    select 1 from public.payments p
    join public.sales_notes sn on sn.order_id = p.order_id
      and sn.check_id is not distinct from p.check_id and sn.status = 'active'
    where p.id = _payment_id
  ) then
    raise exception 'SALES_DOCUMENT_ALREADY_NOTED';
  end if;
  return public.issue_fiscal_document_unchecked(_order_id, _payment_id);
end;
$$;

-- create_fiscal_document reutiliza documentos antes de llamar al emisor.
-- Validar también esa entrada para que el lookup/reparación de una factura
-- existente tenga la misma autorización y alcance que una emisión nueva.
do $$
begin
  if to_regprocedure('public.create_fiscal_document_unchecked(uuid,uuid)') is null then
    alter function public.create_fiscal_document(uuid, uuid)
      rename to create_fiscal_document_unchecked;
  end if;
end;
$$;

create or replace function public.create_fiscal_document(
  p_order_id uuid,
  p_check_id uuid default null
)
returns public.fiscal_documents
language plpgsql
security definer
set search_path = public
as $$
declare v_scope record;
begin
  select * into v_scope from public.fn_sales_note_policy_scope(p_order_id, p_check_id);
  if not found or v_scope.business_id is null then
    raise exception 'SALES_DOCUMENT_BUSINESS_OUT_OF_SCOPE' using errcode = '42501';
  end if;
  if not (coalesce(auth.role(), '') = 'service_role'
          or (session_user in ('postgres', 'supabase_admin') and nullif(auth.role(), '') is null)
          or coalesce(public.is_member_of_business(v_scope.business_id), false)) then
    raise exception 'UNAUTHORIZED_BUSINESS' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(
    hashtextextended(v_scope.business_id::text || ':sales_note_number', 0));
  if exists (select 1 from public.sales_notes sn where sn.order_id = p_order_id
             and sn.check_id is not distinct from p_check_id and sn.status = 'active') then
    raise exception 'SALES_DOCUMENT_ALREADY_NOTED';
  end if;
  return public.create_fiscal_document_unchecked(p_order_id, p_check_id);
end;
$$;

-- Una inserción directa tampoco puede saltarse la elegibilidad o la cuota.
create or replace function public.fn_guard_sales_note_policy()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_scope record;
  v_settings public.business_settings;
begin
  select * into v_scope
  from public.fn_sales_note_policy_scope(new.order_id, new.check_id);
  if not found or v_scope.business_id is distinct from new.business_id
     or not coalesce(v_scope.scope_closed, false)
     or not coalesce(v_scope.eligible, false) then
    raise exception 'SALES_NOTE_REQUIRES_CASH_CONSUMER_FINAL';
  end if;
  if not (coalesce(auth.role(), '') = 'service_role'
          or (session_user in ('postgres', 'supabase_admin')
              and nullif(auth.role(), '') is null)
          or coalesce(public.is_member_of_business(new.business_id), false)) then
    raise exception 'UNAUTHORIZED_BUSINESS' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(
    hashtextextended(new.business_id::text || ':sales_note_number', 0));
  select * into v_settings from public.business_settings
  where business_id = new.business_id for update;
  if not coalesce(v_settings.sales_note_enabled, false) then
    raise exception 'SALES_NOTES_DISABLED';
  end if;
  if v_settings.sales_note_count >= v_settings.sales_note_limit then
    raise exception 'SALES_NOTE_LIMIT_REQUIRES_INVOICE';
  end if;
  if exists (
    select 1 from public.fiscal_documents fd
    where fd.order_id = new.order_id
      and fd.check_id is not distinct from new.check_id and fd.status = 'active'
      and fd.ncf_type::text not in ('B03', 'B04', 'E33', 'E34')
  ) then
    raise exception 'SALES_DOCUMENT_ALREADY_INVOICED';
  end if;
  return new;
end;
$$;

-- El camino fiscal también toma el mismo candado antes de insertar. Evita
-- crear una factura sobre una nota activa por una llamada directa al RPC.
create or replace function public.fn_guard_invoice_sale_document()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_scope record;
begin
  if new.ncf_type::text in ('B03', 'B04', 'E33', 'E34') then return new; end if;
  perform pg_advisory_xact_lock(
    hashtextextended(new.business_id::text || ':sales_note_number', 0));
  select * into v_scope
  from public.fn_sales_note_policy_scope(new.order_id, new.check_id);
  if not found or v_scope.business_id is distinct from new.business_id then
    raise exception 'SALES_DOCUMENT_BUSINESS_OUT_OF_SCOPE' using errcode = '42501';
  end if;
  if new.status = 'active' and exists (
    select 1 from public.sales_notes sn
    where sn.order_id = new.order_id
      and sn.check_id is not distinct from new.check_id and sn.status = 'active'
  ) then
    raise exception 'SALES_DOCUMENT_ALREADY_NOTED';
  end if;
  return new;
end;
$$;

-- Anular no devuelve cuota. Reactivar tampoco consume cuota, pero no puede
-- dejar una nota y una factura activas para el mismo contenedor.
create or replace function public.fn_guard_active_sale_document()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status <> 'active' then return new; end if;
  if tg_table_name = 'fiscal_documents' then
    if new.ncf_type::text in ('B03', 'B04', 'E33', 'E34') then return new; end if;
  end if;
  perform pg_advisory_xact_lock(
    hashtextextended(new.business_id::text || ':sales_note_number', 0));
  if tg_table_name = 'sales_notes' then
    if exists (select 1 from public.fiscal_documents fd where fd.order_id = new.order_id
               and fd.check_id is not distinct from new.check_id and fd.status = 'active'
               and fd.ncf_type::text not in ('B03', 'B04', 'E33', 'E34')) then
      raise exception 'SALES_DOCUMENT_ALREADY_INVOICED';
    end if;
  elsif exists (select 1 from public.sales_notes sn where sn.order_id = new.order_id
                and sn.check_id is not distinct from new.check_id and sn.status = 'active') then
    raise exception 'SALES_DOCUMENT_ALREADY_NOTED';
  end if;
  return new;
end;
$$;

-- Una factura emitida desde un abono puede existir antes del cierre. Se aplica
-- el ciclo una sola vez al cerrarse, sin anticiparlo ni repetirlo al reimprimir.
create or replace function public.fn_apply_sales_note_invoice_cycle(p_document_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_doc public.fiscal_documents;
  v_scope record;
begin
  select * into v_doc from public.fiscal_documents where id = p_document_id;
  if not found or v_doc.sales_note_cycle_applied or v_doc.status <> 'active'
     or v_doc.ncf_type not in ('B02'::public.ncf_type, 'E32'::public.ncf_type) then return; end if;
  perform pg_advisory_xact_lock(
    hashtextextended(v_doc.business_id::text || ':sales_note_number', 0));
  select * into v_doc from public.fiscal_documents where id = p_document_id for update;
  if v_doc.sales_note_cycle_applied then return; end if;
  select * into v_scope
  from public.fn_sales_note_policy_scope(v_doc.order_id, v_doc.check_id);
  if found and v_scope.business_id = v_doc.business_id
     and v_scope.eligible and v_scope.scope_closed then
    update public.fiscal_documents set sales_note_cycle_applied = true where id = v_doc.id;
    update public.business_settings set sales_note_count = 0
    where business_id = v_doc.business_id and sales_note_count <> 0;
  end if;
end;
$$;

-- Se contabilizan inserciones reales. Reimpresión, reintento, abono y anulación
-- no producen INSERT y no modifican el número de notas que ya se utilizaron.
create or replace function public.fn_account_sales_note_cycle()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_table_name = 'sales_notes' then
    perform pg_advisory_xact_lock(
      hashtextextended(new.business_id::text || ':sales_note_number', 0));
    update public.business_settings
    set sales_note_count = sales_note_count + 1
    where business_id = new.business_id;
  else
    perform public.fn_apply_sales_note_invoice_cycle(new.id);
  end if;
  return new;
end;
$$;

-- Un cliente puede guardar la cuota, pero no editar el progreso del ciclo.
-- Las escrituras desde los triggers de documentos tienen profundidad >= 2.
create or replace function public.fn_guard_sales_note_counter()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.sales_note_count is distinct from old.sales_note_count
     and pg_trigger_depth() < 2 then
    raise exception 'SALES_NOTE_COUNTER_READ_ONLY';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_sales_note_policy on public.sales_notes;
create trigger trg_guard_sales_note_policy before insert on public.sales_notes
  for each row execute function public.fn_guard_sales_note_policy();
drop trigger if exists trg_guard_invoice_sale_document on public.fiscal_documents;
create trigger trg_guard_invoice_sale_document before insert on public.fiscal_documents
  for each row execute function public.fn_guard_invoice_sale_document();
drop trigger if exists trg_guard_active_sale_document on public.sales_notes;
create trigger trg_guard_active_sale_document before update of status on public.sales_notes
  for each row execute function public.fn_guard_active_sale_document();
drop trigger if exists trg_guard_active_sale_document on public.fiscal_documents;
create trigger trg_guard_active_sale_document before update of status on public.fiscal_documents
  for each row execute function public.fn_guard_active_sale_document();
drop trigger if exists trg_account_sales_note_cycle on public.sales_notes;
create trigger trg_account_sales_note_cycle after insert on public.sales_notes
  for each row execute function public.fn_account_sales_note_cycle();
drop trigger if exists trg_account_sales_note_cycle on public.fiscal_documents;
create trigger trg_account_sales_note_cycle after insert on public.fiscal_documents
  for each row execute function public.fn_account_sales_note_cycle();
drop trigger if exists trg_guard_sales_note_counter on public.business_settings;
create trigger trg_guard_sales_note_counter
  before update of sales_note_count on public.business_settings
  for each row execute function public.fn_guard_sales_note_counter();

-- Resolver al cerrar, con los pagos definitivos y el contador bloqueado.
-- La preferencia del modal es una solicitud: si perdió la cuota ante otra caja
-- o hubo tarjeta/transferencia/crédito fiscal, se emite factura automáticamente.
create or replace function public.fn_issue_sale_document(
  p_order_id uuid,
  p_check_id uuid,
  p_sales_note_requested boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_scope record;
  v_settings public.business_settings;
  v_note boolean;
  v_document_id uuid;
begin
  select * into v_scope
  from public.fn_sales_note_policy_scope(p_order_id, p_check_id);
  if not found or v_scope.business_id is null then
    raise exception 'SALES_NOTE_SCOPE_NOT_FOUND';
  end if;
  perform pg_advisory_xact_lock(
    hashtextextended(v_scope.business_id::text || ':sales_note_number', 0));
  select * into v_settings from public.business_settings
  where business_id = v_scope.business_id for update;

  -- No cambiar de tipo ni volver a consumir cuota. Completar los links de
  -- abonos posteriores cuando ya había un documento, y sus montos definitivos.
  select sn.id into v_document_id from public.sales_notes sn where sn.order_id = p_order_id
    and sn.check_id is not distinct from p_check_id and sn.status = 'active';
  if found then
    update public.payments set sales_note_id = v_document_id
    where order_id = p_order_id and check_id is not distinct from p_check_id
      and status = 'completed' and sales_note_id is distinct from v_document_id;
    return;
  end if;
  select fd.id into v_document_id from public.fiscal_documents fd where fd.order_id = p_order_id
    and fd.check_id is not distinct from p_check_id and fd.status = 'active'
    and fd.ncf_type::text not in ('B03', 'B04', 'E33', 'E34');
  if found then
    perform public.create_fiscal_document(p_order_id, p_check_id);
    perform public.fn_recompute_fd_for_scope(v_document_id, p_order_id, p_check_id);
    perform public.fn_apply_sales_note_invoice_cycle(v_document_id);
    return;
  end if;

  v_note := coalesce(p_sales_note_requested, false)
    and coalesce(v_settings.sales_note_enabled, false)
    and v_scope.eligible
    and v_settings.sales_note_count < v_settings.sales_note_limit;

  if p_check_id is null then
    update public.orders set is_sales_note = v_note where id = p_order_id;
    update public.order_checks set is_sales_note = v_note
    where order_id = p_order_id and position = 1;
  else
    update public.order_checks set is_sales_note = v_note where id = p_check_id;
  end if;

  if v_note then
    perform public.fn_issue_sales_note(p_order_id, p_check_id);
  else
    perform public.create_fiscal_document(p_order_id, p_check_id);
  end if;
end;
$$;

create or replace function public.trg_fn_issue_fd_on_check_close()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.is_closed and not coalesce(old.is_closed, false) and new.position > 1
     and exists (select 1 from public.payments p
                 where p.check_id = new.id and p.status = 'completed') then
    perform public.fn_issue_sale_document(new.order_id, new.id, new.is_sales_note);
  end if;
  return new;
end;
$$;

create or replace function public.trg_fn_issue_fd_on_order_close()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.closed_at is not null and old.closed_at is null
     and exists (select 1 from public.payments p
                 where p.order_id = new.id and p.check_id is null and p.status = 'completed') then
    perform public.fn_issue_sale_document(new.id, null,
      new.is_sales_note or exists (select 1 from public.order_checks c
                                  where c.order_id = new.id and c.position = 1 and c.is_sales_note));
  end if;
  return new;
end;
$$;

revoke all on function public.fn_sales_note_policy_scope(uuid, uuid) from public, anon, authenticated;
revoke all on function public.fn_issue_sales_note_unchecked(uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function public.issue_fiscal_document_unchecked(uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function public.create_fiscal_document_unchecked(uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function public.fn_guard_sales_note_policy() from public, anon, authenticated;
revoke all on function public.fn_guard_invoice_sale_document() from public, anon, authenticated;
revoke all on function public.fn_guard_active_sale_document() from public, anon, authenticated;
revoke all on function public.fn_apply_sales_note_invoice_cycle(uuid) from public, anon, authenticated;
revoke all on function public.fn_account_sales_note_cycle() from public, anon, authenticated;
revoke all on function public.fn_guard_sales_note_counter() from public, anon, authenticated;
revoke all on function public.fn_issue_sale_document(uuid, uuid, boolean) from public, anon, authenticated;
revoke all on function public.fn_issue_sales_note(uuid, uuid) from public, anon;
grant execute on function public.fn_issue_sales_note(uuid, uuid) to authenticated, service_role;
revoke all on function public.issue_fiscal_document(uuid, uuid) from public, anon;
grant execute on function public.issue_fiscal_document(uuid, uuid) to authenticated, service_role;
revoke all on function public.create_fiscal_document(uuid, uuid) from public, anon;
grant execute on function public.create_fiscal_document(uuid, uuid) to authenticated, service_role;

commit;
notify pgrst, 'reload schema';

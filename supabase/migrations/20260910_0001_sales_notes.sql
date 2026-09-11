-- =============================================================================
-- 20260910_0001_sales_notes.sql
--
-- NOTA DE VENTA: documento de venta NO fiscal, numerado por negocio.
--
-- QUE ES:
--   Un papel que ampara una venta real (descuenta inventario, entra a caja,
--   suma en ventas) pero que NO es un comprobante fiscal: no consume NCF, no
--   se declara, no lleva RNC del negocio como emisor fiscal. El cliente que no
--   pide comprobante se lleva "NOTA DE VENTA No. NV-000123" en vez de una
--   factura con NCF quemado.
--
-- POR QUE HACE FALTA TOCAR LA BD:
--   Hoy el fiscal_document se emite en la BD, no en la app: al cerrar una
--   sub-cuenta (trg_issue_fd_on_check_close) o una orden
--   (trg_issue_fd_on_order_close) el trigger llama create_fiscal_document ->
--   issue_fiscal_document -> generate_ncf, que INCREMENTA ncf_sequences. Si el
--   desvio no vive ahi, toda nota de venta seguiria quemando un NCF y
--   apareceria en el 607. No hay forma app-side de evitarlo.
--
-- POR QUE NO ENTRA A fiscal_documents:
--   De esa tabla salen el reporte fiscal, el 607 y el anclaje de impuestos de
--   `analytics` ([[project_tax_report_config_driven_split]]). Meter ahi un
--   documento sin valor fiscal ensucia lo que se le declara a la DGII. La nota
--   vive en su propia tabla; la VENTA sigue contandose por payments /
--   cash_transactions / orders, que es por donde van ventas y cierre de caja.
--
-- COMO SE MARCA:
--   `orders.is_sales_note` (y `order_checks.is_sales_note` para split bill).
--   La app las setea ANTES de cobrar; el trigger de cierre las lee. No se toca
--   fn_process_payment_v3 ni issue_fiscal_document — las dos funciones mas
--   sensibles y mas divergentes del repo quedan intactas.
--
-- ⚠️  ANTES DE APLICAR: la BD viva diverge de las migraciones del repo
--   ([[project_db_diverges_from_repo_migrations]]). Los cuerpos de
--   trg_fn_issue_fd_on_check_close y trg_fn_issue_fd_on_order_close de abajo
--   son copia de 20260513_0002_fd_per_container.sql MAS el guard. Verifica
--   primero que el vivo sea igual:
--
--     select pg_get_functiondef('public.trg_fn_issue_fd_on_check_close()'::regprocedure);
--     select pg_get_functiondef('public.trg_fn_issue_fd_on_order_close()'::regprocedure);
--
--   Si difieren, agrega SOLO el bloque marcado "GUARD NOTA DE VENTA" al cuerpo
--   vivo en vez de correr este CREATE OR REPLACE tal cual.
--
-- REQUIERE POSTGRES 15+: la vista `sales_documents` se crea con
--   `security_invoker = on` para que herede el RLS de las tablas base en vez
--   de saltarselo. En PG14 esa opcion no existe y el CREATE VIEW falla.
--   Verifica antes:  select current_setting('server_version_num')::int >= 150000;
--   Si el servidor fuera PG14, NO quites la opcion: la vista quedaria leyendo
--   con los permisos del owner y expondria documentos de otros negocios.
--
-- IDEMPOTENTE: si (add column if not exists, create table if not exists,
--   create or replace, unique parcial por scope).
-- REVERSIBLE: si, ver _ROLLBACK.
-- EFECTO EN NEGOCIOS QUE NO LA USEN: NINGUNO. `sales_note_enabled` arranca en
--   false y `is_sales_note` en false: el guard nunca entra y el camino fiscal
--   queda byte por byte igual al de hoy.
-- =============================================================================

begin;

-- 1. Flags del negocio --------------------------------------------------------
-- Viven en business_settings, que es de donde la app ya lee sus features con
-- cache local (PosSettingsRepository), asi que el flag funciona offline.

alter table public.business_settings
  add column if not exists sales_note_enabled boolean default false;

alter table public.business_settings
  add column if not exists sales_note_prefix text default 'NV-';

alter table public.business_settings
  add column if not exists sales_note_default boolean default false;

comment on column public.business_settings.sales_note_enabled is
  'Habilita "Nota de venta" como documento elegible en el cobro. En false '
  '(default) el POS se comporta exactamente como antes: todo cobro emite NCF.';

comment on column public.business_settings.sales_note_prefix is
  'Prefijo del correlativo de notas de venta (default NV-). Solo cosmetico: '
  'la serie se calcula sobre los digitos, asi que cambiarlo no la reinicia.';

comment on column public.business_settings.sales_note_default is
  'Si true, el cobro arranca preseleccionado en Nota de venta en vez del NCF '
  'por defecto del negocio. El cajero puede cambiarlo en el modal.';

-- 2. Marca del scope ----------------------------------------------------------
-- El scope es el mismo que el de fiscal_documents: la sub-cuenta si el cobro
-- es por check, la orden completa si no. Por eso la marca va en las dos.

alter table public.orders
  add column if not exists is_sales_note boolean not null default false;

alter table public.order_checks
  add column if not exists is_sales_note boolean not null default false;

comment on column public.orders.is_sales_note is
  'true = al cerrar, esta orden emite NOTA DE VENTA (no fiscal) en vez de '
  'fiscal_document con NCF. La setea la app antes de cobrar.';

comment on column public.order_checks.is_sales_note is
  'Igual que orders.is_sales_note pero por sub-cuenta (split bill): una mesa '
  'puede cerrar una sub-cuenta con NCF y otra con nota de venta.';

-- 3. Tabla de notas de venta --------------------------------------------------

create table if not exists public.sales_notes (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  order_id uuid not null references public.orders(id) on delete cascade,
  -- NULL = nota de la orden completa; NOT NULL = de esa sub-cuenta.
  check_id uuid references public.order_checks(id) on delete set null,
  note_number text not null,
  -- Pago representativo del contenedor, igual que fiscal_documents.payment_id.
  -- Es el ancla de las acciones del historial (reimprimir, anular).
  payment_id uuid references public.payments(id) on delete set null,
  customer_id uuid references public.customers(id) on delete set null,
  customer_name text not null default 'Consumidor Final',
  customer_rnc text,
  subtotal numeric(12,2) not null default 0,
  discount numeric(12,2) not null default 0,
  tax numeric(12,2) not null default 0,
  service_fee numeric(12,2) not null default 0,
  tip numeric(12,2) not null default 0,
  total numeric(12,2) not null default 0,
  status text not null default 'active',
  cancelled_at timestamptz,
  cancelled_by uuid,
  cancellation_reason text,
  issued_by uuid,
  issued_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  constraint sales_notes_status_check
    check (status in ('active', 'cancelled')),
  constraint sales_notes_number_unique
    unique (business_id, note_number)
);

comment on table public.sales_notes is
  'Notas de venta: documento de venta NO fiscal, correlativo por negocio. Una '
  'por contenedor cobrado (sub-cuenta u orden), igual que fiscal_documents. '
  'NO se declara a la DGII y NO entra al 607 — para eso esta fiscal_documents.';

-- Mismo invariante que fiscal_documents: 1 documento activo por contenedor.
-- Bloquea fisicamente el duplicado si un trigger se re-dispara.
create unique index if not exists idx_sales_notes_unique_active_per_scope
  on public.sales_notes (
    order_id,
    coalesce(check_id, '00000000-0000-0000-0000-000000000000'::uuid)
  )
  where status = 'active';

create index if not exists idx_sales_notes_business_issued
  on public.sales_notes (business_id, issued_at desc);

create index if not exists idx_sales_notes_order
  on public.sales_notes (order_id);

alter table public.sales_notes enable row level security;

drop policy if exists "sales_notes_select" on public.sales_notes;
create policy "sales_notes_select" on public.sales_notes
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

-- La emision va por fn_issue_sales_note (SECURITY DEFINER), asi que esta
-- policy solo cubre correcciones manuales y la anulacion.
drop policy if exists "sales_notes_write" on public.sales_notes;
create policy "sales_notes_write" on public.sales_notes
  to authenticated
  using (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner', 'admin', 'manager'])
  )
  with check (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner', 'admin', 'manager'])
  );

-- 4. Enlace desde el pago ------------------------------------------------------
-- Espejo de payments.fiscal_document_id. El historial de ventas agrupa los
-- pagos de un documento por esta columna; sin ella una nota cobrada con dos
-- métodos no podría mostrar "Mixto" ni anclar la reimpresión.

alter table public.payments
  add column if not exists sales_note_id uuid
    references public.sales_notes(id) on delete set null;

create index if not exists idx_payments_sales_note
  on public.payments (sales_note_id)
  where sales_note_id is not null;

comment on column public.payments.sales_note_id is
  'Nota de venta que ampara este pago. Excluyente con fiscal_document_id: un '
  'pago se documenta con NCF o con nota, nunca con los dos.';

-- 5. Vista unificada para el historial ----------------------------------------
-- El historial de ventas leía `fiscal_documents` directo, así que una venta
-- documentada con nota no aparecía en pantalla: ni verla, ni reimprimirla.
-- Esta vista expone las DOS fuentes con la misma forma de fila y agrega
-- `doc_kind` para que la UI sepa cuál es cuál.
--
-- security_invoker: la vista se evalúa con los permisos de QUIEN consulta, así
-- que hereda el RLS de fiscal_documents y sales_notes en vez de saltárselo.

create or replace view public.sales_documents
with (security_invoker = on) as
  select
    fd.id,
    fd.business_id,
    fd.order_id,
    fd.payment_id,
    fd.check_id,
    fd.ncf_number,
    fd.ncf_type::text                  as ncf_type,
    fd.customer_name,
    fd.customer_rnc,
    coalesce(fd.subtotal, 0)           as subtotal,
    coalesce(fd.taxable_amount, 0)     as taxable_amount,
    coalesce(fd.itbis_amount, 0)       as itbis_amount,
    coalesce(fd.service_fee, 0)        as service_fee,
    coalesce(fd.total, 0)              as total,
    fd.status,
    fd.ecf_status,
    coalesce(fd.is_electronic, false)  as is_electronic,
    fd.created_at,
    'fiscal'::text                     as doc_kind
  from public.fiscal_documents fd
  union all
  select
    sn.id,
    sn.business_id,
    sn.order_id,
    sn.payment_id,
    sn.check_id,
    sn.note_number                     as ncf_number,
    -- 'NV' NO es un código DGII: es la marca interna de "nota de venta". La
    -- app la traduce a "Nota de Venta" en el catálogo de tipos.
    'NV'::text                         as ncf_type,
    sn.customer_name,
    sn.customer_rnc,
    sn.subtotal,
    -- Una nota no declara, pero sí cobró impuesto: el desglose se conserva
    -- para que el ticket y el detalle cuadren igual que una factura.
    sn.subtotal                        as taxable_amount,
    sn.tax                             as itbis_amount,
    sn.service_fee,
    sn.total,
    sn.status,
    null::text                         as ecf_status,
    false                              as is_electronic,
    sn.created_at,
    'sales_note'::text                 as doc_kind
  from public.sales_notes sn;

comment on view public.sales_documents is
  'Documentos de venta del negocio: comprobantes fiscales + notas de venta, '
  'con la misma forma de fila. `doc_kind` distingue cuál es cuál. Es la fuente '
  'del historial de ventas. Para el 607 y el reporte fiscal se usa '
  'fiscal_documents directo — las notas NO se declaran.';

grant select on public.sales_documents to authenticated, service_role;

-- 6. Emision ------------------------------------------------------------------

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
  v_note public.sales_notes;
  v_business_id uuid;
  v_prefix text;
  v_seq bigint;
  v_number text;
  v_order record;
  v_payment record;
  v_customer_id uuid;
  v_customer_rnc text;
  v_customer_name text;
  v_scope_total numeric(12,2);
  v_base_subtotal numeric(12,2);
  v_base_tax numeric(12,2);
  v_base_service_fee numeric(12,2);
  v_base_discount numeric(12,2);
  v_base_total numeric(12,2);
  v_ratio numeric(12,8);
begin
  -- Idempotencia por scope: mismo contrato que create_fiscal_document.
  select * into v_note
  from public.sales_notes sn
  where sn.order_id = p_order_id
    and sn.check_id is not distinct from p_check_id
    and sn.status = 'active'
  order by sn.created_at desc
  limit 1;

  if found then
    return v_note;
  end if;

  select * into v_order from public.orders where id = p_order_id;
  if not found then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  -- Pago representativo del scope: de ahi salen business_id y cliente.
  select p.* into v_payment
  from public.payments p
  where p.order_id = p_order_id
    and p.status = 'completed'
    and p.check_id is not distinct from p_check_id
  order by p.created_at asc
  limit 1;

  if v_payment.id is null then
    raise exception 'NO_PAYMENTS_FOR_SCOPE: order=% check=%',
      p_order_id, p_check_id;
  end if;

  v_business_id := v_payment.business_id;

  if v_business_id is null then
    select ts.business_id into v_business_id
    from public.table_sessions ts
    where ts.id = v_order.session_id;
  end if;

  if v_business_id is null then
    raise exception 'BUSINESS_NOT_RESOLVED';
  end if;

  -- Cliente: mismo orden de resolucion que issue_fiscal_document.
  select
    coalesce(v_payment.customer_id, c.id),
    coalesce(
      nullif(trim(coalesce(v_payment.customer_rnc, '')), ''),
      nullif(trim(coalesce(c.tax_id, '')), '')
    ),
    coalesce(
      nullif(trim(coalesce(ts.customer_name, '')), ''),
      nullif(trim(coalesce(c.name, '')), ''),
      'Consumidor Final'
    )
    into v_customer_id, v_customer_rnc, v_customer_name
  from public.table_sessions ts
  left join public.customers c
    on c.id = coalesce(v_payment.customer_id, ts.customer_id)
  where ts.id = v_order.session_id
  limit 1;

  v_customer_name := coalesce(v_customer_name, 'Consumidor Final');

  -- Montos: total = lo que entro NETO de cambio; desglose prorrateado sobre
  -- los totales del contenedor. Misma regla que fn_recompute_fd_for_scope,
  -- para que una nota y una factura del mismo consumo cuadren igual.
  select coalesce(sum(p.amount - coalesce(p.change_amount, 0)), 0)
    into v_scope_total
  from public.payments p
  where p.order_id = p_order_id
    and p.status = 'completed'
    and p.check_id is not distinct from p_check_id;

  if p_check_id is not null then
    select coalesce(oc.subtotal, 0), coalesce(oc.tax, 0),
           coalesce(oc.service_fee, 0), coalesce(oc.discounts, 0),
           coalesce(oc.total, 0)
      into v_base_subtotal, v_base_tax, v_base_service_fee,
           v_base_discount, v_base_total
    from public.order_checks oc
    where oc.id = p_check_id;
  else
    select coalesce(o.subtotal, 0), coalesce(o.tax, 0),
           coalesce(o.service_fee, 0), coalesce(o.discounts, 0),
           coalesce(o.total, 0)
      into v_base_subtotal, v_base_tax, v_base_service_fee,
           v_base_discount, v_base_total
    from public.orders o
    where o.id = p_order_id;
  end if;

  if coalesce(v_base_total, 0) > 0 then
    v_ratio := v_scope_total / v_base_total;
  else
    v_ratio := 1;
  end if;

  -- Numeracion: lock propio por negocio, igual que el conduce de recepcion.
  -- El cast va ADENTRO del max para que 'NV-000100' no pierda contra
  -- 'NV-000099' comparado como texto.
  perform pg_advisory_xact_lock(
    hashtextextended(v_business_id::text || ':sales_note_number', 0));

  select coalesce(nullif(trim(bs.sales_note_prefix), ''), 'NV-')
    into v_prefix
  from public.business_settings bs
  where bs.business_id = v_business_id;
  v_prefix := coalesce(v_prefix, 'NV-');

  select coalesce(
           max(nullif(regexp_replace(sn.note_number, '\D', '', 'g'), '')::bigint),
           0) + 1
    into v_seq
  from public.sales_notes sn
  where sn.business_id = v_business_id;

  v_number := v_prefix || lpad(v_seq::text, 6, '0');

  insert into public.sales_notes (
    business_id, order_id, check_id, note_number, payment_id,
    customer_id, customer_name, customer_rnc,
    subtotal, discount, tax, service_fee, total,
    issued_by, issued_at
  ) values (
    v_business_id, p_order_id, p_check_id, v_number, v_payment.id,
    v_customer_id, v_customer_name, v_customer_rnc,
    round(v_base_subtotal * v_ratio, 2),
    round(v_base_discount * v_ratio, 2),
    round(v_base_tax * v_ratio, 2),
    round(v_base_service_fee * v_ratio, 2),
    v_scope_total,
    coalesce(v_payment.processed_by, auth.uid()),
    coalesce(v_payment.created_at, now())
  )
  returning * into v_note;

  -- Enlazar TODOS los pagos del contenedor, no solo el representativo: es lo
  -- que hace create_fiscal_document y de ahí sale el "Mixto (Efectivo +
  -- Tarjeta)" del historial.
  update public.payments p
  set sales_note_id = v_note.id
  where p.order_id = p_order_id
    and p.status = 'completed'
    and p.check_id is not distinct from p_check_id
    and p.sales_note_id is distinct from v_note.id;

  return v_note;
end;
$$;

grant execute on function public.fn_issue_sales_note(uuid, uuid)
  to authenticated, service_role;

comment on function public.fn_issue_sales_note(uuid, uuid) is
  'Emite la NOTA DE VENTA (documento no fiscal) de un contenedor cobrado. '
  'Idempotente por (order_id, check_id) activo. No toca ncf_sequences ni '
  'fiscal_documents.';

-- 7. Guard en los triggers de cierre -----------------------------------------
-- Copia de 20260513_0002_fd_per_container.sql + el bloque GUARD. Ver la
-- advertencia del encabezado antes de correr.

create or replace function public.trg_fn_issue_fd_on_check_close()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Solo cuando una sub-cuenta (position > 1) pasa de abierta a cerrada.
  -- El principal (position=1) no genera fd por si mismo; ese caso lo
  -- maneja el trigger de orders.
  if new.is_closed = true
     and (old.is_closed is null or old.is_closed = false)
     and new.position > 1 then
    -- Solo emitir si hay al menos 1 payment completed para este check.
    if exists (
      select 1 from public.payments
      where check_id = new.id and status = 'completed'
    ) then
      -- ── GUARD NOTA DE VENTA ────────────────────────────────────────────
      -- La sub-cuenta manda; si no trae marca propia, hereda la de la orden
      -- (cobro normal donde la eleccion se hizo a nivel orden).
      if coalesce(
           new.is_sales_note,
           (select o.is_sales_note from public.orders o where o.id = new.order_id),
           false
         ) then
        perform public.fn_issue_sales_note(new.order_id, new.id);
        return new;
      end if;
      -- ── fin GUARD; camino fiscal intacto abajo ─────────────────────────
      perform public.create_fiscal_document(new.order_id, new.id);
    end if;
  end if;
  return new;
end;
$$;

create or replace function public.trg_fn_issue_fd_on_order_close()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_has_subchecks boolean;
begin
  -- Solo cuando una orden pasa de abierta a cerrada.
  if new.closed_at is not null
     and old.closed_at is null then

    -- Si la orden tiene sub-cuentas (position > 1), los fds ya fueron
    -- emitidos por trg_issue_fd_on_check_close cuando esas se cerraron.
    -- Skip a nivel orden para no duplicar.
    select exists (
      select 1 from public.order_checks
      where order_id = new.id and position > 1
    ) into v_has_subchecks;

    if not v_has_subchecks then
      -- Full-order: emitir fd con check_id NULL.
      if exists (
        select 1 from public.payments
        where order_id = new.id and check_id is null and status = 'completed'
      ) then
        -- ── GUARD NOTA DE VENTA ──────────────────────────────────────────
        -- Mira TAMBIEN los checks marcados, no solo la orden. El check
        -- principal (position = 1) no emite por el trigger de order_checks —
        -- ese solo actua sobre position > 1 — asi que su documento sale por
        -- ACA. Cobrar ese check con nota de venta marca `order_checks`, y sin
        -- este exists el guard no lo veia: la venta salia con NCF quemado.
        -- Dentro de esta rama no hay sub-cuentas (v_has_subchecks es false),
        -- asi que cualquier check marcado es el principal.
        if coalesce(new.is_sales_note, false)
           or exists (
                select 1 from public.order_checks c
                where c.order_id = new.id
                  and c.is_sales_note = true
              )
        then
          perform public.fn_issue_sales_note(new.id, null);
          return new;
        end if;
        -- ── fin GUARD; camino fiscal intacto abajo ───────────────────────
        perform public.create_fiscal_document(new.id, null);
      end if;
    end if;
  end if;
  return new;
end;
$$;

commit;

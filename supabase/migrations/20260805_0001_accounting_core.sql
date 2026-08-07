-- =============================================================================
-- Módulo de Contabilidad — Fase 1: núcleo de partida doble.
--
-- QUÉ AGREGA:
--   - Catálogo de cuentas jerárquico y configurable por negocio.
--   - Centros de costo / departamentos / proyectos / sucursales.
--   - Períodos contables con apertura, cierre y bloqueo.
--   - Asientos + líneas, con validación débitos = créditos, numeración
--     correlativa por negocio, inmutabilidad una vez posteados y reversión
--     por asiento espejo (nunca se borra el original).
--   - Mapeo evento → cuenta (`accounting_account_mappings`), que es lo que
--     hace configurables los asientos automáticos sin tocar código.
--   - Generadores automáticos IDEMPOTENTES desde los documentos que ya
--     existen: ventas del día, compras recibidas, gastos/retiros de caja y
--     abonos/pagos de crédito.
--   - Reportes: libro diario, libro mayor, balanza de comprobación, estado
--     de resultados y balance general.
--
-- QUÉ NO TOCA (a propósito):
--   Ni `payments`, ni `orders`, ni `fn_process_payment_v3`, ni ninguna
--   función fiscal. No hay triggers contables en el camino crítico del POS:
--   los asientos se generan por lote desde la pantalla de Contabilidad. Si
--   el motor contable falla, el cajero sigue cobrando. La única columna
--   agregada a una tabla existente es `cash_transaction_reasons
--   .accounting_account_id` (nullable), para que un gasto de caja pueda caer
--   en su cuenta correcta.
--
-- IDEMPOTENTE: create table if not exists / create or replace / drop if exists.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0. Helper de autorización
--
-- owner/admin pasan por rol. Cualquier otro rol necesita el permiso granular
-- de la app. `user_has_business_permission` la crea la migración
-- 20260803_0001; si todavía no está aplicada, el bloque la ignora y solo
-- pasan owner/admin (degradación segura, nunca se abre de más).
-- ---------------------------------------------------------------------------

create or replace function public.fn_accounting_can(
  p_business_id uuid,
  p_permission  text
) returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_role text;
begin
  if auth.uid() is null or p_business_id is null then
    return false;
  end if;
  if not public.user_has_business_access(auth.uid(), p_business_id) then
    return false;
  end if;

  begin
    v_role := public.user_business_role(auth.uid(), p_business_id);
  exception when others then
    v_role := null;
  end;
  if v_role in ('owner', 'admin') then
    return true;
  end if;

  begin
    if public.user_has_business_permission(p_business_id, p_permission) then
      return true;
    end if;
  exception when undefined_function then
    null;
  end;

  return false;
end;
$$;

comment on function public.fn_accounting_can(uuid, text) is
  'Autorización del módulo contable: owner/admin por rol, el resto por '
  'permiso granular de la app (contabilidad.*).';

-- ---------------------------------------------------------------------------
-- 1. Catálogo de cuentas
-- ---------------------------------------------------------------------------

create table if not exists public.accounting_accounts (
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null references public.businesses(id) on delete cascade,
  code          text not null,
  name          text not null,
  account_type  text not null
                check (account_type in ('asset','liability','equity','income','expense')),
  parent_id     uuid references public.accounting_accounts(id) on delete set null,
  -- Solo las cuentas de detalle reciben asientos; las de agrupación (1, 11,
  -- 1101) existen para armar el árbol y sumar en los reportes.
  is_postable   boolean not null default true,
  is_active     boolean not null default true,
  description   text,
  created_at    timestamptz not null default now(),
  unique (business_id, code)
);

comment on table public.accounting_accounts is
  'Catálogo de cuentas por negocio. Jerárquico vía parent_id; solo '
  'is_postable = true admite líneas de asiento.';

create index if not exists idx_acct_accounts_business
  on public.accounting_accounts (business_id, code);
create index if not exists idx_acct_accounts_parent
  on public.accounting_accounts (parent_id);

-- ---------------------------------------------------------------------------
-- 2. Centros de costo / departamentos / proyectos / sucursales
-- ---------------------------------------------------------------------------

create table if not exists public.accounting_cost_centers (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  code        text not null,
  name        text not null,
  kind        text not null default 'cost_center'
              check (kind in ('cost_center','department','project','branch')),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  unique (business_id, code)
);

comment on table public.accounting_cost_centers is
  'Dimensión analítica de las líneas de asiento: centro de costo, '
  'departamento, proyecto o sucursal.';

create index if not exists idx_acct_cc_business
  on public.accounting_cost_centers (business_id, is_active);

-- ---------------------------------------------------------------------------
-- 3. Períodos contables
-- ---------------------------------------------------------------------------

create table if not exists public.accounting_periods (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  year        integer not null check (year between 2000 and 2999),
  month       integer not null check (month between 1 and 12),
  status      text not null default 'open' check (status in ('open','closed')),
  closed_at   timestamptz,
  closed_by   uuid,
  reopened_at timestamptz,
  reopened_by uuid,
  notes       text,
  created_at  timestamptz not null default now(),
  unique (business_id, year, month)
);

comment on table public.accounting_periods is
  'Un período por mes. status = closed bloquea el posteo de asientos con '
  'fecha dentro del mes (excepción PERIOD_CLOSED).';

-- ---------------------------------------------------------------------------
-- 4. Asientos y líneas
-- ---------------------------------------------------------------------------

create table if not exists public.accounting_entries (
  id                  uuid primary key default gen_random_uuid(),
  business_id         uuid not null references public.businesses(id) on delete cascade,
  entry_number        bigint not null,
  entry_date          date not null,
  period_id           uuid references public.accounting_periods(id),
  description         text not null,
  reference           text,
  -- Trazabilidad completa asiento → documento que lo originó.
  source_type         text not null default 'manual',
  source_id           uuid,
  source_table        text,
  status              text not null default 'posted'
                      check (status in ('draft','posted','reversed')),
  reverses_entry_id   uuid references public.accounting_entries(id),
  reversed_by_entry_id uuid references public.accounting_entries(id),
  total_debit         numeric(15,2) not null default 0,
  total_credit        numeric(15,2) not null default 0,
  created_by          uuid,
  created_at          timestamptz not null default now(),
  posted_at           timestamptz,
  unique (business_id, entry_number)
);

comment on table public.accounting_entries is
  'Asiento contable. Nunca se edita ni se borra una vez posteado: se '
  'revierte con un asiento espejo enlazado por reverses_entry_id.';

create index if not exists idx_acct_entries_business_date
  on public.accounting_entries (business_id, entry_date);
create index if not exists idx_acct_entries_period
  on public.accounting_entries (period_id);

-- Un documento origen genera UN asiento. Esto es lo que hace que los
-- generadores se puedan re-correr sobre el mismo rango sin duplicar.
create unique index if not exists uq_acct_entries_source
  on public.accounting_entries (business_id, source_type, source_id)
  where source_id is not null;

create table if not exists public.accounting_entry_lines (
  id             uuid primary key default gen_random_uuid(),
  entry_id       uuid not null references public.accounting_entries(id) on delete cascade,
  line_no        integer not null default 1,
  account_id     uuid not null references public.accounting_accounts(id),
  cost_center_id uuid references public.accounting_cost_centers(id),
  debit          numeric(15,2) not null default 0 check (debit >= 0),
  credit         numeric(15,2) not null default 0 check (credit >= 0),
  description    text,
  -- Una línea es débito o crédito, nunca las dos ni ninguna.
  constraint acct_line_one_side check (
    (debit > 0 and credit = 0) or (credit > 0 and debit = 0)
  )
);

create index if not exists idx_acct_lines_entry
  on public.accounting_entry_lines (entry_id);
create index if not exists idx_acct_lines_account
  on public.accounting_entry_lines (account_id);
create index if not exists idx_acct_lines_cc
  on public.accounting_entry_lines (cost_center_id);

-- ---------------------------------------------------------------------------
-- 5. Mapeo evento → cuenta
-- ---------------------------------------------------------------------------

create table if not exists public.accounting_account_mappings (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  event_key   text not null,
  account_id  uuid not null references public.accounting_accounts(id) on delete cascade,
  updated_at  timestamptz not null default now(),
  unique (business_id, event_key)
);

comment on table public.accounting_account_mappings is
  'Traduce un evento del POS (sales_revenue, itbis_payable, '
  'payment_method:cash, …) a la cuenta que debe usar el generador '
  'automático. Editable por el contador sin tocar código.';

-- ---------------------------------------------------------------------------
-- 6. Configuración contable del negocio
-- ---------------------------------------------------------------------------

create table if not exists public.accounting_settings (
  business_id             uuid primary key references public.businesses(id) on delete cascade,
  fiscal_year_start_month integer not null default 1 check (fiscal_year_start_month between 1 and 12),
  base_currency           text not null default 'DOP',
  initialized_at          timestamptz,
  updated_at              timestamptz not null default now()
);

-- Cuenta contable opcional por razón de gasto de caja (Ajustes → Razones de
-- caja). Nullable: las razones existentes siguen cayendo en la cuenta por
-- defecto de gastos varios. Se guarda por si la BD viva no tiene todavía
-- `cash_transaction_reasons` (mig 20260513_0015): el generador de caja cae al
-- coalesce con la cuenta por defecto igual.
do $$
begin
  if to_regclass('public.cash_transaction_reasons') is not null then
    alter table public.cash_transaction_reasons
      add column if not exists accounting_account_id uuid
        references public.accounting_accounts(id) on delete set null;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Inmutabilidad de asientos posteados
--
-- Bitácora mínima exigida por el PDF: "reversión de asientos sin borrar el
-- registro original". El trigger impide UPDATE/DELETE sobre asientos
-- posteados salvo el enlace de reversión, y sobre cualquier línea cuyo
-- asiento ya esté posteado.
-- ---------------------------------------------------------------------------

create or replace function public.fn_accounting_guard_entry()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    if old.status <> 'draft' then
      raise exception 'ENTRY_IMMUTABLE'
        using hint = 'Un asiento posteado no se borra: reviértelo.';
    end if;
    return old;
  end if;

  if old.status = 'draft' then
    return new;
  end if;

  -- Posteado: solo se permite marcarlo como revertido y enlazar el espejo.
  if new.business_id  is distinct from old.business_id
     or new.entry_number is distinct from old.entry_number
     or new.entry_date   is distinct from old.entry_date
     or new.description  is distinct from old.description
     or new.total_debit  is distinct from old.total_debit
     or new.total_credit is distinct from old.total_credit
     or new.source_type  is distinct from old.source_type
     or new.source_id    is distinct from old.source_id then
    raise exception 'ENTRY_IMMUTABLE'
      using hint = 'Un asiento posteado no se edita: reviértelo y vuelve a asentar.';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_accounting_guard_entry on public.accounting_entries;
create trigger trg_accounting_guard_entry
  before update or delete on public.accounting_entries
  for each row execute function public.fn_accounting_guard_entry();

create or replace function public.fn_accounting_guard_line()
returns trigger
language plpgsql
as $$
declare
  v_status text;
  v_entry  uuid;
begin
  v_entry := coalesce(new.entry_id, old.entry_id);
  select e.status into v_status
  from public.accounting_entries e
  where e.id = v_entry;

  -- El cascade del DELETE del asiento (solo posible en draft) no debe
  -- dispararse acá: si el asiento ya no existe, dejamos pasar.
  if v_status is null or v_status = 'draft' then
    return coalesce(new, old);
  end if;

  raise exception 'ENTRY_IMMUTABLE'
    using hint = 'Las líneas de un asiento posteado no se modifican.';
end;
$$;

drop trigger if exists trg_accounting_guard_line on public.accounting_entry_lines;
create trigger trg_accounting_guard_line
  before update or delete on public.accounting_entry_lines
  for each row execute function public.fn_accounting_guard_line();

-- ---------------------------------------------------------------------------
-- 8. RLS
--
-- Lectura: cualquier miembro con el permiso de acceso (o owner/admin).
-- Escritura directa: solo owner/admin — el resto escribe por las RPC
-- SECURITY DEFINER, que validan permiso granular y reglas contables.
-- ---------------------------------------------------------------------------

do $$
declare
  t text;
begin
  foreach t in array array[
    'accounting_accounts','accounting_cost_centers','accounting_periods',
    'accounting_entries','accounting_account_mappings','accounting_settings'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "acct_select" on public.%I', t);
    execute format($p$
      create policy "acct_select" on public.%I
        for select to authenticated
        using (public.fn_accounting_can(business_id, 'contabilidad.acceso'))
    $p$, t);
    execute format('drop policy if exists "acct_write" on public.%I', t);
    execute format($p$
      create policy "acct_write" on public.%I
        for all to authenticated
        using (public.fn_accounting_can(business_id, 'contabilidad.catalogo.gestionar'))
        with check (public.fn_accounting_can(business_id, 'contabilidad.catalogo.gestionar'))
    $p$, t);
  end loop;
end;
$$;

alter table public.accounting_entry_lines enable row level security;

drop policy if exists "acct_lines_select" on public.accounting_entry_lines;
create policy "acct_lines_select" on public.accounting_entry_lines
  for select to authenticated
  using (exists (
    select 1 from public.accounting_entries e
    where e.id = entry_id
      and public.fn_accounting_can(e.business_id, 'contabilidad.acceso')
  ));

-- Sin policy de escritura: las líneas solo entran por fn_accounting_post_entry.

-- ---------------------------------------------------------------------------
-- 9. Seed del catálogo + mapeos
-- ---------------------------------------------------------------------------

create or replace function public.fn_accounting_seed_chart(p_business_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_created int := 0;
  v_mapped  int := 0;
  r         record;
begin
  if not public.fn_accounting_can(p_business_id, 'contabilidad.catalogo.gestionar') then
    raise exception 'ACCESS_DENIED';
  end if;

  -- `if not exists` no alcanza: si la función se llama dos veces en la misma
  -- transacción, la temp table sobrevive con datos. Se descarta explícito.
  drop table if exists _seed_chart;
  create temp table _seed_chart (
    code text, name text, account_type text, parent_code text, is_postable boolean
  ) on commit drop;

  insert into _seed_chart (code, name, account_type, parent_code, is_postable) values
    ('1',      'ACTIVO',                            'asset',     null,   false),
    ('11',     'Activo corriente',                  'asset',     '1',    false),
    ('1101',   'Efectivo y equivalentes',           'asset',     '11',   false),
    ('110101', 'Caja general',                      'asset',     '1101', true),
    ('110102', 'Caja chica',                        'asset',     '1101', true),
    ('110103', 'Bancos',                            'asset',     '1101', true),
    ('110104', 'Tarjetas por liquidar',             'asset',     '1101', true),
    ('1102',   'Cuentas por cobrar',                'asset',     '11',   false),
    ('110201', 'Cuentas por cobrar clientes',       'asset',     '1102', true),
    ('110202', 'Otras cuentas por cobrar',          'asset',     '1102', true),
    ('1103',   'Inventarios',                       'asset',     '11',   false),
    ('110301', 'Inventario de mercancías e insumos','asset',     '1103', true),
    ('1104',   'Impuestos adelantados',             'asset',     '11',   false),
    ('110401', 'ITBIS pagado en compras',           'asset',     '1104', true),
    ('110402', 'Anticipos y retenciones de ISR',    'asset',     '1104', true),
    ('12',     'Activo no corriente',               'asset',     '1',    false),
    ('120101', 'Mobiliario y equipos',              'asset',     '12',   true),
    ('120102', 'Depreciación acumulada',            'asset',     '12',   true),

    ('2',      'PASIVO',                            'liability', null,   false),
    ('21',     'Pasivo corriente',                  'liability', '2',    false),
    ('2101',   'Cuentas por pagar',                 'liability', '21',   false),
    ('210101', 'Cuentas por pagar proveedores',     'liability', '2101', true),
    ('2102',   'Impuestos por pagar',               'liability', '21',   false),
    ('210201', 'ITBIS por pagar',                   'liability', '2102', true),
    ('210202', 'ITBIS retenido por pagar',          'liability', '2102', true),
    ('210203', 'ISR retenido por pagar',            'liability', '2102', true),
    ('2103',   'Otras cuentas por pagar',           'liability', '21',   false),
    ('210301', 'Propinas por pagar',                'liability', '2103', true),
    ('210302', 'Servicio por pagar',                'liability', '2103', true),
    ('210303', 'Acreedores diversos',               'liability', '2103', true),

    ('3',      'PATRIMONIO',                        'equity',    null,   false),
    ('310101', 'Capital social',                    'equity',    '3',    true),
    ('310201', 'Resultados acumulados',             'equity',    '3',    true),
    ('310202', 'Resultado del ejercicio',           'equity',    '3',    true),

    ('4',      'INGRESOS',                          'income',    null,   false),
    ('41',     'Ingresos operacionales',            'income',    '4',    false),
    ('410101', 'Ventas',                            'income',    '41',   true),
    ('410102', 'Ingresos por delivery',             'income',    '41',   true),
    ('410103', 'Ingresos por servicio',             'income',    '41',   true),
    ('410201', 'Descuentos en ventas',              'income',    '41',   true),
    ('42',     'Otros ingresos',                    'income',    '4',    false),
    ('420101', 'Otros ingresos',                    'income',    '42',   true),

    ('5',      'COSTOS',                            'expense',   null,   false),
    ('510101', 'Costo de ventas',                   'expense',   '5',    true),

    ('6',      'GASTOS',                            'expense',   null,   false),
    ('61',     'Gastos operativos',                 'expense',   '6',    false),
    ('610101', 'Gastos de personal',                'expense',   '61',   true),
    ('610102', 'Alquiler',                          'expense',   '61',   true),
    ('610103', 'Servicios (luz, agua, internet)',   'expense',   '61',   true),
    ('610104', 'Suministros y limpieza',            'expense',   '61',   true),
    ('610105', 'Mantenimiento y reparaciones',      'expense',   '61',   true),
    ('610106', 'Publicidad y mercadeo',             'expense',   '61',   true),
    ('610107', 'Comisiones bancarias y de tarjeta', 'expense',   '61',   true),
    ('610108', 'Gastos varios de caja',             'expense',   '61',   true),
    ('62',     'Otros gastos',                      'expense',   '6',    false),
    ('610201', 'Diferencias y redondeo',            'expense',   '62',   true);

  -- Paso 1: cuentas sin jerarquía (las que ya existen se respetan).
  insert into public.accounting_accounts
    (business_id, code, name, account_type, is_postable)
  select p_business_id, s.code, s.name, s.account_type, s.is_postable
  from _seed_chart s
  on conflict (business_id, code) do nothing;

  get diagnostics v_created = row_count;

  -- Paso 2: jerarquía por código.
  update public.accounting_accounts a
     set parent_id = p.id
    from _seed_chart s
    join public.accounting_accounts p
      on p.business_id = p_business_id and p.code = s.parent_code
   where a.business_id = p_business_id
     and a.code = s.code
     and s.parent_code is not null
     and a.parent_id is null;

  -- Paso 3: mapeos evento → cuenta.
  for r in
    select * from (values
      ('cash',                     '110101'),
      ('petty_cash',               '110102'),
      ('bank',                     '110103'),
      ('card_clearing',            '110104'),
      ('ar_customers',             '110201'),
      ('inventory',                '110301'),
      ('itbis_credit',             '110401'),
      ('ap_suppliers',             '210101'),
      ('itbis_payable',            '210201'),
      ('itbis_withheld',           '210202'),
      ('isr_withheld',             '210203'),
      ('tips_payable',             '210301'),
      ('service_fee_payable',      '210302'),
      ('sales_revenue',            '410101'),
      ('delivery_revenue',         '410102'),
      ('sales_discounts',          '410201'),
      ('other_income',             '420101'),
      ('cogs',                     '510101'),
      ('cash_expense',             '610108'),
      ('rounding',                 '610201'),
      ('retained_earnings',        '310201'),
      ('current_earnings',         '310202'),
      ('payment_method:cash',      '110101'),
      ('payment_method:card',      '110104'),
      ('payment_method:tarjeta',   '110104'),
      ('payment_method:transfer',  '110103'),
      ('payment_method:transferencia', '110103'),
      ('payment_method:credit',    '110201')
    ) as m(event_key, code)
  loop
    insert into public.accounting_account_mappings (business_id, event_key, account_id)
    select p_business_id, r.event_key, a.id
    from public.accounting_accounts a
    where a.business_id = p_business_id and a.code = r.code
    on conflict (business_id, event_key) do nothing;
    v_mapped := v_mapped + 1;
  end loop;

  insert into public.accounting_settings (business_id, initialized_at)
  values (p_business_id, now())
  on conflict (business_id) do update
    set initialized_at = coalesce(accounting_settings.initialized_at, now());

  return jsonb_build_object('accounts_created', v_created, 'mappings', v_mapped);
end;
$$;

-- ---------------------------------------------------------------------------
-- 10. Períodos
-- ---------------------------------------------------------------------------

create or replace function public.fn_accounting_ensure_period(
  p_business_id uuid,
  p_date        date
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  select id into v_id
  from public.accounting_periods
  where business_id = p_business_id
    and year = extract(year from p_date)::int
    and month = extract(month from p_date)::int;

  if v_id is null then
    insert into public.accounting_periods (business_id, year, month)
    values (p_business_id, extract(year from p_date)::int,
            extract(month from p_date)::int)
    on conflict (business_id, year, month) do nothing
    returning id into v_id;

    if v_id is null then
      select id into v_id
      from public.accounting_periods
      where business_id = p_business_id
        and year = extract(year from p_date)::int
        and month = extract(month from p_date)::int;
    end if;
  end if;

  return v_id;
end;
$$;

create or replace function public.fn_accounting_set_period_status(
  p_business_id uuid,
  p_year        integer,
  p_month       integer,
  p_status      text,
  p_notes       text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if not public.fn_accounting_can(p_business_id, 'contabilidad.periodos.cerrar') then
    raise exception 'ACCESS_DENIED';
  end if;
  if p_status not in ('open','closed') then
    raise exception 'INVALID_STATUS';
  end if;

  v_id := public.fn_accounting_ensure_period(
    p_business_id, make_date(p_year, p_month, 1));

  update public.accounting_periods
     set status      = p_status,
         notes       = coalesce(p_notes, notes),
         closed_at   = case when p_status = 'closed' then now() else closed_at end,
         closed_by   = case when p_status = 'closed' then auth.uid() else closed_by end,
         reopened_at = case when p_status = 'open'   then now() else reopened_at end,
         reopened_by = case when p_status = 'open'   then auth.uid() else reopened_by end
   where id = v_id;

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 11. Posteo de asientos
--
-- p_lines: jsonb array de objetos
--   { "account_code" | "account_id", "debit", "credit",
--     "description", "cost_center_id" }
-- ---------------------------------------------------------------------------

create or replace function public.fn_accounting_post_entry(
  p_business_id  uuid,
  p_entry_date   date,
  p_description  text,
  p_lines        jsonb,
  p_reference    text default null,
  p_source_type  text default 'manual',
  p_source_id    uuid default null,
  p_source_table text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_entry_id  uuid;
  v_period_id uuid;
  v_status    text;
  v_number    bigint;
  v_debit     numeric(15,2) := 0;
  v_credit    numeric(15,2) := 0;
  v_line      jsonb;
  v_account   uuid;
  v_no        int := 0;
  v_d         numeric(15,2);
  v_c         numeric(15,2);
begin
  if not public.fn_accounting_can(p_business_id, 'contabilidad.asientos.crear') then
    raise exception 'ACCESS_DENIED';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array'
     or jsonb_array_length(p_lines) < 2 then
    raise exception 'INVALID_LINES'
      using hint = 'Un asiento necesita al menos dos líneas.';
  end if;

  -- Período abierto
  v_period_id := public.fn_accounting_ensure_period(p_business_id, p_entry_date);
  select status into v_status from public.accounting_periods where id = v_period_id;
  if v_status = 'closed' then
    raise exception 'PERIOD_CLOSED'
      using hint = 'El mes está cerrado. Reábrelo para asentar en esa fecha.';
  end if;

  -- Cuadre
  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_debit  := v_debit  + round(coalesce((v_line->>'debit')::numeric, 0), 2);
    v_credit := v_credit + round(coalesce((v_line->>'credit')::numeric, 0), 2);
  end loop;

  if v_debit <= 0 then
    raise exception 'EMPTY_ENTRY' using hint = 'El asiento no mueve importes.';
  end if;
  if v_debit <> v_credit then
    raise exception 'UNBALANCED_ENTRY'
      using hint = format('Débitos %s ≠ créditos %s.', v_debit, v_credit);
  end if;

  -- Numeración correlativa por negocio, serializada por advisory lock.
  perform pg_advisory_xact_lock(hashtext('acct_entry_no:' || p_business_id::text));
  select coalesce(max(entry_number), 0) + 1 into v_number
  from public.accounting_entries where business_id = p_business_id;

  insert into public.accounting_entries (
    business_id, entry_number, entry_date, period_id, description, reference,
    source_type, source_id, source_table, status,
    total_debit, total_credit, created_by, posted_at
  ) values (
    p_business_id, v_number, p_entry_date, v_period_id, p_description, p_reference,
    coalesce(p_source_type, 'manual'), p_source_id, p_source_table, 'posted',
    v_debit, v_credit, auth.uid(), now()
  )
  returning id into v_entry_id;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_no := v_no + 1;
    v_d  := round(coalesce((v_line->>'debit')::numeric, 0), 2);
    v_c  := round(coalesce((v_line->>'credit')::numeric, 0), 2);
    if v_d = 0 and v_c = 0 then
      continue;  -- línea vacía: se ignora, ya cuadró arriba
    end if;

    if (v_line->>'account_id') is not null then
      v_account := (v_line->>'account_id')::uuid;
    else
      select id into v_account
      from public.accounting_accounts
      where business_id = p_business_id and code = (v_line->>'account_code');
    end if;

    if v_account is null then
      raise exception 'ACCOUNT_NOT_FOUND'
        using hint = coalesce(v_line->>'account_code', v_line->>'account_id');
    end if;

    if not exists (
      select 1 from public.accounting_accounts
      where id = v_account and business_id = p_business_id
        and is_active and is_postable
    ) then
      raise exception 'ACCOUNT_NOT_POSTABLE'
        using hint = 'La cuenta no existe, está inactiva o es de agrupación.';
    end if;

    insert into public.accounting_entry_lines (
      entry_id, line_no, account_id, cost_center_id, debit, credit, description
    ) values (
      v_entry_id, v_no, v_account,
      nullif(v_line->>'cost_center_id','')::uuid,
      v_d, v_c, v_line->>'description'
    );
  end loop;

  return v_entry_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 12. Reversión
-- ---------------------------------------------------------------------------

create or replace function public.fn_accounting_reverse_entry(
  p_entry_id uuid,
  p_date     date default null,
  p_reason   text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_src   public.accounting_entries;
  v_lines jsonb;
  v_new   uuid;
  v_date  date;
begin
  select * into v_src from public.accounting_entries where id = p_entry_id;
  if v_src.id is null then
    raise exception 'ENTRY_NOT_FOUND';
  end if;
  if not public.fn_accounting_can(v_src.business_id, 'contabilidad.asientos.anular') then
    raise exception 'ACCESS_DENIED';
  end if;
  if v_src.status = 'reversed' then
    raise exception 'ALREADY_REVERSED';
  end if;
  if v_src.reverses_entry_id is not null then
    raise exception 'CANNOT_REVERSE_REVERSAL'
      using hint = 'Ese asiento ya es la reversión de otro.';
  end if;

  v_date := coalesce(p_date, current_date);

  -- Espejo: débito ↔ crédito.
  select jsonb_agg(jsonb_build_object(
           'account_id',     l.account_id,
           'cost_center_id', l.cost_center_id,
           'debit',          l.credit,
           'credit',         l.debit,
           'description',    l.description
         ) order by l.line_no)
    into v_lines
  from public.accounting_entry_lines l
  where l.entry_id = p_entry_id;

  v_new := public.fn_accounting_post_entry(
    p_business_id  => v_src.business_id,
    p_entry_date   => v_date,
    p_description  => 'Reversión asiento #' || v_src.entry_number ||
                      coalesce(' — ' || p_reason, ''),
    p_lines        => v_lines,
    p_reference    => v_src.reference,
    p_source_type  => 'reversal',
    p_source_id    => null,
    p_source_table => 'accounting_entries'
  );

  update public.accounting_entries
     set reverses_entry_id = p_entry_id
   where id = v_new;

  update public.accounting_entries
     set status = 'reversed', reversed_by_entry_id = v_new
   where id = p_entry_id;

  return v_new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 13. Helper interno: cuenta mapeada a un evento
-- ---------------------------------------------------------------------------

create or replace function public.fn_accounting_account_for(
  p_business_id uuid,
  p_event_key   text
) returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select m.account_id
  from public.accounting_account_mappings m
  where m.business_id = p_business_id and m.event_key = p_event_key
  limit 1;
$$;

-- ---------------------------------------------------------------------------
-- 14. Generador: ventas (un asiento por día)
-- ---------------------------------------------------------------------------

create or replace function public.fn_accounting_generate_sales(
  p_business_id uuid,
  p_from        date,
  p_to          date
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tz        text;
  v_day       date;
  v_created   int := 0;
  v_lines     jsonb;
  v_debits    numeric(15,2);
  v_credits   numeric(15,2);
  v_subtotal  numeric(15,2);
  v_discounts numeric(15,2);
  v_tax       numeric(15,2);
  v_service   numeric(15,2);
  v_diff      numeric(15,2);
  v_source    uuid;
  r           record;
begin
  if not public.fn_accounting_can(p_business_id, 'contabilidad.asientos.crear') then
    raise exception 'ACCESS_DENIED';
  end if;

  select coalesce(timezone, 'America/Santo_Domingo') into v_tz
  from public.business_settings where business_id = p_business_id;
  v_tz := coalesce(v_tz, 'America/Santo_Domingo');

  for v_day in select generate_series(p_from, p_to, interval '1 day')::date loop
    -- source_id determinístico: mismo negocio + mismo día ⇒ mismo uuid, así
    -- el índice único de origen bloquea el duplicado si se re-corre.
    v_source := md5('sales:' || p_business_id::text || ':' || v_day::text)::uuid;

    if exists (
      select 1 from public.accounting_entries
      where business_id = p_business_id
        and source_type = 'sales' and source_id = v_source
    ) then
      continue;
    end if;

    select coalesce(sum(o.subtotal),0), coalesce(sum(o.discounts),0),
           coalesce(sum(o.tax),0), coalesce(sum(o.service_fee),0)
      into v_subtotal, v_discounts, v_tax, v_service
    from public.orders o
    join public.table_sessions ts on ts.id = o.session_id
    where ts.business_id = p_business_id
      and o.status = 'paid'
      and o.closed_at is not null
      and ((o.closed_at at time zone v_tz)::date) = v_day;

    if v_subtotal = 0 and v_tax = 0 and v_service = 0 then
      continue;
    end if;

    v_lines  := '[]'::jsonb;
    v_debits := 0;

    -- DEBE: la plata cobrada, por método de pago.
    for r in
      select coalesce(pm.code, 'cash') as code,
             round(sum(p.amount), 2)   as amount
      from public.payments p
      join public.orders o on o.id = p.order_id
      join public.table_sessions ts on ts.id = o.session_id
      left join public.payment_methods pm on pm.id = p.payment_method_id
      where ts.business_id = p_business_id
        and p.status = 'completed'
        and o.status = 'paid'
        and o.closed_at is not null
        and ((o.closed_at at time zone v_tz)::date) = v_day
      group by 1
      having round(sum(p.amount), 2) <> 0
    loop
      v_lines := v_lines || jsonb_build_object(
        'account_id', coalesce(
          public.fn_accounting_account_for(p_business_id, 'payment_method:' || r.code),
          public.fn_accounting_account_for(p_business_id, 'cash')),
        'debit', r.amount, 'credit', 0,
        'description', 'Cobros ' || r.code);
      v_debits := v_debits + r.amount;
    end loop;

    if v_discounts > 0 then
      v_lines := v_lines || jsonb_build_object(
        'account_id', public.fn_accounting_account_for(p_business_id, 'sales_discounts'),
        'debit', v_discounts, 'credit', 0, 'description', 'Descuentos otorgados');
      v_debits := v_debits + v_discounts;
    end if;

    -- HABER: ingreso devengado + impuestos + servicio.
    v_credits := 0;
    if v_subtotal <> 0 then
      v_lines := v_lines || jsonb_build_object(
        'account_id', public.fn_accounting_account_for(p_business_id, 'sales_revenue'),
        'debit', 0, 'credit', v_subtotal, 'description', 'Ventas del día');
      v_credits := v_credits + v_subtotal;
    end if;
    if v_tax <> 0 then
      v_lines := v_lines || jsonb_build_object(
        'account_id', public.fn_accounting_account_for(p_business_id, 'itbis_payable'),
        'debit', 0, 'credit', v_tax, 'description', 'ITBIS facturado');
      v_credits := v_credits + v_tax;
    end if;
    if v_service <> 0 then
      v_lines := v_lines || jsonb_build_object(
        'account_id', public.fn_accounting_account_for(p_business_id, 'service_fee_payable'),
        'debit', 0, 'credit', v_service, 'description', 'Cargo por servicio');
      v_credits := v_credits + v_service;
    end if;

    -- Residuo (redondeos, cobros parciales del día anterior, propinas que el
    -- POS no persiste a nivel de orden): va a Diferencias para que el asiento
    -- cuadre sin inventar ingreso.
    v_diff := round(v_credits - v_debits, 2);
    if v_diff <> 0 then
      v_lines := v_lines || jsonb_build_object(
        'account_id', public.fn_accounting_account_for(p_business_id, 'rounding'),
        'debit',  case when v_diff > 0 then  v_diff else 0 end,
        'credit', case when v_diff < 0 then -v_diff else 0 end,
        'description', 'Diferencia cobros vs. facturación');
    end if;

    begin
      perform public.fn_accounting_post_entry(
        p_business_id  => p_business_id,
        p_entry_date   => v_day,
        p_description  => 'Ventas del ' || to_char(v_day, 'DD/MM/YYYY'),
        p_lines        => v_lines,
        p_reference    => null,
        p_source_type  => 'sales',
        p_source_id    => v_source,
        p_source_table => 'orders');
      v_created := v_created + 1;
    exception
      when sqlstate '23505' then null;            -- ya existía (carrera)
      when others then
        if sqlerrm = 'PERIOD_CLOSED' then
          null;                                    -- mes cerrado: se salta
        else
          raise;
        end if;
    end;
  end loop;

  return v_created;
end;
$$;

-- ---------------------------------------------------------------------------
-- 15. Generador: compras recibidas
-- ---------------------------------------------------------------------------

create or replace function public.fn_accounting_generate_purchases(
  p_business_id uuid,
  p_from        date,
  p_to          date
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_created int := 0;
  v_lines   jsonb;
  v_credit  boolean;
  r         record;
begin
  if not public.fn_accounting_can(p_business_id, 'contabilidad.asientos.crear') then
    raise exception 'ACCESS_DENIED';
  end if;

  for r in
    select po.id, po.order_number, po.subtotal, po.tax, po.total,
           po.received_date, s.name as supplier_name
    from public.purchase_orders po
    left join public.suppliers s on s.id = po.supplier_id
    where po.business_id = p_business_id
      and po.status = 'received'
      and coalesce(po.received_date, po.created_at::date) between p_from and p_to
      and not exists (
        select 1 from public.accounting_entries e
        where e.business_id = p_business_id
          and e.source_type = 'purchase' and e.source_id = po.id)
  loop
    if coalesce(r.total, 0) = 0 then
      continue;
    end if;

    -- ¿Quedó como cuenta por pagar? Entonces la contrapartida es CxP.
    v_credit := exists (
      select 1 from public.supplier_credits sc
      where sc.purchase_order_id = r.id and sc.status <> 'cancelled');

    v_lines := jsonb_build_array(
      jsonb_build_object(
        'account_id', public.fn_accounting_account_for(p_business_id, 'inventory'),
        'debit', round(coalesce(r.subtotal, r.total), 2), 'credit', 0,
        'description', 'Compra ' || coalesce(r.order_number, '')),
      jsonb_build_object(
        'account_id', public.fn_accounting_account_for(
          p_business_id, case when v_credit then 'ap_suppliers' else 'cash' end),
        'debit', 0, 'credit', round(r.total, 2),
        'description', coalesce(r.supplier_name, 'Proveedor')));

    if coalesce(r.tax, 0) <> 0 then
      v_lines := jsonb_insert(v_lines, '{1}', jsonb_build_object(
        'account_id', public.fn_accounting_account_for(p_business_id, 'itbis_credit'),
        'debit', round(r.tax, 2), 'credit', 0,
        'description', 'ITBIS en compras'));
    end if;

    begin
      perform public.fn_accounting_post_entry(
        p_business_id  => p_business_id,
        p_entry_date   => coalesce(r.received_date, current_date),
        p_description  => 'Compra ' || coalesce(r.order_number, '') ||
                          coalesce(' — ' || r.supplier_name, ''),
        p_lines        => v_lines,
        p_reference    => r.order_number,
        p_source_type  => 'purchase',
        p_source_id    => r.id,
        p_source_table => 'purchase_orders');
      v_created := v_created + 1;
    exception
      when sqlstate '23505' then null;
      when others then
        if sqlerrm = 'PERIOD_CLOSED' then null; else raise; end if;
    end;
  end loop;

  return v_created;
end;
$$;

-- ---------------------------------------------------------------------------
-- 16. Generador: gastos y retiros de caja
--
-- Se excluyen los movimientos que emiten las RPC de crédito ('Abono crédito
-- CxC …' y 'Pago CxP …'), porque esos los asienta el generador de créditos.
-- Sin esa exclusión se contarían dos veces.
-- ---------------------------------------------------------------------------

create or replace function public.fn_accounting_generate_cash(
  p_business_id uuid,
  p_from        date,
  p_to          date
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_created int := 0;
  v_tz      text;
  v_account uuid;
  r         record;
begin
  if not public.fn_accounting_can(p_business_id, 'contabilidad.asientos.crear') then
    raise exception 'ACCESS_DENIED';
  end if;

  select coalesce(timezone, 'America/Santo_Domingo') into v_tz
  from public.business_settings where business_id = p_business_id;
  v_tz := coalesce(v_tz, 'America/Santo_Domingo');

  for r in
    select ct.id, ct.amount, ct.type, ct.description, ct.reason_code,
           ((ct.created_at at time zone v_tz)::date) as txn_date,
           cr_reason.accounting_account_id as reason_account_id
    from public.cash_transactions ct
    join public.cash_register_sessions crs on crs.id = ct.session_id
    join public.cash_registers cr on cr.id = crs.cash_register_id
    left join public.cash_transaction_reasons cr_reason
      on cr_reason.business_id = cr.business_id
     and cr_reason.code = ct.reason_code
    where cr.business_id = p_business_id
      and ct.type in ('expense', 'withdrawal')
      and ct.related_order_id is null
      and coalesce(ct.description, '') not like 'Abono crédito CxC%'
      and coalesce(ct.description, '') not like 'Pago CxP%'
      and ((ct.created_at at time zone v_tz)::date) between p_from and p_to
      and not exists (
        select 1 from public.accounting_entries e
        where e.business_id = p_business_id
          and e.source_type = 'cash_txn' and e.source_id = ct.id)
  loop
    if coalesce(r.amount, 0) = 0 then
      continue;
    end if;

    v_account := coalesce(
      r.reason_account_id,
      public.fn_accounting_account_for(p_business_id, 'cash_expense'));

    begin
      perform public.fn_accounting_post_entry(
        p_business_id  => p_business_id,
        p_entry_date   => r.txn_date,
        p_description  => coalesce(nullif(r.description, ''),
                                   'Movimiento de caja (' || r.type || ')'),
        p_lines        => jsonb_build_array(
          jsonb_build_object('account_id', v_account,
            'debit', round(abs(r.amount), 2), 'credit', 0,
            'description', r.reason_code),
          jsonb_build_object(
            'account_id', public.fn_accounting_account_for(p_business_id, 'cash'),
            'debit', 0, 'credit', round(abs(r.amount), 2),
            'description', 'Salida de caja')),
        p_reference    => r.reason_code,
        p_source_type  => 'cash_txn',
        p_source_id    => r.id,
        p_source_table => 'cash_transactions');
      v_created := v_created + 1;
    exception
      when sqlstate '23505' then null;
      when others then
        if sqlerrm = 'PERIOD_CLOSED' then null; else raise; end if;
    end;
  end loop;

  return v_created;
end;
$$;

-- ---------------------------------------------------------------------------
-- 17. Generador: abonos CxC y pagos CxP
-- ---------------------------------------------------------------------------

create or replace function public.fn_accounting_generate_credits(
  p_business_id uuid,
  p_from        date,
  p_to          date
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_created int := 0;
  v_tz      text;
  v_contra  uuid;
  r         record;
begin
  if not public.fn_accounting_can(p_business_id, 'contabilidad.asientos.crear') then
    raise exception 'ACCESS_DENIED';
  end if;

  select coalesce(timezone, 'America/Santo_Domingo') into v_tz
  from public.business_settings where business_id = p_business_id;
  v_tz := coalesce(v_tz, 'America/Santo_Domingo');

  -- CxC: entra plata, baja la cuenta por cobrar.
  for r in
    select cp.id, cp.amount, cp.created_at, pm.code as method,
           ((cp.created_at at time zone v_tz)::date) as pay_date,
           c.name as customer_name
    from public.credit_payments cp
    join public.customer_credits cc on cc.id = cp.credit_id
    left join public.customers c on c.id = cc.customer_id
    left join public.payment_methods pm on pm.id = cp.payment_method_id
    where cc.business_id = p_business_id
      and ((cp.created_at at time zone v_tz)::date) between p_from and p_to
      and not exists (
        select 1 from public.accounting_entries e
        where e.business_id = p_business_id
          and e.source_type = 'credit_payment' and e.source_id = cp.id)
  loop
    if coalesce(r.amount, 0) = 0 then continue; end if;
    v_contra := coalesce(
      public.fn_accounting_account_for(
        p_business_id, 'payment_method:' || coalesce(r.method, 'cash')),
      public.fn_accounting_account_for(p_business_id, 'cash'));

    begin
      perform public.fn_accounting_post_entry(
        p_business_id  => p_business_id,
        p_entry_date   => r.pay_date,
        p_description  => 'Abono CxC' || coalesce(' — ' || r.customer_name, ''),
        p_lines        => jsonb_build_array(
          jsonb_build_object('account_id', v_contra,
            'debit', round(r.amount, 2), 'credit', 0, 'description', 'Cobro'),
          jsonb_build_object(
            'account_id', public.fn_accounting_account_for(p_business_id, 'ar_customers'),
            'debit', 0, 'credit', round(r.amount, 2),
            'description', 'Baja de cuenta por cobrar')),
        p_source_type  => 'credit_payment',
        p_source_id    => r.id,
        p_source_table => 'credit_payments');
      v_created := v_created + 1;
    exception
      when sqlstate '23505' then null;
      when others then
        if sqlerrm = 'PERIOD_CLOSED' then null; else raise; end if;
    end;
  end loop;

  -- CxP: sale plata, baja la cuenta por pagar.
  for r in
    select sp.id, sp.amount, sp.payment_method_code as method,
           ((sp.created_at at time zone v_tz)::date) as pay_date,
           s.name as supplier_name
    from public.supplier_credit_payments sp
    join public.supplier_credits sc on sc.id = sp.supplier_credit_id
    left join public.suppliers s on s.id = sc.supplier_id
    where sc.business_id = p_business_id
      and ((sp.created_at at time zone v_tz)::date) between p_from and p_to
      and not exists (
        select 1 from public.accounting_entries e
        where e.business_id = p_business_id
          and e.source_type = 'supplier_payment' and e.source_id = sp.id)
  loop
    if coalesce(r.amount, 0) = 0 then continue; end if;
    v_contra := coalesce(
      public.fn_accounting_account_for(
        p_business_id, 'payment_method:' || coalesce(r.method, 'cash')),
      public.fn_accounting_account_for(p_business_id, 'cash'));

    begin
      perform public.fn_accounting_post_entry(
        p_business_id  => p_business_id,
        p_entry_date   => r.pay_date,
        p_description  => 'Pago CxP' || coalesce(' — ' || r.supplier_name, ''),
        p_lines        => jsonb_build_array(
          jsonb_build_object(
            'account_id', public.fn_accounting_account_for(p_business_id, 'ap_suppliers'),
            'debit', round(r.amount, 2), 'credit', 0,
            'description', 'Baja de cuenta por pagar'),
          jsonb_build_object('account_id', v_contra,
            'debit', 0, 'credit', round(r.amount, 2), 'description', 'Pago')),
        p_source_type  => 'supplier_payment',
        p_source_id    => r.id,
        p_source_table => 'supplier_credit_payments');
      v_created := v_created + 1;
    exception
      when sqlstate '23505' then null;
      when others then
        if sqlerrm = 'PERIOD_CLOSED' then null; else raise; end if;
    end;
  end loop;

  return v_created;
end;
$$;

-- ---------------------------------------------------------------------------
-- 18. Generar todo
-- ---------------------------------------------------------------------------

create or replace function public.fn_accounting_generate_all(
  p_business_id uuid,
  p_from        date,
  p_to          date
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sales     int;
  v_purchases int;
  v_cash      int;
  v_credits   int;
begin
  v_sales     := public.fn_accounting_generate_sales(p_business_id, p_from, p_to);
  v_purchases := public.fn_accounting_generate_purchases(p_business_id, p_from, p_to);
  v_cash      := public.fn_accounting_generate_cash(p_business_id, p_from, p_to);
  v_credits   := public.fn_accounting_generate_credits(p_business_id, p_from, p_to);

  return jsonb_build_object(
    'sales', v_sales, 'purchases', v_purchases,
    'cash', v_cash, 'credits', v_credits,
    'total', v_sales + v_purchases + v_cash + v_credits);
end;
$$;

-- ---------------------------------------------------------------------------
-- 19. Reportes
-- ---------------------------------------------------------------------------

-- Libro diario: asientos del rango con sus líneas.
create or replace function public.fn_accounting_journal(
  p_business_id uuid,
  p_from        date,
  p_to          date
) returns table (
  entry_id     uuid,
  entry_number bigint,
  entry_date   date,
  description  text,
  reference    text,
  source_type  text,
  source_id    uuid,
  status       text,
  line_no      integer,
  account_code text,
  account_name text,
  cost_center  text,
  debit        numeric,
  credit       numeric,
  line_note    text
)
language sql
stable
security definer
set search_path = public
as $$
  select e.id, e.entry_number, e.entry_date, e.description, e.reference,
         e.source_type, e.source_id, e.status,
         l.line_no, a.code, a.name, cc.name,
         l.debit, l.credit, l.description
  from public.accounting_entries e
  join public.accounting_entry_lines l on l.entry_id = e.id
  join public.accounting_accounts a on a.id = l.account_id
  left join public.accounting_cost_centers cc on cc.id = l.cost_center_id
  where e.business_id = p_business_id
    and e.entry_date between p_from and p_to
    and public.fn_accounting_can(p_business_id, 'contabilidad.acceso')
  order by e.entry_date, e.entry_number, l.line_no;
$$;

-- Libro mayor de una cuenta, con saldo inicial y corrido.
create or replace function public.fn_accounting_ledger(
  p_business_id uuid,
  p_account_id  uuid,
  p_from        date,
  p_to          date
) returns table (
  entry_id     uuid,
  entry_number bigint,
  entry_date   date,
  description  text,
  reference    text,
  source_type  text,
  debit        numeric,
  credit       numeric,
  balance      numeric
)
language sql
stable
security definer
set search_path = public
as $$
  with nature as (
    select case when a.account_type in ('asset','expense') then 1 else -1 end as sign
    from public.accounting_accounts a
    where a.id = p_account_id and a.business_id = p_business_id
  ),
  opening as (
    select coalesce(sum(l.debit - l.credit), 0) as raw
    from public.accounting_entry_lines l
    join public.accounting_entries e on e.id = l.entry_id
    where e.business_id = p_business_id
      and l.account_id = p_account_id
      and e.entry_date < p_from
  ),
  movements as (
    select e.id, e.entry_number, e.entry_date, e.description, e.reference,
           e.source_type, l.debit, l.credit
    from public.accounting_entry_lines l
    join public.accounting_entries e on e.id = l.entry_id
    where e.business_id = p_business_id
      and l.account_id = p_account_id
      and e.entry_date between p_from and p_to
  )
  select *
  from (
    select null::uuid, 0::bigint, p_from, 'Saldo inicial'::text, null::text,
           'opening'::text, 0::numeric, 0::numeric,
           round((select raw from opening) * (select sign from nature), 2)
    union all
    select m.id, m.entry_number, m.entry_date, m.description, m.reference,
           m.source_type, m.debit, m.credit,
           round((((select raw from opening)
                   + sum(m.debit - m.credit) over (
                       order by m.entry_date, m.entry_number, m.id
                       rows between unbounded preceding and current row))
                  * (select sign from nature)), 2)
    from movements m
  ) t
  where public.fn_accounting_can(p_business_id, 'contabilidad.acceso')
  order by 3, 2;
$$;

-- Balanza de comprobación.
create or replace function public.fn_accounting_trial_balance(
  p_business_id   uuid,
  p_from          date,
  p_to            date,
  p_cost_center_id uuid default null
) returns table (
  account_id      uuid,
  code            text,
  name            text,
  account_type    text,
  opening_balance numeric,
  debit           numeric,
  credit          numeric,
  ending_balance  numeric
)
language sql
stable
security definer
set search_path = public
as $$
  with base as (
    select a.id, a.code, a.name, a.account_type,
           case when a.account_type in ('asset','expense') then 1 else -1 end as sign
    from public.accounting_accounts a
    where a.business_id = p_business_id and a.is_postable
  ),
  mov as (
    select l.account_id,
           sum(case when e.entry_date < p_from then l.debit - l.credit else 0 end) as opening_raw,
           sum(case when e.entry_date between p_from and p_to then l.debit else 0 end) as debit,
           sum(case when e.entry_date between p_from and p_to then l.credit else 0 end) as credit
    from public.accounting_entry_lines l
    join public.accounting_entries e on e.id = l.entry_id
    where e.business_id = p_business_id
      and e.entry_date <= p_to
      and (p_cost_center_id is null or l.cost_center_id = p_cost_center_id)
    group by l.account_id
  )
  select b.id, b.code, b.name, b.account_type,
         round(coalesce(m.opening_raw, 0) * b.sign, 2),
         round(coalesce(m.debit, 0), 2),
         round(coalesce(m.credit, 0), 2),
         round((coalesce(m.opening_raw, 0)
                + coalesce(m.debit, 0) - coalesce(m.credit, 0)) * b.sign, 2)
  from base b
  left join mov m on m.account_id = b.id
  where public.fn_accounting_can(p_business_id, 'contabilidad.acceso')
    and (coalesce(m.opening_raw, 0) <> 0
         or coalesce(m.debit, 0) <> 0 or coalesce(m.credit, 0) <> 0)
  order by b.code;
$$;

-- Estado de resultados: ingresos y gastos del rango.
create or replace function public.fn_accounting_income_statement(
  p_business_id uuid,
  p_from        date,
  p_to          date
) returns table (
  account_id   uuid,
  code         text,
  name         text,
  account_type text,
  amount       numeric
)
language sql
stable
security definer
set search_path = public
as $$
  select a.id, a.code, a.name, a.account_type,
         round(sum(case when a.account_type = 'income'
                        then l.credit - l.debit
                        else l.debit - l.credit end), 2)
  from public.accounting_entry_lines l
  join public.accounting_entries e on e.id = l.entry_id
  join public.accounting_accounts a on a.id = l.account_id
  where e.business_id = p_business_id
    and e.entry_date between p_from and p_to
    and a.account_type in ('income','expense')
    and public.fn_accounting_can(p_business_id, 'contabilidad.acceso')
  group by a.id, a.code, a.name, a.account_type
  having round(sum(case when a.account_type = 'income'
                        then l.credit - l.debit
                        else l.debit - l.credit end), 2) <> 0
  order by a.code;
$$;

-- Balance general a una fecha. La última fila es el resultado del ejercicio
-- calculado al vuelo (todavía no hay asiento de cierre anual).
create or replace function public.fn_accounting_balance_sheet(
  p_business_id uuid,
  p_as_of       date
) returns table (
  account_id   uuid,
  code         text,
  name         text,
  account_type text,
  balance      numeric
)
language sql
stable
security definer
set search_path = public
as $$
  with fy as (
    select make_date(
             case when extract(month from p_as_of)::int
                       >= coalesce(s.fiscal_year_start_month, 1)
                  then extract(year from p_as_of)::int
                  else extract(year from p_as_of)::int - 1 end,
             coalesce(s.fiscal_year_start_month, 1), 1) as start_date
    from (select 1) x
    left join public.accounting_settings s on s.business_id = p_business_id
  ),
  balances as (
    select a.id, a.code, a.name, a.account_type,
           round(sum(l.debit - l.credit)
                 * case when a.account_type = 'asset' then 1 else -1 end, 2) as balance
    from public.accounting_entry_lines l
    join public.accounting_entries e on e.id = l.entry_id
    join public.accounting_accounts a on a.id = l.account_id
    where e.business_id = p_business_id
      and e.entry_date <= p_as_of
      and a.account_type in ('asset','liability','equity')
    group by a.id, a.code, a.name, a.account_type
  ),
  result as (
    -- Resultado = ingresos − gastos, en una sola pasada (sin group by, así
    -- que el signo tiene que ir DENTRO del sum).
    select round(sum(case when a.account_type = 'income'
                          then  (l.credit - l.debit)
                          else -(l.debit  - l.credit) end), 2) as amount
    from public.accounting_entry_lines l
    join public.accounting_entries e on e.id = l.entry_id
    join public.accounting_accounts a on a.id = l.account_id
    where e.business_id = p_business_id
      and e.entry_date between (select start_date from fy) and p_as_of
      and a.account_type in ('income','expense')
  )
  select * from (
    select b.id, b.code, b.name, b.account_type, b.balance
    from balances b
    where b.balance <> 0
    union all
    select null::uuid, 'RESULT'::text, 'Resultado del ejercicio'::text,
           'equity'::text, coalesce((select amount from result), 0)
  ) t
  where public.fn_accounting_can(p_business_id, 'contabilidad.acceso')
  order by 4, 2;
$$;

-- ---------------------------------------------------------------------------
-- 20. Grants
-- ---------------------------------------------------------------------------

do $$
declare
  f text;
begin
  foreach f in array array[
    'fn_accounting_can(uuid, text)',
    'fn_accounting_seed_chart(uuid)',
    'fn_accounting_ensure_period(uuid, date)',
    'fn_accounting_set_period_status(uuid, integer, integer, text, text)',
    'fn_accounting_post_entry(uuid, date, text, jsonb, text, text, uuid, text)',
    'fn_accounting_reverse_entry(uuid, date, text)',
    'fn_accounting_account_for(uuid, text)',
    'fn_accounting_generate_sales(uuid, date, date)',
    'fn_accounting_generate_purchases(uuid, date, date)',
    'fn_accounting_generate_cash(uuid, date, date)',
    'fn_accounting_generate_credits(uuid, date, date)',
    'fn_accounting_generate_all(uuid, date, date)',
    'fn_accounting_journal(uuid, date, date)',
    'fn_accounting_ledger(uuid, uuid, date, date)',
    'fn_accounting_trial_balance(uuid, date, date, uuid)',
    'fn_accounting_income_statement(uuid, date, date)',
    'fn_accounting_balance_sheet(uuid, date)'
  ] loop
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end;
$$;

grant select on public.accounting_accounts, public.accounting_cost_centers,
                public.accounting_periods, public.accounting_entries,
                public.accounting_entry_lines, public.accounting_account_mappings,
                public.accounting_settings to authenticated;

grant insert, update, delete on public.accounting_accounts,
      public.accounting_cost_centers, public.accounting_periods,
      public.accounting_account_mappings, public.accounting_settings
      to authenticated;

-- ---------------------------------------------------------------------------
-- 21. Permisos de la app
--
-- Se siembran en `permissions` para que aparezcan en Roles y Permisos y para
-- que `user_has_business_permission` los pueda resolver. Si la tabla no tiene
-- la forma esperada, el bloque no rompe la migración.
-- ---------------------------------------------------------------------------

do $$
begin
  if to_regclass('public.permissions') is null then
    return;
  end if;

  insert into public.permissions (code, name, module, description)
  select v.code, v.name, 'contabilidad', v.description
  from (values
    ('contabilidad.acceso', 'Acceso a contabilidad',
     'Abre el módulo contable y consulta libros y estados financieros.'),
    ('contabilidad.asientos.crear', 'Crear asientos',
     'Registra asientos manuales y genera los automáticos.'),
    ('contabilidad.asientos.anular', 'Revertir asientos',
     'Emite el asiento de reversión de un asiento posteado.'),
    ('contabilidad.catalogo.gestionar', 'Gestionar catálogo de cuentas',
     'Crea y edita cuentas, centros de costo y mapeos contables.'),
    ('contabilidad.periodos.cerrar', 'Cerrar y reabrir períodos',
     'Cierra el mes contable y lo vuelve a abrir.'),
    ('contabilidad.reportes', 'Reportes contables',
     'Balanza, estados financieros y exportaciones contables.')
  ) as v(code, name, description)
  where not exists (
    select 1 from public.permissions p where p.code = v.code);
exception when others then
  raise notice 'Seed de permisos contables omitido: %', sqlerrm;
end;
$$;

commit;

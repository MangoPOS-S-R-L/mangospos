-- =============================================================================
-- 20260926_0001 — Solicitudes de facturación electrónica de OTRAS apps
-- =============================================================================
--
-- Busi Pos Web (flutter_shop+) comparte la cuenta de Alanube y el mismo flujo
-- de alta e-CF, pero corre en su propia base: sus empresas no existen en
-- `businesses` y sus usuarios no existen en este `auth.users`. Cuando alguien
-- allá solicita la facturación electrónica, su servidor avisa acá para que las
-- solicitudes se atiendan en UN SOLO panel y no haya que revisar dos sistemas.
--
-- Esta tabla es solo la bandeja de entrada: quien opera ve la solicitud,
-- contacta al cliente y hace la certificación ante la DGII. El avance real
-- (empresa registrada, secuencias, activación) vive en la base de la app que
-- la pidió, porque es la que tiene que emitir.
--
-- NO guarda el certificado digital ni su contraseña: ésos viajan directo de
-- esa app a Alanube y no pasan por acá.
--
-- La escribe la Edge Function `ecf-request-inbox` con service_role, tras
-- validar el secreto compartido.
-- =============================================================================

begin;

-- Dependencia: `is_platform_operator()` la crea el repo del panel
-- (mangopos_administrador). Fallamos temprano y con mensaje claro en vez de
-- dejar la tabla sin políticas que la protejan.
do $$
begin
  if to_regprocedure('public.is_platform_operator(uuid)') is null then
    raise exception
      'Falta public.is_platform_operator(uuid). Aplica primero la migración '
      '0001_platform_operators.sql del repo mangopos_administrador.';
  end if;
end;
$$;

create table if not exists public.external_ecf_requests (
  id                 uuid primary key default gen_random_uuid(),

  -- Qué app la mandó ('flutter_shop+') y qué empresa es allá. El par
  -- identifica la solicitud: un reenvío actualiza en vez de duplicar.
  source             text not null,
  external_id        text not null,

  company_name       text,
  rnc                text,
  legal_name         text,
  trade_name         text,
  email              text,
  contact_name       text,
  contact_phone      text,
  already_authorized boolean,

  -- ULID de Alanube si esa app alcanzó a registrar la empresa. Null = quedó
  -- pendiente (RNC ya existente, o certificado rechazado) y hay que mirarlo.
  alanube_company_id text,
  company_registered boolean not null default false,

  requested_at       timestamptz,
  received_at        timestamptz not null default now(),

  -- Seguimiento de quien opera.
  status             text not null default 'new'
                       check (status in ('new', 'in_progress', 'done', 'discarded')),
  notes              text,
  handled_by         uuid references auth.users(id),
  handled_at         timestamptz,

  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),

  unique (source, external_id)
);

comment on table public.external_ecf_requests is
  'Bandeja de solicitudes de facturación electrónica que llegan de otras apps '
  'que comparten la cuenta de Alanube (hoy: Busi Pos Web). No guarda el '
  'certificado digital ni su contraseña.';
comment on column public.external_ecf_requests.external_id is
  'Id de la empresa en la app de origen. Con `source` identifica la '
  'solicitud: un reenvío actualiza la fila en vez de duplicarla.';
comment on column public.external_ecf_requests.company_registered is
  'false = la empresa NO quedó registrada en Alanube (RNC ya existente o '
  'certificado rechazado). Esas son las que hay que mirar primero.';

create index if not exists external_ecf_requests_status_idx
  on public.external_ecf_requests (status, received_at desc);

-- ── RLS: solo operadores de la plataforma ───────────────────────────────────
alter table public.external_ecf_requests enable row level security;

drop policy if exists "external_ecf_requests_operator_read" on public.external_ecf_requests;
create policy "external_ecf_requests_operator_read"
  on public.external_ecf_requests
  for select
  using (public.is_platform_operator(auth.uid()));

drop policy if exists "external_ecf_requests_operator_write" on public.external_ecf_requests;
create policy "external_ecf_requests_operator_write"
  on public.external_ecf_requests
  for update
  using (public.is_platform_operator(auth.uid()))
  with check (public.is_platform_operator(auth.uid()));

commit;

notify pgrst, 'reload schema';

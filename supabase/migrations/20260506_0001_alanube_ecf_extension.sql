-- 20260506_0001_alanube_ecf_extension.sql
--
-- Scope:
-- 1) Tabla nueva business_alanube_settings (config de integracion por business).
-- 2) ALTER TABLE fiscal_documents additive: solo punteros y metadata operacional.
--    NO se duplican lineas, totales, XML, payloads, ni nada que viva en Alanube.
-- 3) Audit log fiscal_document_status_events (transiciones de estado).
-- 4) Webhook inbox alanube_webhook_inbox (eventos async de Alanube).
-- 5) RLS reusando user_has_business_access ya existente.
--
-- Principio: Alanube es source of truth de e-CF. Aqui solo guardamos lo minimo
-- necesario para idempotency, receipts impresos sin round-trip, y compliance DGII
-- (10 anos retencion via blob archival con flag xml_archived_at).
--
-- NO toca: issue_fiscal_document(), generate_ncf(), fn_process_payment_v3(),
-- ni ninguna columna preexistente de fiscal_documents. Cambios en esas funciones
-- van en migration siguiente, una vez validado este cimiento.

begin;

-- ============================================================================
-- 1) business_alanube_settings: config Alanube por business
-- ============================================================================
-- Tabla delgada. RNC/razon social/direccion se leen via JOIN a businesses.
-- No duplicamos esos campos.

create table if not exists public.business_alanube_settings (
    id uuid primary key default gen_random_uuid(),
    business_id uuid not null references public.businesses(id) on delete restrict,
    alanube_company_id text unique not null,
    environment text not null
        check (environment in ('sandbox', 'production')),
    certification_status text not null default 'pending'
        check (certification_status in ('pending', 'in_progress', 'certified', 'rejected')),
    mode text not null default 'hybrid'
        check (mode in ('physical', 'electronic', 'hybrid')),
    webhook_secret text,
    webhooks_configured boolean default false,
    notify_by_email boolean default false,
    logo_url text,
    created_at timestamptz default now(),
    updated_at timestamptz default now(),
    unique (business_id, environment)
);

comment on table public.business_alanube_settings is
    'Config de integracion Alanube por business. RNC/razon social viven en businesses (source of truth).';
comment on column public.business_alanube_settings.mode is
    'physical: solo NCF B0x | electronic: solo e-CF Exx | hybrid: ambos coexisten (default mientras DGII migra).';
comment on column public.business_alanube_settings.alanube_company_id is
    'ULID devuelto por Alanube al crear la company. Mapping mangopos<->Alanube.';

-- Trigger updated_at reusa funcion existente
drop trigger if exists set_business_alanube_settings_updated_at on public.business_alanube_settings;
create trigger set_business_alanube_settings_updated_at
    before update on public.business_alanube_settings
    for each row execute function public.trigger_set_updated_at();

-- ============================================================================
-- 2) fiscal_documents: ALTER TABLE additive
-- ============================================================================
-- Solo punteros y metadata operacional. NO duplicamos:
--   - lineas (viven en order_items)
--   - totales/ITBIS (ya existen como subtotal/itbis_amount/total)
--   - request/response payloads (los tiene Alanube)
--   - XML firmado completo (existe ecf_xml legacy para B0x; para Exx queda NULL,
--     se archiva a blob storage externo via job nocturno cuando xml_archived_at IS NULL)

alter table public.fiscal_documents
    add column if not exists alanube_document_id text,
    add column if not exists public_url text,
    add column if not exists xml_url text,
    add column if not exists pdf_url text,
    add column if not exists submitted_at timestamptz,
    add column if not exists accepted_at timestamptz,
    add column if not exists last_error text,
    add column if not exists retry_count integer default 0,
    add column if not exists idempotency_key text,
    add column if not exists xml_archived_at timestamptz;

-- alanube_document_id es UNIQUE (NULL permitidos para B0x fisicos)
do $$
begin
    if not exists (
        select 1 from pg_constraint
        where conname = 'fiscal_documents_alanube_document_id_key'
          and conrelid = 'public.fiscal_documents'::regclass
    ) then
        alter table public.fiscal_documents
            add constraint fiscal_documents_alanube_document_id_key
            unique (alanube_document_id);
    end if;
end$$;

-- Idempotency: misma venta = misma fila, nunca duplicar emision Alanube.
-- Cliente Flutter genera UUID al crear venta. UNIQUE por business.
create unique index if not exists idx_fiscal_docs_idempotency
    on public.fiscal_documents (business_id, idempotency_key)
    where idempotency_key is not null;

-- Index para job de retry/processing: solo docs Exx en transito.
create index if not exists idx_fiscal_docs_pending_emission
    on public.fiscal_documents (business_id, ecf_status, created_at)
    where ecf_status in ('pending', 'sent') and is_electronic = true;

-- Index para reportes contables del cliente.
create index if not exists idx_fiscal_docs_business_created
    on public.fiscal_documents (business_id, created_at desc);

comment on column public.fiscal_documents.alanube_document_id is
    'ULID de Alanube. NULL hasta que Alanube confirma. Source of truth del payload completo vive en Alanube.';
comment on column public.fiscal_documents.idempotency_key is
    'UUID generado por cliente Flutter al crear venta. UNIQUE per business previene doble emision.';
comment on column public.fiscal_documents.last_error is
    'Ultimo error de comunicacion Alanube. NO duplicamos response completo (vive en Alanube).';
comment on column public.fiscal_documents.xml_archived_at is
    'Timestamp cuando XML firmado fue descargado a blob storage propio para retencion DGII (10 anos). NULL = pendiente archival.';
comment on column public.fiscal_documents.public_url is
    'URL publica DGII para verificacion. Solo pointer, no contenido.';

-- ============================================================================
-- 3) fiscal_document_status_events: audit log de transiciones
-- ============================================================================
-- No se borra nunca. Permite responder a auditoria DGII y debugging post-facto.

create table if not exists public.fiscal_document_status_events (
    id uuid primary key default gen_random_uuid(),
    fiscal_document_id uuid not null references public.fiscal_documents(id) on delete cascade,
    previous_status text,
    new_status text not null,
    source text not null
        check (source in ('api_response', 'webhook', 'manual', 'retry_job', 'reconciliation')),
    note text,
    created_at timestamptz default now()
);

create index if not exists idx_fiscal_status_events_doc
    on public.fiscal_document_status_events (fiscal_document_id, created_at desc);

comment on table public.fiscal_document_status_events is
    'Audit log de transiciones de ecf_status. Append-only, nunca borrar.';

-- ============================================================================
-- 4) alanube_webhook_inbox: eventos async de Alanube
-- ============================================================================
-- Endpoint /webhooks/alanube hace insert aqui y responde 200 en <3s.
-- Procesamiento real corre async (Edge Function gatillada por trigger).

create table if not exists public.alanube_webhook_inbox (
    id uuid primary key default gen_random_uuid(),
    event_type text not null,
    payload jsonb not null,
    headers jsonb,
    signature_valid boolean,
    processed boolean default false,
    processed_at timestamptz,
    error text,
    received_at timestamptz default now()
);

create index if not exists idx_webhook_inbox_unprocessed
    on public.alanube_webhook_inbox (processed, received_at)
    where processed = false;

comment on table public.alanube_webhook_inbox is
    'Inbox de webhooks Alanube. Receiver responde 200 rapido y procesador async drena por created_at.';

-- ============================================================================
-- 5) RLS
-- ============================================================================

-- business_alanube_settings: read para usuarios del business; write solo service_role
alter table public.business_alanube_settings enable row level security;

drop policy if exists "bas_select" on public.business_alanube_settings;
create policy "bas_select" on public.business_alanube_settings
    for select to authenticated
    using (public.user_has_business_access(auth.uid(), business_id));

-- fiscal_document_status_events: read si tienes acceso al doc padre
alter table public.fiscal_document_status_events enable row level security;

drop policy if exists "fdse_select" on public.fiscal_document_status_events;
create policy "fdse_select" on public.fiscal_document_status_events
    for select to authenticated
    using (
        exists (
            select 1 from public.fiscal_documents fd
            where fd.id = fiscal_document_status_events.fiscal_document_id
              and public.user_has_business_access(auth.uid(), fd.business_id)
        )
    );

-- alanube_webhook_inbox: NO expuesto a authenticated. Solo service_role.
alter table public.alanube_webhook_inbox enable row level security;
-- (sin policies => default deny para clientes; service_role bypassea RLS)

commit;

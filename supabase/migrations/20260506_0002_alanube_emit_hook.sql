-- 20260506_0002_alanube_emit_hook.sql
--
-- Scope:
-- 1) UNIQUE en business_alanube_settings: pasar de (business_id, environment) a (business_id).
--    Un business = un solo settings. environment es campo, no dimension del UNIQUE.
-- 2) Tabla alanube_emit_outbox: garantia de procesamiento asincrono.
-- 3) Trigger AFTER INSERT en fiscal_documents que encola Exx + pg_notify.
--
-- Principios:
-- - El cobro fisico (B0x) NO debe romperse jamas. Por eso el trigger envuelve
--   toda su logica en EXCEPTION WHEN OTHERS y solo emite RAISE WARNING.
-- - El trigger es 100% no-op para is_electronic=false (return new inmediato).
-- - Outbox + pg_notify: outbox es source of truth para retry/reconciliacion;
--   pg_notify es solo wake-up real-time para Edge Function.

begin;

-- ============================================================================
-- 1) UNIQUE de business_alanube_settings: 1 settings por business
-- ============================================================================
-- Tabla esta vacia (creada en 0001 sin datos), por lo que el cambio es safe.

alter table public.business_alanube_settings
    drop constraint if exists business_alanube_settings_business_id_environment_key;

do $$
begin
    if not exists (
        select 1 from pg_constraint
        where conname = 'business_alanube_settings_business_id_key'
          and conrelid = 'public.business_alanube_settings'::regclass
    ) then
        alter table public.business_alanube_settings
            add constraint business_alanube_settings_business_id_key
            unique (business_id);
    end if;
end$$;

-- ============================================================================
-- 2) alanube_emit_outbox: garantia de procesamiento async
-- ============================================================================
-- Solo punteros + estado de emision. No duplica payload. El procesador
-- (Edge Function) hace fetch del doc + business + items y construye el
-- payload Alanube on-demand desde la fuente de verdad (fiscal_documents + orders + order_items).

create table if not exists public.alanube_emit_outbox (
    id uuid primary key default gen_random_uuid(),
    fiscal_document_id uuid not null unique
        references public.fiscal_documents(id) on delete cascade,
    business_id uuid not null
        references public.businesses(id) on delete restrict,
    settings_id uuid not null
        references public.business_alanube_settings(id) on delete restrict,
    status text not null default 'pending'
        check (status in ('pending', 'processing', 'done', 'failed')),
    attempts integer not null default 0,
    last_attempt_at timestamptz,
    next_attempt_at timestamptz default now(),
    error text,
    created_at timestamptz default now(),
    updated_at timestamptz default now()
);

comment on table public.alanube_emit_outbox is
    'Cola de emision Alanube. Garantia de procesamiento. Edge Function consume por (status=pending, next_attempt_at<=now()).';
comment on column public.alanube_emit_outbox.fiscal_document_id is
    'UNIQUE: un fiscal_document = un job de outbox. Idempotencia natural.';

create index if not exists idx_emit_outbox_pending_due
    on public.alanube_emit_outbox (next_attempt_at)
    where status = 'pending';

create index if not exists idx_emit_outbox_processing
    on public.alanube_emit_outbox (status, last_attempt_at)
    where status = 'processing';

drop trigger if exists set_alanube_emit_outbox_updated_at on public.alanube_emit_outbox;
create trigger set_alanube_emit_outbox_updated_at
    before update on public.alanube_emit_outbox
    for each row execute function public.trigger_set_updated_at();

-- RLS: outbox interno, default deny para clientes. Solo service_role.
alter table public.alanube_emit_outbox enable row level security;

-- ============================================================================
-- 3) Trigger AFTER INSERT en fiscal_documents
-- ============================================================================
-- Encola emision Alanube cuando is_electronic=true y settings configurados.
-- NUNCA falla el INSERT principal (EXCEPTION WHEN OTHERS -> RAISE WARNING).

create or replace function public.fn_alanube_enqueue_emission()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    v_settings_id uuid;
    v_settings_mode text;
begin
    -- Documentos fisicos (B0x): cero impacto. Salida inmediata.
    if new.is_electronic is not true then
        return new;
    end if;

    -- Toda la logica del hook envuelta en exception block.
    -- Bug aqui no debe romper el cobro.
    begin
        select id, mode
          into v_settings_id, v_settings_mode
        from public.business_alanube_settings
        where business_id = new.business_id;

        -- Sin settings: marcar last_error pero no encolar. Admin debe configurar.
        if v_settings_id is null then
            update public.fiscal_documents
            set last_error = 'business_alanube_settings missing - configurar antes de emitir'
            where id = new.id;
            return new;
        end if;

        -- mode='physical': business hibrido eligio no emitir e-CF aun. Skip.
        if v_settings_mode = 'physical' then
            return new;
        end if;

        -- Encolar para emision (idempotente por UNIQUE en fiscal_document_id)
        insert into public.alanube_emit_outbox (fiscal_document_id, business_id, settings_id)
        values (new.id, new.business_id, v_settings_id)
        on conflict (fiscal_document_id) do nothing;

        -- Audit log
        insert into public.fiscal_document_status_events (
            fiscal_document_id, previous_status, new_status, source, note
        ) values (
            new.id, null, 'pending', 'manual', 'enqueued for Alanube emission'
        );

        -- Wake-up real-time (Edge Function suscrito a canal 'alanube_emit')
        perform pg_notify('alanube_emit', new.id::text);

    exception when others then
        -- Ningun bug del hook puede tumbar el cobro. Solo warning a logs.
        raise warning 'fn_alanube_enqueue_emission failed for doc % (business %): %',
            new.id, new.business_id, sqlerrm;
    end;

    return new;
end;
$$;

comment on function public.fn_alanube_enqueue_emission() is
    'Hook AFTER INSERT en fiscal_documents. Encola docs Exx en alanube_emit_outbox y notifica via pg_notify. Falla silente con RAISE WARNING para no romper cobro.';

drop trigger if exists tg_alanube_enqueue_emission on public.fiscal_documents;
create trigger tg_alanube_enqueue_emission
    after insert on public.fiscal_documents
    for each row execute function public.fn_alanube_enqueue_emission();

commit;

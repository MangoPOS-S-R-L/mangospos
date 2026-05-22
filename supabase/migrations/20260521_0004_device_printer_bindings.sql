-- =============================================================================
-- Fase 1 — Printing v2: tabla device_printer_bindings.
--
-- CONTEXTO:
--   Impresoras LAN son alcanzables desde cualquier device del business
--   (cualquiera puede abrir un socket TCP a la IP). Pero impresoras USB
--   y Bluetooth solo pueden imprimir desde el device al que están
--   físicamente conectadas o pareadas.
--
--   Esta tabla registra qué device es el "dueño físico" de cada impresora
--   no-LAN. Cuando el orchestrator decide imprimir en una BT/USB, encola
--   el print_job con `target_device_id = binding.device_id` para que SOLO
--   ese device lo procese.
--
--   Para impresoras LAN, esta tabla es opcional. Si está vacía, el agent
--   más cercano (heartbeat reciente) puede tomar el job.
--
-- DEVICE_ID:
--   Es el `device_id` estable de mangospos generado en
--   `lib/core/printing/device_identity.dart` (UUID hardware en desktop,
--   UUID v4 persistido en mobile/web).
--
-- COMPATIBILIDAD:
--   Tabla nueva, no afecta nada existente. Si está vacía, el
--   comportamiento de impresión LAN actual se mantiene intacto.
-- =============================================================================

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Tabla
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists public.device_printer_bindings (
  device_id text not null,
  printer_id uuid not null references public.printers(id) on delete cascade,
  is_local_owner boolean not null default true,
  paired_at timestamptz not null default now(),
  notes text,
  primary key (device_id, printer_id)
);

create index if not exists idx_device_printer_bindings_printer
  on public.device_printer_bindings (printer_id);

create index if not exists idx_device_printer_bindings_device
  on public.device_printer_bindings (device_id);

comment on table public.device_printer_bindings is
  'Vinculación física device ↔ impresora. Necesario para impresoras USB/BT que solo pueden imprimir desde el device al que están conectadas. Para LAN es opcional.';

comment on column public.device_printer_bindings.is_local_owner is
  'true = este device es el único que puede imprimir físicamente. false = vinculación informativa (ej. para reportes), pero no exclusiva.';

comment on column public.device_printer_bindings.notes is
  'Texto libre para el admin (ej. "PC barra principal, USB puerto 2").';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. RLS
-- ─────────────────────────────────────────────────────────────────────────────

alter table public.device_printer_bindings enable row level security;

-- SELECT: cualquier miembro del business de la impresora puede ver bindings
drop policy if exists "device_printer_bindings_select" on public.device_printer_bindings;
create policy "device_printer_bindings_select"
  on public.device_printer_bindings
  for select
  using (
    exists (
      select 1
      from public.printers p
      join public.memberships m on m.business_id = p.business_id
      where p.id = printer_id
        and m.user_id = auth.uid()
    )
  );

-- WRITE: solo admin/owner/manager
drop policy if exists "device_printer_bindings_write" on public.device_printer_bindings;
create policy "device_printer_bindings_write"
  on public.device_printer_bindings
  for all
  using (
    exists (
      select 1
      from public.printers p
      join public.memberships m on m.business_id = p.business_id
      where p.id = printer_id
        and m.user_id = auth.uid()
        and m.role in ('owner','admin','manager')
    )
  )
  with check (
    exists (
      select 1
      from public.printers p
      join public.memberships m on m.business_id = p.business_id
      where p.id = printer_id
        and m.user_id = auth.uid()
        and m.role in ('owner','admin','manager')
    )
  );

commit;

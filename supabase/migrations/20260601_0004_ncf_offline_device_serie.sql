-- =============================================================================
-- 20260601_0004 — Soporte de NCF offline por serie/dispositivo (F4)
-- =============================================================================
--
-- Habilita la infraestructura para emitir NCF de PAPEL sin conexión usando el
-- mecanismo de `serie` que ya tiene `ncf_sequences`: cada dispositivo emite
-- desde SU serie, con un sub-rango DISJUNTO del rango autorizado del negocio,
-- llevando el contador localmente y conciliando al reconectar.
--
-- Esta migración es SOLO de trazabilidad/marcas (aditiva, segura). NO cambia
-- la mecánica de emisión online ni reparte rangos (eso lo hace el carvado de
-- series, online). La emisión offline real va detrás del flag kOfflineNcfEnabled
-- y NO se enciende sin el visto bueno fiscal (huecos de numeración, etc.).
--
-- ⚠️ FISCAL: partir la numeración en sub-rangos por dispositivo genera huecos
-- en la secuencia, que DGII espera justificables. La política la firma el
-- contador del cliente antes de activar. Ver docs/PRD_OFFLINE_F4_NCF.md.
-- =============================================================================

begin;

-- Traza qué serie pertenece a qué dispositivo (opcional; la mecánica usa
-- `serie`). Nullable: las series "centrales"/online existentes quedan en NULL.
alter table public.ncf_sequences
  add column if not exists device_id uuid;

comment on column public.ncf_sequences.device_id is
  'Dispositivo dueño de esta serie para emisión offline (F4). NULL = serie '
  'central/online. La unicidad real sigue siendo (business_id, ncf_type, serie); '
  'cada serie de dispositivo tiene un sub-rango disjunto del rango autorizado.';

-- Marca los comprobantes emitidos sin conexión, para auditoría y para el
-- visor de huecos que revisará el contador.
alter table public.fiscal_documents
  add column if not exists offline_issued boolean not null default false;

comment on column public.fiscal_documents.offline_issued is
  'True si el comprobante se emitió offline (NCF asignado localmente desde el '
  'rango del dispositivo) y se concilió al reconectar. Default false.';

commit;

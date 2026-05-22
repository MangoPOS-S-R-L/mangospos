-- =============================================================================
-- Printing v2 — Slice B: multi-copia simultánea por tipo de comprobante.
--
-- CONTEXTO:
--   Por default, cuando hay >1 impresora configurada para precheck o
--   receipt, mangospos muestra un picker al cajero (Slice 1+2+3). Pero
--   hay setups operativos donde se quiere imprimir SIEMPRE en TODAS las
--   impresoras del tipo (ej. recibo en caja + copia en archivo, o
--   precuenta en mesero + duplicado en caja).
--
--   Estos 2 flags activan ese modo "multi-copia automática". Cuando
--   están en true, el orchestrator salta el picker y dispara N print
--   jobs paralelos.
--
-- COMPATIBILIDAD:
--   Default false en ambos → comportamiento actual (con picker).
--   Setting per-business, no per-device.
-- =============================================================================

begin;

alter table public.business_settings
  add column if not exists print_precheck_multi_copy boolean not null default false;

alter table public.business_settings
  add column if not exists print_receipt_multi_copy boolean not null default false;

comment on column public.business_settings.print_precheck_multi_copy is
  'Si true, las pre-cuentas se imprimen automáticamente en TODAS las '
  'impresoras configuradas con prints_prebills=true (sin picker). '
  'Default false = picker o fijada (comportamiento Slice 1+2).';

comment on column public.business_settings.print_receipt_multi_copy is
  'Si true, los recibos post-pago se imprimen automáticamente en TODAS '
  'las impresoras configuradas con prints_receipts=true (sin picker). '
  'Default false = picker o fijada (comportamiento Slice 3).';

commit;

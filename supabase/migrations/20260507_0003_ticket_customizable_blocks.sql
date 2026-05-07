-- 20260507_0003_ticket_customizable_blocks.sql
--
-- Scope: permitir al negocio reordenar y activar/desactivar los bloques
-- del header y del footer del ticket (factura y pre-cuenta usan la misma
-- config). Reemplaza los 3 toggles individuales del commit 0001
-- (print_logo_on_invoice, show_slogan_on_invoice,
-- show_branch_name_on_invoice) por una lista ordenada por bloque.
--
-- Cambios:
--   1. business_settings: 2 columnas JSONB con la lista ordenada de
--      bloques. Cada elemento {key: <slug>, enabled: <bool>}.
--   2. Backfill: respetar los toggles viejos (logo off, slogan/branch
--      on por default). Los toggles viejos quedan en DB pero ya no se
--      leen para rendering — se pueden borrar en una migration futura
--      cuando confirmemos que ningun cliente legacy depende de ellos.
--
-- Bloques estandar (mismos para factura y pre-cuenta):
--   Header: logo, business_name, slogan, legal_name, branch_name,
--           address, phone, email, rnc.
--   Footer: footer_message (texto custom), thank_you ("GRACIAS POR
--           SU PREFERENCIA").
--
-- Items NO customizables (compliance DGII Norma 01-2020):
--   e-NCF, tabla de productos, subtotal/ITBIS/total, QR + codigo de
--   seguridad, mesa/mesero/orden/fecha. Esos quedan hardcoded.

begin;

-- ============================================================================
-- 1) Columnas nuevas en business_settings
-- ============================================================================

alter table public.business_settings
  add column if not exists ticket_header_blocks jsonb,
  add column if not exists ticket_footer_blocks jsonb;

comment on column public.business_settings.ticket_header_blocks is
  'Lista ordenada de bloques del header del ticket (factura + pre-cuenta). '
  'Formato: [{"key": "logo", "enabled": true}, {"key": "business_name", "enabled": true}, ...]. '
  'Keys validas: logo, business_name, slogan, legal_name, branch_name, address, phone, email, rnc. '
  'Solo se renderizan los enabled=true en el orden de la lista. '
  'Null o vacio: PrintTicketService cae al rendering hardcoded legacy.';

comment on column public.business_settings.ticket_footer_blocks is
  'Lista ordenada de bloques del footer del ticket. '
  'Formato igual a ticket_header_blocks. '
  'Keys validas: footer_message, thank_you. '
  'Null o vacio: PrintTicketService cae al rendering hardcoded legacy.';

-- ============================================================================
-- 2) Backfill: traducir toggles viejos a la nueva lista
-- ============================================================================

-- Para cada row existente, generamos el JSON respetando los flags viejos.
-- COALESCE para defaults sensatos cuando los toggles aun no existen
-- (e.g. business_settings creado antes de migration 0001).
update public.business_settings
set ticket_header_blocks = jsonb_build_array(
  jsonb_build_object('key', 'logo',          'enabled', coalesce(print_logo_on_invoice, false)),
  jsonb_build_object('key', 'business_name', 'enabled', true),
  jsonb_build_object('key', 'slogan',        'enabled', coalesce(show_slogan_on_invoice, true)),
  jsonb_build_object('key', 'legal_name',    'enabled', true),
  jsonb_build_object('key', 'branch_name',   'enabled', coalesce(show_branch_name_on_invoice, true)),
  jsonb_build_object('key', 'address',       'enabled', true),
  jsonb_build_object('key', 'phone',         'enabled', true),
  jsonb_build_object('key', 'email',         'enabled', false),
  jsonb_build_object('key', 'rnc',           'enabled', true)
)
where ticket_header_blocks is null;

update public.business_settings
set ticket_footer_blocks = jsonb_build_array(
  jsonb_build_object('key', 'footer_message', 'enabled', true),
  jsonb_build_object('key', 'thank_you',      'enabled', true)
)
where ticket_footer_blocks is null;

-- ============================================================================
-- 3) Defaults para rows nuevos
-- ============================================================================

-- Default JSONB literal: aplica a INSERTs futuros que no especifiquen el
-- campo. Coincide con el backfill arriba.
alter table public.business_settings
  alter column ticket_header_blocks set default jsonb_build_array(
    jsonb_build_object('key', 'logo',          'enabled', false),
    jsonb_build_object('key', 'business_name', 'enabled', true),
    jsonb_build_object('key', 'slogan',        'enabled', true),
    jsonb_build_object('key', 'legal_name',    'enabled', true),
    jsonb_build_object('key', 'branch_name',   'enabled', true),
    jsonb_build_object('key', 'address',       'enabled', true),
    jsonb_build_object('key', 'phone',         'enabled', true),
    jsonb_build_object('key', 'email',         'enabled', false),
    jsonb_build_object('key', 'rnc',           'enabled', true)
  );

alter table public.business_settings
  alter column ticket_footer_blocks set default jsonb_build_array(
    jsonb_build_object('key', 'footer_message', 'enabled', true),
    jsonb_build_object('key', 'thank_you',      'enabled', true)
  );

commit;

-- ============================================================================
-- Smoke check
-- ============================================================================
-- 1. Verificar columnas:
--    select column_name, data_type from information_schema.columns
--    where table_name = 'business_settings'
--      and column_name like 'ticket_%_blocks';
--
-- 2. Verificar backfill (debe haber 2 jsonb arrays por cada row):
--    select business_id,
--           jsonb_array_length(ticket_header_blocks) as header_count,
--           jsonb_array_length(ticket_footer_blocks) as footer_count
--    from public.business_settings;

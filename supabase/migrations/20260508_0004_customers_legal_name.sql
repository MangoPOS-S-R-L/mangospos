-- =============================================================================
-- Migration: agregar customers.legal_name (razón social)
-- Purpose : Separar nombre comercial (campo `name` existente) de razón social
--           legal. e-CF DGII requiere razón social en el comprobante,
--           distinta del nombre comercial que se muestra al cajero.
--
-- Ejemplo:
--   name        = "Banco Popular"             (nombre comercial / display)
--   legal_name  = "BANCO POPULAR DOMINICANO S A BANCO MULTIPLE"  (e-CF)
--
-- Compat: columna nullable. Filas existentes la dejan en NULL hasta
-- que el admin haga lookup DGII y refresque sus clientes. Sin cambios
-- en flows existentes.
-- =============================================================================

-- pg_trgm habilita el operador gin_trgm_ops usado en el índice de
-- búsqueda parcial. Es no-op si ya está instalada (común en Supabase).
CREATE EXTENSION IF NOT EXISTS pg_trgm;

ALTER TABLE public.customers
  ADD COLUMN IF NOT EXISTS legal_name text;

COMMENT ON COLUMN public.customers.legal_name IS
  'Razón social legal según padrón DGII. Se usa en e-CF / facturas con NCF. '
  'Nullable: legacy customers la dejan vacía hasta el próximo lookup DGII.';

-- Índice GIN trigram para búsqueda ilike rápida sobre razón social
-- (los queries del repo usan ilike con %{q}% — sin este índice serían
-- full-table scans).
CREATE INDEX IF NOT EXISTS idx_customers_legal_name
  ON public.customers
  USING gin (lower(legal_name) gin_trgm_ops)
  WHERE legal_name IS NOT NULL;

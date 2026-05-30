-- =============================================================================
-- DRY-RUN preview del backfill 20260530_0003.
--
-- Corré ESTE script ANTES de aplicar la migración real. No modifica nada,
-- solo muestra qué NCFs se tocarían y qué nuevo total tendría cada uno.
--
-- Sirve para:
--   1. Confirmar que el conjunto de outliers no cambió desde el diagnóstico
--   2. Ver el delta exacto por NCF (sanity check de que ningún NCF se baja)
--   3. Verificar que el delta total ≈ RD$ 17,560
--
-- Si los números cuadran con lo esperado, aplicar las 3 migraciones en
-- orden: 0001 (fix función) → 0002 (trigger) → 0003 (backfill).
--
-- Pre-requisito: aplicar 20260530_0001_fix_fn_recompute_fd_for_scope.sql
-- ANTES de este preview. Sin la función corregida, el preview muestra el
-- mismo bug (cero corrección). Después podés revertir 0001 con su
-- ROLLBACK si querés re-evaluar antes de aplicar definitivo.
--
-- Alternativa segura sin tocar la función: el query principal abajo
-- calcula el "total correcto" leyendo payments por fd_id (replica la
-- lógica nueva sin invocar la función), así podés correrlo SIN aplicar
-- 0001 todavía.
-- =============================================================================

-- Preview 1: detalle de cada NCF que se tocaría
WITH outliers AS (
  SELECT
    fd.id,
    fd.ncf_number,
    fd.ncf_type,
    fd.issued_at::date AS fecha,
    fd.total AS total_actual,
    (
      SELECT COALESCE(SUM(p.amount - COALESCE(p.change_amount, 0)), 0)
      FROM public.payments p
      WHERE p.fiscal_document_id = fd.id
        AND p.status = 'completed'
    )::numeric(12,2) AS total_si_backfill,
    fd.order_id,
    fd.check_id,
    (SELECT COUNT(*) FROM public.payments p
       WHERE p.fiscal_document_id = fd.id AND p.status = 'completed') AS payments_count
  FROM public.fiscal_documents fd
  WHERE fd.business_id = '33207ebd-985d-455c-bdbb-1b38af8b36ea'
    AND fd.status = 'active'
    AND fd.issued_at >= '2026-05-01' AND fd.issued_at < '2026-06-01'
    AND (
      SELECT COALESCE(SUM(p.amount - COALESCE(p.change_amount, 0)), 0)
      FROM public.payments p
      WHERE p.fiscal_document_id = fd.id AND p.status = 'completed'
    ) > fd.total + 1
)
SELECT
  ncf_number,
  ncf_type,
  fecha,
  total_actual,
  total_si_backfill,
  (total_si_backfill - total_actual)::numeric(12,2) AS delta,
  payments_count,
  order_id,
  check_id
FROM outliers
ORDER BY (total_si_backfill - total_actual) DESC;

-- Preview 2: resumen agregado
WITH outliers AS (
  SELECT
    fd.id,
    fd.total AS total_actual,
    (
      SELECT COALESCE(SUM(p.amount - COALESCE(p.change_amount, 0)), 0)
      FROM public.payments p
      WHERE p.fiscal_document_id = fd.id AND p.status = 'completed'
    )::numeric(12,2) AS total_si_backfill
  FROM public.fiscal_documents fd
  WHERE fd.business_id = '33207ebd-985d-455c-bdbb-1b38af8b36ea'
    AND fd.status = 'active'
    AND fd.issued_at >= '2026-05-01' AND fd.issued_at < '2026-06-01'
    AND (
      SELECT COALESCE(SUM(p.amount - COALESCE(p.change_amount, 0)), 0)
      FROM public.payments p
      WHERE p.fiscal_document_id = fd.id AND p.status = 'completed'
    ) > fd.total + 1
)
SELECT
  COUNT(*) AS ncfs_a_corregir,
  ROUND(SUM(total_actual)::numeric, 2) AS sum_total_actual,
  ROUND(SUM(total_si_backfill)::numeric, 2) AS sum_total_post_backfill,
  ROUND(SUM(total_si_backfill - total_actual)::numeric, 2) AS delta_total,
  MIN(total_actual) AS min_total_actual,
  MAX(total_actual) AS max_total_actual,
  COUNT(*) FILTER (WHERE total_si_backfill < total_actual) AS ncfs_que_BAJARIAN
FROM outliers;

-- Preview 3: validar que no haya NCFs sospechosos donde el "nuevo total"
-- excede dramáticamente lo razonable (más de 10× el actual). Si aparece
-- alguno, hay que investigar antes de aplicar.
WITH outliers AS (
  SELECT
    fd.id,
    fd.ncf_number,
    fd.total AS total_actual,
    (
      SELECT COALESCE(SUM(p.amount - COALESCE(p.change_amount, 0)), 0)
      FROM public.payments p
      WHERE p.fiscal_document_id = fd.id AND p.status = 'completed'
    )::numeric(12,2) AS total_si_backfill
  FROM public.fiscal_documents fd
  WHERE fd.business_id = '33207ebd-985d-455c-bdbb-1b38af8b36ea'
    AND fd.status = 'active'
    AND fd.issued_at >= '2026-05-01' AND fd.issued_at < '2026-06-01'
)
SELECT
  ncf_number,
  total_actual,
  total_si_backfill,
  ROUND((total_si_backfill / NULLIF(total_actual, 0))::numeric, 2) AS ratio
FROM outliers
WHERE total_si_backfill > total_actual * 10
ORDER BY ratio DESC;

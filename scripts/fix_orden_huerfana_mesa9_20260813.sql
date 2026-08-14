-- ============================================================================
-- RECUPERAR el consumo huérfano de MESA9 — Sophisticated Managment SRL
-- Negocio : f054fbc2-3fb7-4e34-a020-11341ff11d84
-- Orden   : f5ab74d7-006f-44ab-be61-b6d187c676f1  (cliente nathalia, RD$200.00)
-- Sesión  : 8a76adcc-2180-4970-9ce2-47bc7709d237  (cerrada por error 11:43:18)
--
-- ⚠ ESCRIBE EN LA BD. Correr el PASO 0 primero y elegir UNA sola vía.
-- ============================================================================

-- ─── PASO 0 (OBLIGATORIO): ¿cómo está MESA9 AHORA MISMO? ──────────────────
-- Decide qué vía usar:
--   sesiones_abiertas = 0  → VÍA A (reabrir la sesión original)
--   sesiones_abiertas >= 1 → VÍA B (mudar la orden a la sesión que está viva;
--                            reabrir la vieja dejaría DOS sesiones abiertas en
--                            la misma mesa y `fn_open_table` tomaría la más
--                            reciente, dejando la otra invisible otra vez)
SELECT
  dt.id                                              AS table_id,
  dt.code                                            AS mesa,
  dt.state                                           AS estado_actual,
  count(ts.id) FILTER (WHERE ts.closed_at IS NULL)   AS sesiones_abiertas,
  max(ts.id::text) FILTER (WHERE ts.closed_at IS NULL) AS session_abierta_id
FROM public.dining_tables dt
LEFT JOIN public.table_sessions ts ON ts.table_id = dt.id
WHERE dt.id = (
  SELECT table_id FROM public.table_sessions
  WHERE id = '8a76adcc-2180-4970-9ce2-47bc7709d237'
)
GROUP BY dt.id, dt.code, dt.state;


-- ═══ VÍA A — MESA9 LIBRE: reabrir la sesión original ══════════════════════
-- La cuenta de Nathalia reaparece en el salón tal cual quedó y se cobra normal.
/*
BEGIN;

UPDATE public.table_sessions
   SET closed_at = NULL
 WHERE id = '8a76adcc-2180-4970-9ce2-47bc7709d237'
   AND closed_at IS NOT NULL;

UPDATE public.dining_tables dt
   SET state = 'occupied'
  FROM public.table_sessions ts
 WHERE ts.id = '8a76adcc-2180-4970-9ce2-47bc7709d237'
   AND dt.id = ts.table_id;

-- Verificar ANTES de confirmar: 1 fila, closed_at NULL, mesa 'occupied'.
SELECT ts.id, ts.closed_at, dt.code, dt.state
  FROM public.table_sessions ts
  JOIN public.dining_tables dt ON dt.id = ts.table_id
 WHERE ts.id = '8a76adcc-2180-4970-9ce2-47bc7709d237';

COMMIT;   -- o ROLLBACK; si algo no cuadra
*/


-- ═══ VÍA B — MESA9 YA TIENE OTRA SESIÓN ABIERTA ═══════════════════════════
-- Mueve la orden huérfana a la sesión viva: el plato de Nathalia aparece en la
-- cuenta que está abierta en la mesa ahora. Sustituye <SESSION_ABIERTA> por el
-- id que devolvió el PASO 0.
/*
BEGIN;

UPDATE public.orders
   SET session_id = '<SESSION_ABIERTA>'
 WHERE id = 'f5ab74d7-006f-44ab-be61-b6d187c676f1'
   AND closed_at IS NULL;

SELECT o.id, o.session_id, o.status_ext, o.total, dt.code AS mesa, ts.closed_at
  FROM public.orders o
  JOIN public.table_sessions ts ON ts.id = o.session_id
  JOIN public.dining_tables dt  ON dt.id = ts.table_id
 WHERE o.id = 'f5ab74d7-006f-44ab-be61-b6d187c676f1';

COMMIT;
*/


-- ═══ VÍA C — NO SE VA A COBRAR: dejarla anulada y que deje de ensuciar ════
-- Solo si el dueño decide asumir la pérdida. Deja rastro real (no la borra).
/*
BEGIN;

UPDATE public.orders
   SET status_ext = 'void',
       closed_at  = now()
 WHERE id = 'f5ab74d7-006f-44ab-be61-b6d187c676f1'
   AND closed_at IS NULL;

UPDATE public.order_items
   SET status = 'void'
 WHERE order_id = 'f5ab74d7-006f-44ab-be61-b6d187c676f1'
   AND status NOT IN ('paid','void');

COMMIT;
*/


-- ─── LIMPIEZA APARTE: la orden gemela vacía ───────────────────────────────
-- 9ac906b3 quedó con status_ext='void' pero status='open' y closed_at con el
-- desfase de 4 h. No afecta a nadie, pero si quieres dejarla coherente:
/*
UPDATE public.orders
   SET status = 'canceled',
       closed_at = '2026-08-13 15:43:17.822887+00'   -- la hora REAL (UTC)
 WHERE id = '9ac906b3-3cca-4ce0-8143-81147b09d0ae';
*/

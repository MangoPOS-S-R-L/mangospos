-- =============================================================================
-- Cleanup de payments duplicados detectados el 2026-05-09
--
-- Contexto: el RPC fn_process_payment_v3 ya tiene guard atomico (migration
-- 20260509_0001), pero quedaron 3 rows duplicados en `payments` de antes:
--
--   Orden 54a9...128d: payment 12ad6a4f...  (sin fiscal_document)
--   Orden 25e9...1052: payment bc973eed... (sin fiscal_document)
--   Orden 25e9...1052: payment 3e3a81f5... (sin fiscal_document)
--
-- Cada orden tiene UN payment valido con fiscal_document_id no nulo. Los
-- duplicados los marcamos status='cancelled' (preservamos audit trail).
-- 'void' no esta permitido por el check constraint payments_status_check
-- (valores validos: pending, completed, refunded, cancelled). Si los
-- duplicados son cash, tambien tenemos que borrar las cash_transactions
-- correspondientes para no inflar el cuadre de caja.
--
-- Como correrlo:
--   1. Lee SECCION 1 (preview): confirma que las 3 rows son las correctas.
--   2. Lee SECCION 2 (cash_transactions): ve si hay rows de tipo 'sale' que
--      tambien hay que limpiar. Si no las hay (eran tarjeta/transferencia),
--      la SECCION 2 devuelve vacio y no necesitas hacer nada extra.
--   3. Si todo se ve bien, cambia el ROLLBACK del final por COMMIT y corre
--      el bloque entero. Si no, deja ROLLBACK y abortas.
--
-- Caja sigue abierta (segun confirmacion del usuario), asi que el cleanup
-- se refleja en el cuadre antes del cierre. Idempotente: re-correr no hace
-- nada porque el WHERE filtra por status='completed'.
-- =============================================================================

BEGIN;

-- ─── SECCION 1: preview de los payments antes del cambio ──────────────────
SELECT
  p.id              AS payment_id,
  p.order_id,
  p.check_id,
  p.amount,
  p.status          AS status_before,
  p.fiscal_document_id,
  pm.code           AS method_code,
  p.created_at,
  p.session_id      AS cash_session_id
FROM public.payments p
LEFT JOIN public.payment_methods pm ON pm.id = p.payment_method_id
WHERE p.id IN (
  '12ad6a4f-e82e-4f5a-ba49-fb38b1cda590',
  'bc973eed-25dd-4d62-aa14-e6a4ed581f18',
  '3e3a81f5-5e32-4aef-b966-b3cbd2288a47'
)
ORDER BY p.created_at;


-- ─── SECCION 2: cash_transactions asociadas (si los duplicados fueron cash)
-- Heuristica TIGHT: now() es constante dentro de una transaccion Postgres,
-- asi que payment.created_at == cash_tx.created_at cuando ambos vienen del
-- mismo RPC. Usamos ventana < 1s y DISTINCT ON (p.id) para que cada
-- duplicado matchee solo SU cash_tx (la mas cercana en tiempo).
--
-- Sin esto, si hay 3 cash_tx dentro de 30s para la misma orden, el join
-- cruzado matchearia hasta la cash_tx del payment BUENO contra los
-- duplicados -> al borrar la caja quedaria short.
SELECT DISTINCT ON (p.id)
  ct.id                  AS cash_tx_id,
  ct.session_id,
  ct.related_order_id,
  ct.amount              AS cash_tx_amount,
  ct.type                AS cash_tx_type,
  ct.description,
  ct.created_at          AS cash_tx_created_at,
  p.id                   AS dup_payment_id,
  p.amount               AS dup_payment_amount,
  p.created_at           AS dup_payment_created_at
FROM public.payments p
JOIN public.cash_transactions ct
  ON p.session_id        = ct.session_id
 AND p.order_id          = ct.related_order_id
 AND ct.type             = 'sale'
 AND abs(extract(epoch from (p.created_at - ct.created_at))) < 1.0
 AND abs(p.amount - coalesce(p.change_amount, 0) - ct.amount) < 0.01
WHERE p.id IN (
  '12ad6a4f-e82e-4f5a-ba49-fb38b1cda590',
  'bc973eed-25dd-4d62-aa14-e6a4ed581f18',
  '3e3a81f5-5e32-4aef-b966-b3cbd2288a47'
)
ORDER BY p.id, abs(extract(epoch from (p.created_at - ct.created_at)));


-- ─── SECCION 3: cancelar los payments duplicados ──────────────────────────
-- Filtros de seguridad: status='completed' y fiscal_document_id IS NULL
-- (asi nunca tocamos el payment "bueno" que tiene NCF). Idempotente.
-- Usamos status='cancelled' porque 'void' no esta en el check constraint.
UPDATE public.payments
SET status = 'cancelled'
WHERE id IN (
  '12ad6a4f-e82e-4f5a-ba49-fb38b1cda590',
  'bc973eed-25dd-4d62-aa14-e6a4ed581f18',
  '3e3a81f5-5e32-4aef-b966-b3cbd2288a47'
)
  AND status = 'completed'
  AND fiscal_document_id IS NULL
RETURNING id, order_id, amount, status AS status_after;


-- ─── SECCION 4: DELETE de las cash_transactions correspondientes ─────────
-- Misma heuristica TIGHT que SECCION 2: ventana < 1s + DISTINCT ON (p.id)
-- para garantizar que cada duplicado matchee solo SU cash_tx. Si los 3
-- duplicados eran tarjeta/transferencia, esto borra 0 rows.
DELETE FROM public.cash_transactions
WHERE id IN (
  SELECT DISTINCT ON (p.id) ct.id
  FROM public.payments p
  JOIN public.cash_transactions ct
    ON p.session_id        = ct.session_id
   AND p.order_id          = ct.related_order_id
   AND ct.type             = 'sale'
   AND abs(extract(epoch from (p.created_at - ct.created_at))) < 1.0
   AND abs(p.amount - coalesce(p.change_amount, 0) - ct.amount) < 0.01
  WHERE p.id IN (
    '12ad6a4f-e82e-4f5a-ba49-fb38b1cda590',
    'bc973eed-25dd-4d62-aa14-e6a4ed581f18',
    '3e3a81f5-5e32-4aef-b966-b3cbd2288a47'
  )
  ORDER BY p.id, abs(extract(epoch from (p.created_at - ct.created_at)))
)
RETURNING id, session_id, related_order_id, amount;


-- ─── SECCION 5: verificacion final ────────────────────────────────────────
SELECT
  p.id              AS payment_id,
  p.order_id,
  p.amount,
  p.status          AS status_after,
  p.fiscal_document_id
FROM public.payments p
WHERE p.id IN (
  '12ad6a4f-e82e-4f5a-ba49-fb38b1cda590',
  'bc973eed-25dd-4d62-aa14-e6a4ed581f18',
  '3e3a81f5-5e32-4aef-b966-b3cbd2288a47'
)
ORDER BY p.created_at;


-- IMPORTANTE: ya revisado y aprobado en sesion 2026-05-09. Persistir.
-- ROLLBACK;
COMMIT;

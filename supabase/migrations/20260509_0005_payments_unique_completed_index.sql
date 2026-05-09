-- =============================================================================
-- Belt-and-suspenders: UNIQUE INDEX que prohibe fisicamente 2 payments
-- 'completed' para la misma (order_id, check_id) combinacion.
--
-- Contexto:
--   Migration 20260509_0001 agrego un guard atomico (SELECT FOR UPDATE +
--   verificacion de orden cerrada) en fn_process_payment_v3. La verificacion
--   confirmo que el cuerpo deployed tiene el lock correcto.
--
--   Pero el 2026-05-09 detectamos 4 ordenes con duplicado (payments=2x el
--   total de la orden), todas creadas DESPUES del deploy del guard. Spread
--   1.9-4.2s entre payments. El order.closed_at coincide con el SEGUNDO
--   payment, lo que sugiere que el FOR UPDATE no esta serializando como se
--   esperaba (posible quirk de PostgREST + PgBouncer en transaction mode).
--
--   En lugar de seguir investigando el por que del race, agregamos una
--   garantia a nivel de Postgres: el indice unico parcial bloquea fisicamente
--   un INSERT que viole la restriccion. Si el guard del RPC falla, el
--   constraint hace que el INSERT tire `unique_violation` (codigo 23505) y
--   el cliente Dart cae al fallback (que ya maneja el caso devolviendo el
--   payment existente).
--
-- Trade-off:
--   - Para split-checks (check_id NOT NULL): cada check tiene su propio
--     payment completed. La unique permite eso porque la PK del indice
--     incluye check_id.
--   - Para split full-order (check_id IS NULL, varios payments para la
--     misma orden con metodos distintos): este indice los BLOQUEA. Eso es
--     consistente con el comportamiento del RPC v3 que cierra la orden al
--     primer payment full-order — el flujo correcto para split full-order
--     es usar checks. Si en el futuro queremos full-order split nativo,
--     necesitaremos un schema distinto (campo `is_split` o status
--     `partially_paid` antes de cerrar).
--
-- COALESCE de check_id:
--   PostgreSQL trata NULL como distinct en indices unicos por default
--   (multiple rows con check_id=NULL pueden coexistir). Forzamos a un UUID
--   sentinel para que el indice trate "sin check" como un valor concreto.
-- =============================================================================

CREATE UNIQUE INDEX IF NOT EXISTS payments_unique_completed_per_check
ON public.payments (
  order_id,
  COALESCE(check_id, '00000000-0000-0000-0000-000000000000'::uuid)
)
WHERE status = 'completed';

COMMENT ON INDEX public.payments_unique_completed_per_check IS
  'Prohibe 2 payments completed para la misma (order_id, check_id). '
  'Defensa fisica contra duplicate-payment bug 20260509_0001.';

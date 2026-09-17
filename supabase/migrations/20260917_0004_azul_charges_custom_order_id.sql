-- ===========================================================================
-- 20260917_0004 — CustomOrderId en cada cobro de suscripción
--
-- POR QUÉ
-- Cuando la llamada a Azul se cae DESPUÉS de que Azul aprobó la venta (timeout
-- del sidecar, worker que muere), la fila queda en `error` o `pending` y el
-- siguiente intento vuelve a cobrar: el cliente paga dos veces. Tropella
-- Coffee (13/07/2026) tiene ese patrón en la bitácora.
--
-- No había forma de preguntarle a Azul "¿pasó ese cobro?": VerifyPayment
-- busca por CustomOrderId, y los cobros no mandaban ninguno.
--
-- Con esta columna, azul-charge-subscription:
--   * manda un CustomOrderId único por cobro (el mismo en sus reintentos);
--   * ANTES de reintentar un `error` o un `pending` viejo, consulta
--     VerifyPayment. Si Azul ya lo cobró, lo registra como aprobado sin volver
--     a cobrar; si no lo encuentra, reintenta; si no puede saberlo, no cobra.
--
-- Los cobros viejos (sin CustomOrderId) no se pueden verificar: si alguno
-- queda en `error`/`pending`, la función NO lo reintenta solo. Ver
-- supabase/VERIFICAR_20260917_0004_custom_order_id.sql para encontrarlos y
-- resolverlos a mano.
--
-- ORDEN DE DESPLIEGUE: esta migración ANTES de desplegar la función. La
-- función nueva escribe esta columna; sin ella el INSERT falla y no cobra.
--
-- Idempotente. Rollback: 20260917_0004_azul_charges_custom_order_id_ROLLBACK.sql
-- ===========================================================================

begin;

alter table public.azul_charges
  add column if not exists custom_order_id text;

-- Único: es la llave con la que VerifyPayment encuentra la venta. Dos cobros
-- con el mismo CustomOrderId harían que la verificación de uno responda por
-- el otro.
create unique index if not exists azul_charges_custom_order_id_key
  on public.azul_charges (custom_order_id)
  where custom_order_id is not null;

comment on column public.azul_charges.custom_order_id is
  'CustomOrderId enviado a Azul en la venta (único por cobro, se repite en sus '
  'reintentos). Llave de VerifyPayment para saber si un intento con resultado '
  'desconocido se cobró. NULL en cobros anteriores a 20260917_0004.';

commit;

notify pgrst, 'reload schema';

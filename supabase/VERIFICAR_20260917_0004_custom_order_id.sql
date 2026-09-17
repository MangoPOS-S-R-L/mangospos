-- =============================================================================
-- VERIFICAR 20260917_0004 — cobros que la función nueva NO va a reintentar sola
--
-- Correr DESPUÉS de aplicar la migración y ANTES (o justo después) de desplegar
-- la versión nueva de azul-charge-subscription. Solo lee.
--
-- La función nueva verifica con Azul (VerifyPayment por CustomOrderId) antes de
-- reintentar un cobro en `error` o `pending`. Los cobros creados antes de esta
-- migración no tienen CustomOrderId: no se pueden verificar, así que la función
-- responde 409 "unverifiable_previous_attempt" y no cobra. Lo normal es que esta
-- consulta devuelva CERO filas. Si devuelve alguna, se resuelve a mano (abajo).
-- =============================================================================

select c.id                                   as charge_id,
       b.business_name                        as negocio,
       c.status                               as estado,
       c.order_number,
       c.billing_period_start                 as periodo,
       c.attempt_number                       as intento,
       to_char(c.amount_cents / 100.0, 'FM999,999,990.00') as monto_rd,
       to_char(c.attempted_at at time zone 'America/Santo_Domingo',
               'DD/MM/YYYY HH24:MI')          as intentado
  from public.azul_charges c
  join public.businesses b on b.id = c.business_id
 where c.status in ('error', 'pending')
   and c.custom_order_id is null
 order by c.attempted_at desc;

-- -----------------------------------------------------------------------------
-- CÓMO RESOLVER CADA FILA
--
-- (0) Monto RD$0.00 → NO es un cobro por resolver. Es una suscripción con
--     precio efectivo 0 (plan gratis o precio especial en 0) que el cron
--     encolaba igual: Azul rechaza la venta y la fila queda en `error`. No se
--     movió dinero y no hace falta tocar la fila. Lo que la frena es
--     20260915_0007_cron_skip_zero_price.sql (el cron deja de encolarla) y la
--     guarda zero_amount de azul-charge-subscription. No usar (a): solo
--     volvería a mandar RD$0. Caso visto el 17/09/2026: "cristian".
--
-- Para el resto, primero buscar el OrderNumber en el portal de Azul.
--
-- (a) Azul NO tiene esa venta → habilitar el reintento verificado. Se le asigna
--     el CustomOrderId normal; la función lo verifica (Azul no lo encuentra) y
--     recién ahí cobra:
--
--   update public.azul_charges
--      set custom_order_id = 'mpch-' || replace(id::text, '-', '')
--    where id = '<charge_id>'
--      and custom_order_id is null;
--
-- (b) Azul SÍ tiene la venta aprobada → registrarla como aprobada con los datos
--     del portal y poner la suscripción al día. NO habilitar el reintento: sería
--     el cobro doble.
--
--   update public.azul_charges
--      set status = 'approved',
--          azul_order_id = '<AzulOrderId del portal>',
--          authorization_code = '<autorización del portal>',
--          completed_at = now()
--    where id = '<charge_id>';
--
--   update public.memberships m
--      set billing_status = 'active',
--          current_attempt_number = 0,
--          last_successful_charge_id = c.id,
--          current_period_start = c.billing_period_start,
--          current_period_end = (c.billing_period_start + interval '1 month')::date,
--          next_billing_date = (c.billing_period_start + interval '1 month')::date
--     from public.azul_charges c
--    where c.id = '<charge_id>'
--      and m.id = c.membership_id;
-- -----------------------------------------------------------------------------

-- ============================================================================
-- ¿Qué negocios pagaron con TARJETA este mes y el mes pasado?
--
-- Dos fuentes distintas de "pago con tarjeta":
--   A) public.azul_charges  → cobro automático de la suscripción vía Azul
--                             (DataVault). status='approved' = cobro real.
--   B) public.membership_invoices → factura que un operador marcó pagada a
--                             mano; payment_method es texto libre ('card',
--                             'tarjeta', 'visa'…), por eso el match es ILIKE.
--
-- Meses en hora de RD (America/Santo_Domingo, UTC-4 sin horario de verano):
-- "mes actual" = mes calendario en curso, "mes pasado" = el inmediato anterior.
-- Montos de azul_charges están en centavos → se dividen entre 100.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1) RESUMEN — un renglón por negocio, columnas para cada mes (solo Azul)
-- ---------------------------------------------------------------------------
with rango as (
  select
    date_trunc('month', now() at time zone 'America/Santo_Domingo')                      as ini_actual,
    date_trunc('month', now() at time zone 'America/Santo_Domingo') - interval '1 month' as ini_pasado
),
cobros as (
  select
    c.business_id,
    date_trunc('month', coalesce(c.completed_at, c.attempted_at) at time zone 'America/Santo_Domingo') as mes,
    (c.amount_cents + c.itbis_cents) / 100.0 as total_rd
  from public.azul_charges c, rango r
  where c.status = 'approved'
    and coalesce(c.completed_at, c.attempted_at) at time zone 'America/Santo_Domingo' >= r.ini_pasado
    and coalesce(c.completed_at, c.attempted_at) at time zone 'America/Santo_Domingo' <  r.ini_actual + interval '1 month'
)
select
  b.business_name,
  b.environment,
  count(*)          filter (where k.mes = r.ini_actual)              as cobros_mes_actual,
  coalesce(sum(k.total_rd) filter (where k.mes = r.ini_actual), 0)   as rd_mes_actual,
  count(*)          filter (where k.mes = r.ini_pasado)              as cobros_mes_pasado,
  coalesce(sum(k.total_rd) filter (where k.mes = r.ini_pasado), 0)   as rd_mes_pasado
from cobros k
join public.businesses b on b.id = k.business_id
cross join rango r
group by b.business_name, b.environment
order by rd_mes_actual desc, b.business_name;


-- ---------------------------------------------------------------------------
-- 2) DETALLE — cada cobro aprobado, con la tarjeta usada
-- ---------------------------------------------------------------------------
with rango as (
  select
    date_trunc('month', now() at time zone 'America/Santo_Domingo')                      as ini_actual,
    date_trunc('month', now() at time zone 'America/Santo_Domingo') - interval '1 month' as ini_pasado
)
select
  to_char(date_trunc('month', coalesce(c.completed_at, c.attempted_at) at time zone 'America/Santo_Domingo'), 'YYYY-MM') as mes,
  b.business_name,
  b.environment,
  (coalesce(c.completed_at, c.attempted_at) at time zone 'America/Santo_Domingo')::date as fecha,
  c.order_number,
  c.billing_period_start,
  c.billing_period_end,
  c.attempt_number,
  (c.amount_cents + c.itbis_cents) / 100.0 as total_rd,
  c.currency_code,
  pm.data_vault_brand as marca,
  pm.card_number_masked as tarjeta,
  c.authorization_code,
  c.response_message
from public.azul_charges c
join public.businesses b            on b.id  = c.business_id
join public.azul_payment_methods pm on pm.id = c.payment_method_id
cross join rango r
where c.status = 'approved'
  and coalesce(c.completed_at, c.attempted_at) at time zone 'America/Santo_Domingo' >= r.ini_pasado
  and coalesce(c.completed_at, c.attempted_at) at time zone 'America/Santo_Domingo' <  r.ini_actual + interval '1 month'
order by mes desc, fecha desc, b.business_name;


-- ---------------------------------------------------------------------------
-- 3) Facturas de membresía marcadas pagadas A MANO con método tipo tarjeta
--    (por si algún cobro no pasó por Azul y lo registró un operador)
-- ---------------------------------------------------------------------------
with rango as (
  select
    date_trunc('month', now() at time zone 'America/Santo_Domingo')                      as ini_actual,
    date_trunc('month', now() at time zone 'America/Santo_Domingo') - interval '1 month' as ini_pasado
)
select
  to_char(date_trunc('month', i.paid_at at time zone 'America/Santo_Domingo'), 'YYYY-MM') as mes,
  b.business_name,
  b.environment,
  i.invoice_number,
  (i.paid_at at time zone 'America/Santo_Domingo')::date as fecha_pago,
  i.plan_type,
  i.total,
  i.payment_method,
  i.payment_reference
from public.membership_invoices i
join public.businesses b on b.id = i.business_id
cross join rango r
where i.status = 'paid'
  and i.paid_at is not null
  and i.payment_method ~* '(card|tarjeta|visa|master|amex|azul)'
  and i.paid_at at time zone 'America/Santo_Domingo' >= r.ini_pasado
  and i.paid_at at time zone 'America/Santo_Domingo' <  r.ini_actual + interval '1 month'
order by mes desc, fecha_pago desc, b.business_name;


-- ---------------------------------------------------------------------------
-- 4) COMBINADO — lista única de negocios que pagaron con tarjeta, por mes,
--    juntando cobro automático (Azul) y registro manual
-- ---------------------------------------------------------------------------
with rango as (
  select
    date_trunc('month', now() at time zone 'America/Santo_Domingo')                      as ini_actual,
    date_trunc('month', now() at time zone 'America/Santo_Domingo') - interval '1 month' as ini_pasado
),
todo as (
  select c.business_id,
         date_trunc('month', coalesce(c.completed_at, c.attempted_at) at time zone 'America/Santo_Domingo') as mes,
         'azul'::text as origen,
         (c.amount_cents + c.itbis_cents) / 100.0 as total_rd
  from public.azul_charges c, rango r
  where c.status = 'approved'
    and coalesce(c.completed_at, c.attempted_at) at time zone 'America/Santo_Domingo' >= r.ini_pasado
    and coalesce(c.completed_at, c.attempted_at) at time zone 'America/Santo_Domingo' <  r.ini_actual + interval '1 month'

  union all

  select i.business_id,
         date_trunc('month', i.paid_at at time zone 'America/Santo_Domingo') as mes,
         'manual'::text as origen,
         i.total
  from public.membership_invoices i, rango r
  where i.status = 'paid'
    and i.paid_at is not null
    and i.payment_method ~* '(card|tarjeta|visa|master|amex|azul)'
    and i.paid_at at time zone 'America/Santo_Domingo' >= r.ini_pasado
    and i.paid_at at time zone 'America/Santo_Domingo' <  r.ini_actual + interval '1 month'
)
select
  to_char(t.mes, 'YYYY-MM') as mes,
  case when t.mes = r.ini_actual then 'mes actual' else 'mes pasado' end as etiqueta,
  b.business_name,
  b.environment,
  string_agg(distinct t.origen, ' + ') as origen,
  count(*)      as pagos,
  sum(t.total_rd) as total_rd
from todo t
join public.businesses b on b.id = t.business_id
cross join rango r
group by t.mes, r.ini_actual, b.business_name, b.environment
order by mes desc, total_rd desc, b.business_name;

-- ============================================================================
-- ¿Estos negocios tienen impuestos configurados?
--   af2ec2e7-2cdd-4583-bf5a-7e7476173b72
--   f054fbc2-3fb7-4e34-a020-11341ff11d84
-- Correr en Supabase Studio (SQL Editor) o psql contra producción.
-- ============================================================================

-- ─── Detalle: cada impuesto definido por negocio ───────────────────────────
select
  b.id                              as business_id,
  b.business_name                   as negocio,
  t.name                            as impuesto,
  t.rate,
  t.is_active,
  t.is_service_fee
from public.businesses b
left join public.taxes t on t.business_id = b.id
where b.id in (
  'af2ec2e7-2cdd-4583-bf5a-7e7476173b72',
  'f054fbc2-3fb7-4e34-a020-11341ff11d84'
)
order by b.business_name, t.is_service_fee nulls first, t.rate desc;

-- ─── Veredicto por negocio ─────────────────────────────────────────────────
select
  b.id            as business_id,
  b.business_name as negocio,
  count(t.id) filter (
    where coalesce(t.is_active, true)
  )                                                         as impuestos_activos,
  count(t.id) filter (
    where coalesce(t.is_active, true)
      and coalesce(t.is_service_fee, false) = false
      and t.rate > 0
  )                                                         as itbis_activos,
  coalesce(bool_or(
    coalesce(t.is_active, true)
      and coalesce(t.is_service_fee, false) = false
      and t.rate > 0
  ), false)                                                 as tiene_itbis_configurado
from public.businesses b
left join public.taxes t on t.business_id = b.id
where b.id in (
  'af2ec2e7-2cdd-4583-bf5a-7e7476173b72',
  'f054fbc2-3fb7-4e34-a020-11341ff11d84'
)
group by b.id, b.business_name
order by b.business_name;

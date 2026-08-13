-- ============================================================================
-- ¿Por qué el archivo de la plaza llega solo hasta cierta hora?
-- Negocio 6e18428f-fdd6-4c58-af0e-dae2403fbf1d (LA COCINA MEXICANA AUTENTICA)
--
-- SOLO LECTURA. El envío se dispara al CERRAR CAJA y sube todos los pagos del
-- día hasta ese instante. Estas consultas contrastan: hora de los cierres vs.
-- hora de la última venta vs. último envío registrado.
-- Todo en hora local (America/Santo_Domingo).
-- ============================================================================

-- ─── 1) Cierres de caja de los últimos 4 días ───────────────────────────────
--   `closed_at` es la hora en que se disparó el envío. Si hay un cierre
--   POSTERIOR al último envío, ese cierre no subió el archivo.
select
  s.id                                                           as session_id,
  r.name                                                         as caja,
  s.status,
  (s.opened_at at time zone 'America/Santo_Domingo')             as abierta,
  (s.closed_at at time zone 'America/Santo_Domingo')             as cerrada,
  s.end_amount,
  s.difference
from public.cash_register_sessions s
join public.cash_registers r on r.id = s.cash_register_id
where r.business_id = '6e18428f-fdd6-4c58-af0e-dae2403fbf1d'::uuid
  and s.opened_at >= (current_date - 4)
order by s.opened_at desc;


-- ─── 2) Primera y última venta por día vs. hora de corte ────────────────────
--   Si `ultima_venta` es más tarde que el cierre, esas ventas NO llegaron a
--   la plaza (el archivo se generó antes de que existieran).
select
  (p.created_at at time zone 'America/Santo_Domingo')::date       as dia,
  count(*)                                                        as pagos,
  min(p.created_at at time zone 'America/Santo_Domingo')::time     as primera_venta,
  max(p.created_at at time zone 'America/Santo_Domingo')::time     as ultima_venta,
  max(extract(hour from p.created_at at time zone 'America/Santo_Domingo'))::int
                                                                  as ultima_hora
from public.payments p
where p.business_id = '6e18428f-fdd6-4c58-af0e-dae2403fbf1d'::uuid
  and (p.status = 'completed' or p.status is null)
  and p.created_at >= (current_date - 4)
group by 1
order by 1 desc;


-- ─── 3) Ventas por hora de HOY según la RPC (lo que subiría ahora mismo) ────
--   Compara estas horas con las que trae el .txt del servidor.
select *
from public.fn_mall_sales_by_hour(
  '6e18428f-fdd6-4c58-af0e-dae2403fbf1d'::uuid,
  current_date
)
order by sale_hour;


-- ─── 4) Estado del último envío ─────────────────────────────────────────────
select
  c.enabled,
  c.send_on_cash_close,
  (c.last_sent_at at time zone 'America/Santo_Domingo')          as ultimo_envio,
  c.last_error
from public.business_sales_export_config c
where c.business_id = '6e18428f-fdd6-4c58-af0e-dae2403fbf1d'::uuid;

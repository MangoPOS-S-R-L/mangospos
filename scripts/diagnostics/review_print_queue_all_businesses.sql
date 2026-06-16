-- =============================================================================
-- Revisión de la cola de impresión (print_jobs) — TODOS los negocios
--
-- Objetivo: ver el estado de la cola antes de limpiarla. Importante AHORA
-- porque el nuevo CloudPrintQueueWorker (drenador en la app) reclama e imprime
-- TODO lo que esté en status 'pending'/'retry'. Si hay comandas viejas
-- atascadas (de cuando nadie drenaba la cola en setups solo-tablets), al
-- desplegar saldrían todas de golpe. Esto mide esa "lluvia" antes de actuar.
--
-- Cómo correrlo: SQL editor de Supabase. Es SOLO LECTURA — no modifica nada.
-- Comparte el output de las 5 queries y con eso armamos el DELETE/UPDATE preciso.
--
-- Nota: el SQL editor no soporta meta-comandos de psql (\set); todo va inline.
-- =============================================================================

-- ── Q1. Conteo global por status (todos los negocios) ───────────────────────
-- Vista rápida de cómo está repartida la cola entera.
select
  status,
  count(*)                                         as jobs,
  min(created_at)                                  as mas_viejo,
  max(created_at)                                  as mas_nuevo
from public.print_jobs
group by status
order by jobs desc;


-- ── Q2. "Lluvia" potencial: jobs que el drenador IMPRIMIRÍA (pending/retry) ──
-- Repartido por antigüedad. Lo que esté aquí es lo que saldría al desplegar.
select
  count(*)                                                                   as total_imprimibles,
  count(*) filter (where created_at >= now() - interval '1 hour')           as ultima_hora,
  count(*) filter (where created_at <  now() - interval '1 hour'
                     and created_at >= now() - interval '1 day')            as entre_1h_y_1d,
  count(*) filter (where created_at <  now() - interval '1 day'
                     and created_at >= now() - interval '7 days')           as entre_1d_y_7d,
  count(*) filter (where created_at <  now() - interval '7 days'
                     and created_at >= now() - interval '30 days')          as entre_7d_y_30d,
  count(*) filter (where created_at <  now() - interval '30 days')          as mas_de_30d
from public.print_jobs
where status in ('pending', 'retry');


-- ── Q3. Por negocio: cuántos imprimibles y qué tan viejos ───────────────────
-- Para ver si la lluvia está concentrada en pocos negocios.
select
  business_id,
  count(*)                                                          as imprimibles,
  count(*) filter (where created_at < now() - interval '1 day')    as viejos_mas_1d,
  min(created_at)                                                  as mas_viejo,
  max(created_at)                                                  as mas_nuevo
from public.print_jobs
where status in ('pending', 'retry')
group by business_id
order by imprimibles desc
limit 50;


-- ── Q4. Muestra de los 30 jobs imprimibles más VIEJOS ───────────────────────
-- Sanity check: ver qué son realmente (kind/area) y confirmar que son basura
-- antigua y no algo legítimo reciente.
select
  id,
  business_id,
  status,
  kind,
  area_code,
  printer_id,
  ip,
  retry_count,
  created_at
from public.print_jobs
where status in ('pending', 'retry')
order by created_at asc
limit 30;


-- ── Q5. Jobs "colgados" en proceso (claimed pero nunca terminaron) ──────────
-- 'printing'/'in_progress' viejos = un device los reclamó y murió a media
-- impresión. No los re-imprime el drenador (solo toma pending/retry), pero son
-- ruido y conviene contarlos para la limpieza.
select
  status,
  count(*)                                                       as jobs,
  count(*) filter (where created_at < now() - interval '1 day') as viejos_mas_1d,
  min(created_at)                                               as mas_viejo
from public.print_jobs
where status in ('printing', 'in_progress')
group by status
order by jobs desc;

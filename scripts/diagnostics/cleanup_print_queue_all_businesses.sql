-- =============================================================================
-- Limpieza de la cola de impresión (print_jobs) — TODOS los negocios
--
-- Contexto: el nuevo CloudPrintQueueWorker reclama e imprime TODO lo que esté
-- en 'pending'/'retry'. Hay ~618 jobs viejos atascados (nadie los drenaba en
-- setups solo-tablets) que saldrían de golpe al desplegar. Esto los neutraliza.
--
-- Cómo correrlo: SQL editor de Supabase. CORRE EL PASO 0 PRIMERO (preview).
-- Para previsualizar el efecto de un PASO sin aplicarlo, cambia `commit;` por
-- `rollback;` en ese bloque.
--
-- ⚠️ Modifica producción de TODOS los negocios. No borra en el PASO 1 (marca
-- 'cancelled' = reversible/auditable). El PASO 2 (DELETE) es opcional.
-- =============================================================================

-- ── PASO 0 — PREVIEW (no modifica nada) ─────────────────────────────────────
-- Cuántos se neutralizarían con el umbral de 2 horas del PASO 1.
select
  count(*)                                                          as total_imprimibles,
  count(*) filter (where created_at <  now() - interval '2 hours') as se_cancelan,
  count(*) filter (where created_at >= now() - interval '2 hours') as se_conservan_recientes
from public.print_jobs
where status in ('pending', 'retry', 'in_progress');


-- ── PASO 1 — NEUTRALIZAR LA LLUVIA (antes de desplegar el drenador) ──────────
-- Marca como 'cancelled' el backlog de pending/retry/in_progress más viejo que
-- el umbral. El drenador ignora 'cancelled', así que NO se imprimen.
--
-- Umbral: conserva los últimos 2h por si algún negocio SÍ tiene un agente Node
-- drenando jobs recientes en vivo. Ajústalo:
--   - limpiar TODO el backlog: usa  interval '0 hours'  (o borra la línea created_at)
--   - más conservador:          usa  interval '1 day'
begin;
update public.print_jobs
set status = 'cancelled'
where status in ('pending', 'retry', 'in_progress')
  and created_at < now() - interval '2 hours';
commit;


-- ── PASO 2 (OPCIONAL) — HOUSEKEEPING: purgar rows terminales viejas ──────────
-- Libera espacio borrando jobs ya terminados (printed/dead/cancelled) viejos.
-- Incluye lo que el PASO 1 acaba de cancelar si tiene >7 días.
--
-- Preview:
select status, count(*) as jobs
from public.print_jobs
where status in ('printed', 'dead', 'cancelled')
  and created_at < now() - interval '7 days'
group by status
order by jobs desc;

-- Borrar (descomenta el bloque para ejecutar):
-- begin;
-- delete from public.print_jobs
-- where status in ('printed', 'dead', 'cancelled')
--   and created_at < now() - interval '7 days';
-- commit;

-- =============================================================================
-- PASO 1b · ¿El backfill dispararía emisiones e-CF?
--
-- El trigger tg_alanube_enqueue_emission está HABILITADO sobre fiscal_documents.
-- Antes de cualquier UPDATE masivo hay que saber en qué eventos dispara.
--
-- SOLO LECTURA.
-- =============================================================================

-- E ─── En qué eventos dispara ────────────────────────────────────────────────
--     LO QUE QUEREMOS VER: "AFTER INSERT" y NADA de UPDATE.
--     Si dice UPDATE -> el backfill NO se corre tal cual.
select pg_get_triggerdef(t.oid) as definicion
from pg_trigger t
join pg_class c on c.oid = t.tgrelid
where c.relname = 'fiscal_documents'
  and t.tgname = 'tg_alanube_enqueue_emission';


-- F ─── Qué hace por dentro ───────────────────────────────────────────────────
--     Aunque dispare en UPDATE, puede tener un guard (is_electronic, ecf_status,
--     o comparar OLD/NEW). Hay que leerlo.
select pg_get_functiondef('public.fn_alanube_enqueue_emission'::regproc) as cuerpo;


-- G ─── ¿La Penda emite e-CF, o NCF tradicional? ──────────────────────────────
--     Si is_electronic = false en todo agosto, el riesgo es teórico.
select
  is_electronic,
  coalesce(ecf_status, '(sin estado)') as ecf_status,
  count(*)                             as comprobantes,
  min(issued_at)::date                 as desde,
  max(issued_at)::date                 as hasta
from public.fiscal_documents
where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and (issued_at at time zone 'America/Santo_Domingo')::date
      between date '2026-08-01' and date '2026-08-31'
group by is_electronic, ecf_status
order by comprobantes desc;


-- H ─── ¿Hay configuración de Alanube para este negocio? ──────────────────────
--     Sin fila aquí, el e-CF ni siquiera está activado.
select count(*) as tiene_config_alanube
from public.business_alanube_settings
where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';

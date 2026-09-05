-- ============================================================================
-- Anulacion con NOTA DE CREDITO — puesta en marcha
-- ============================================================================
-- Requiere la migracion 20260903_0001_credit_note_annulment.sql APLICADA.
--
-- Sin secuencia de notas cargada el POS anula igual, pero la nota queda
-- PENDIENTE: el negocio declara ITBIS de una venta que devolvio. Estos pasos
-- cierran ese hueco.
-- ============================================================================


-- PASO 1 ─ Quien puede anular ante la DGII y quien no ────────────────────────
-- E34 = nota de credito electronica (para negocios en e-CF).
-- B04 = nota de credito de papel (para negocios en NCF tradicional).
select b.id as business_id,
       b.business_name,
       fs.ecf_enabled,
       max(case when ns.ncf_type = 'E34' then 1 else 0 end) = 1 as tiene_e34,
       max(case when ns.ncf_type = 'B04' then 1 else 0 end) = 1 as tiene_b04,
       string_agg(distinct ns.ncf_type::text, ', ' order by ns.ncf_type::text)
         filter (where ns.is_active) as secuencias_activas
from public.businesses b
left join public.fiscal_settings fs on fs.business_id = b.id
left join public.ncf_sequences ns on ns.business_id = b.id
group by b.id, b.business_name, fs.ecf_enabled
order by fs.ecf_enabled desc nulls last, b.business_name;


-- PASO 2 ─ Cargar la secuencia de notas de credito ───────────────────────────
-- El rango sale de la AUTORIZACION de la DGII para ese tipo. No lo inventes:
-- generate_ncf reparte numeros dentro de ese rango y la DGII los valida.
--
-- Electronica (e-CF 34). Tambien se puede cargar desde la POS en
-- Ajustes > Comprobantes fiscales > Agregar Secuencia (serie E, tipo 34).
--
-- insert into public.ncf_sequences
--   (business_id, ncf_type, serie, prefix, range_start, range_end,
--    current_number, expiration_date, is_active)
-- values
--   ('PON_AQUI_EL_BUSINESS_ID'::uuid, 'E34', 'E', 'E34', 1, 1000, 0, null, true)
-- on conflict (business_id, ncf_type, serie) do nothing;
--
-- Papel (NCF B04), para los negocios que todavia no estan en e-CF. Aqui la
-- fecha de vencimiento SI viene en la autorizacion de la DGII.
--
-- insert into public.ncf_sequences
--   (business_id, ncf_type, serie, prefix, range_start, range_end,
--    current_number, expiration_date, is_active)
-- values
--   ('PON_AQUI_EL_BUSINESS_ID'::uuid, 'B04', 'B', 'B04', 1, 500, 0,
--    'AAAA-MM-DD'::date, true)
-- on conflict (business_id, ncf_type, serie) do nothing;


-- PASO 3 ─ Anuladas que se quedaron SIN nota de credito ──────────────────────
-- Es la lista a perseguir. Cada fila es una venta anulada cuyo NCF sigue
-- declarado ante la DGII.
select v.*, b.business_name
from public.v_fiscal_docs_pending_credit_note v
join public.businesses b on b.id = v.business_id
order by v.cancelled_at desc nulls last
limit 200;


-- PASO 4 ─ Emitir las notas atrasadas ────────────────────────────────────────
-- OJO: esto CONSUME e-NCF reales y manda documentos a la DGII. Corre primero
-- el PASO 3, revisa la lista, y limita por negocio.
--
-- select v.ncf_number as anulado,
--        public.fn_issue_credit_note(v.id, coalesce(v.cancellation_reason,
--                                    'Anulacion registrada en el POS'), 1) as resultado
-- from public.v_fiscal_docs_pending_credit_note v
-- where v.business_id = 'PON_AQUI_EL_BUSINESS_ID'::uuid
-- order by v.cancelled_at;
--
-- Las electronicas quedan encoladas en alanube_emit_outbox y el cron de
-- emit-document (cada 60s) las manda solas.


-- PASO 5 ─ Seguimiento: notas emitidas y su estado en la DGII ────────────────
select n.ncf_number      as nota,
       n.ecf_status,
       n.total,
       o.ncf_number      as anula,
       n.modification_code,
       n.modification_reason,
       n.issued_at,
       n.last_error
from public.fiscal_documents n
left join public.fiscal_documents o on o.id = n.related_document_id
where n.ncf_type in ('E34', 'B04')
order by n.issued_at desc
limit 100;

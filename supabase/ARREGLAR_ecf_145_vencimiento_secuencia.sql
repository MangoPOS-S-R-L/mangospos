-- ============================================================================
-- DGII codigo 145 — "Fecha de vencimiento de secuencia invalida"
-- ============================================================================
-- CAUSA: el emisor mandaba `sequenceDueDate` = hoy + 1 anio, una fecha
-- INVENTADA. La DGII la valida contra la autorizacion del rango, asi que
-- rechaza. E32 no falla porque a ese tipo NO se le manda la fecha.
--
-- ARREGLO: la fecha sale de ncf_sequences.expiration_date, que hoy esta en
-- NULL porque la pantalla de secuencias nunca la pedia.
--
-- Corre los pasos EN ORDEN en el SQL Editor de Supabase.
-- ============================================================================


-- PASO 1 ─ El documento rechazado: que tipo es y que dijo la DGII ────────────
select fd.id,
       fd.business_id,
       b.business_name,
       fd.ncf_type,
       fd.ncf_number,
       fd.ecf_status,
       fd.issued_at,
       fd.total,
       fd.alanube_document_id,
       fd.last_error
from public.fiscal_documents fd
join public.businesses b on b.id = fd.business_id
where fd.alanube_document_id = '01M1J2XFV9ZRXXQFCT4AFJ49AJ'
   or fd.ecf_tracking_number = '01M1J2XFV9ZRXXQFCT4AFJ49AJ';


-- PASO 1B ─ Las secuencias DEL NEGOCIO de ese documento ──────────────────────
-- Se resuelve solo desde el documento: no hace falta saber el business_id.
-- Lo que importa es la fila del MISMO ncf_type del documento y su
-- expiration_date, que es la que ahora viaja en el comprobante.
select b.business_name,
       ns.ncf_type,
       ns.prefix,
       ns.range_start,
       ns.current_number,
       ns.range_end,
       ns.expiration_date,
       ns.is_active,
       case
         when ns.expiration_date is null then 'SIN FECHA — el emisor se planta'
         when ns.expiration_date <= current_date then 'VENCIDA — generate_ncf la ignora'
         else 'ok'
       end as diagnostico
from public.ncf_sequences ns
join public.businesses b on b.id = ns.business_id
where ns.business_id = (
  select fd.business_id
  from public.fiscal_documents fd
  where fd.alanube_document_id = '01M1J2XFV9ZRXXQFCT4AFJ49AJ'
     or fd.ecf_tracking_number = '01M1J2XFV9ZRXXQFCT4AFJ49AJ'
  limit 1
)
order by ns.ncf_type;


-- PASO 2 ─ Todos los rechazados por el 145 (para saber el alcance) ───────────
select fd.business_id,
       b.business_name,
       fd.ncf_type,
       count(*)              as rechazados,
       min(fd.issued_at)     as desde,
       max(fd.issued_at)     as hasta
from public.fiscal_documents fd
join public.businesses b on b.id = fd.business_id
where fd.ecf_status = 'rejected'
  and (fd.last_error ilike '%145%' or fd.last_error ilike '%vencimiento%')
group by 1, 2, 3
order by rechazados desc;


-- PASO 3 ─ Como estan las secuencias hoy (expiration_date en NULL = el bug) ──
-- Cambia el business_id por el que salio en el PASO 1.
select ns.id,
       ns.ncf_type,
       ns.serie,
       ns.range_start,
       ns.current_number,
       ns.range_end,
       ns.expiration_date,
       ns.is_active,
       case
         when ns.serie = 'E' and ns.ncf_type <> 'E32' and ns.expiration_date is null
           then 'FALTA la fecha de la autorizacion — la DGII rechaza con 145'
         else 'ok'
       end as diagnostico
from public.ncf_sequences ns
where ns.business_id = 'PON_AQUI_EL_BUSINESS_ID'::uuid
order by ns.ncf_type;


-- PASO 3B ─ TODAS las secuencias que quedarian bloqueadas ────────────────────
-- Corre esto apenas despliegues la funcion nueva: desde ese momento un e-CF
-- E31/E44/E45 sin fecha NO se emite (antes salia con fecha inventada y la DGII
-- lo rechazaba con el 145, quemando el e-NCF).
select b.business_name,
       ns.business_id,
       ns.ncf_type,
       ns.current_number,
       ns.range_end,
       ns.range_end - ns.current_number as disponibles,
       ns.expiration_date
from public.ncf_sequences ns
join public.businesses b on b.id = ns.business_id
where ns.is_active
  and ns.ncf_type::text in ('E31', 'E44', 'E45')
  and ns.expiration_date is null
  and ns.current_number < ns.range_end
order by b.business_name;


-- PASO 4 ─ Cargar la fecha DE LA AUTORIZACION DE LA DGII ─────────────────────
-- OJO: NO la inventes. Es la "Fecha de vencimiento" que aparece en la
-- autorizacion de secuencias de la Oficina Virtual para ESE rango de e-NCF.
-- Si la pones distinta, la DGII sigue devolviendo el 145.
--
-- update public.ncf_sequences
--    set expiration_date = 'AAAA-MM-DD'::date
--  where business_id = 'PON_AQUI_EL_BUSINESS_ID'::uuid
--    and ncf_type = 'E31';


-- PASO 4B ─ Cuanto arrastra el 145 en ese negocio ────────────────────────────
-- Restaurante Vistamar (59301a9b-4959-4d6f-bbfb-78e98e221aec) fue el unico con
-- E31 sin fecha al 2026-09-03. Todo E31 que haya emitido salio con la fecha
-- inventada, asi que la DGII lo rechazo.
select fd.ecf_status,
       count(*)          as documentos,
       min(fd.issued_at) as desde,
       max(fd.issued_at) as hasta,
       sum(fd.total)     as monto
from public.fiscal_documents fd
where fd.business_id = '59301a9b-4959-4d6f-bbfb-78e98e221aec'::uuid
  and fd.ncf_type::text = 'E31'
group by fd.ecf_status
order by documentos desc;


-- PASO 5 ─ Reintentar el documento rechazado con el mismo e-NCF ──────────────
-- Solo despues del PASO 4 y de desplegar la Edge Function corregida.
-- Se limpia alanube_document_id porque emit-document salta cualquier doc que
-- ya lo tenga ("already submitted") y nunca lo volveria a mandar.
--
-- with doc as (
--   select id from public.fiscal_documents
--    where alanube_document_id = '01M1J2XFV9ZRXXQFCT4AFJ49AJ'
-- ), reset_doc as (
--   update public.fiscal_documents fd
--      set alanube_document_id = null,
--          ecf_status          = 'pending',
--          last_error          = null
--     from doc
--    where fd.id = doc.id
--   returning fd.id
-- )
-- update public.alanube_emit_outbox o
--    set status          = 'pending',
--        attempts        = 0,
--        error           = null,
--        next_attempt_at = now()
--   from reset_doc
--  where o.fiscal_document_id = reset_doc.id;
--
-- El cron de emit-document (cada 60s) lo recoge solo.
-- NOTA: Alanube manda el Idempotency-Key del documento. Si te devuelve el
-- mismo rechazo sin re-procesar, hay que pedirles a ellos que liberen el
-- documento o emitir con un e-NCF nuevo.


-- PASO 6 ─ Reenviar EN LOTE los E31 rechazados de un negocio ─────────────────
-- Solo despues de cargar la fecha (PASO 4) y de ver el conteo (PASO 4B).
-- Empieza por UNO: corre el PASO 5 con un solo documento, comprueba que la
-- DGII lo acepta, y recien ahi suelta el lote.
--
-- with docs as (
--   select fd.id
--   from public.fiscal_documents fd
--   where fd.business_id = '59301a9b-4959-4d6f-bbfb-78e98e221aec'::uuid
--     and fd.ncf_type::text = 'E31'
--     and fd.ecf_status = 'rejected'
--     and fd.status = 'active'          -- las anuladas no se reenvian
--   order by fd.issued_at
--   limit 25                            -- de a poco: cada una es un POST a la DGII
-- ), reset_docs as (
--   update public.fiscal_documents fd
--      set alanube_document_id = null,
--          ecf_status          = 'pending',
--          last_error          = null
--     from docs
--    where fd.id = docs.id
--   returning fd.id
-- )
-- update public.alanube_emit_outbox o
--    set status = 'pending', attempts = 0, error = null, next_attempt_at = now()
--   from reset_docs
--  where o.fiscal_document_id = reset_docs.id;

-- =============================================================================
-- PASO 2 · Aplicar la v6 y probarla contra datos reales SIN escribir nada
-- La Penda Express · business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- Preflight OK:
--   * reparto 18/10 por respaldo de nombre, sin tocar configuracion
--   * funcion viva = v5
--   * trg_recompute_fd_on_payment_change EXISTE y esta habilitado
--   * Alanube: AFTER INSERT + is_electronic=false + sin settings -> sin riesgo
--
-- CORRER 2.1 Y LUEGO 2.2. Ninguno modifica comprobantes.
-- =============================================================================


-- ─── 2.1 · Aplicar la migracion ──────────────────────────────────────────────
--
--   Pegar y ejecutar el contenido COMPLETO de:
--       supabase/migrations/20260902_0007_fd_split_by_tax_name.sql
--
--   Solo redefine una funcion. NO toca ningun comprobante, ninguna orden,
--   ningun pago. Los 6,007 de agosto quedan exactamente como estan.
--
--   Verificar que quedo aplicada: tiene que decir v6.
select obj_description(
  'public.fn_recompute_fd_for_scope(uuid,uuid,uuid)'::regprocedure, 'pg_proc'
) as version_viva;


-- ─── 2.2 · LA PRUEBA DE FUEGO ────────────────────────────────────────────────
--
--   Corre la funcion nueva sobre la factura testigo del auditor, muestra el
--   antes y el despues, y HACE ROLLBACK. Nada queda escrito.
--
--   Es la prueba real: la logica nueva contra datos de produccion, sin riesgo.
--
--   ESPERADO en la fila "DESPUES":
--       itbis_amount  2326.21     (hoy 0.00)
--       service_fee   1292.34     (hoy 0.00)
--       total        16541.95     (igual que antes)
--       descuadre        0.00     (subtotal + itbis + ley - total)
--
--   Correr el bloque completo de una sola vez.

begin;

select 'ANTES' as momento, ncf_number, subtotal, itbis_amount, service_fee, total,
       round(subtotal + itbis_amount + service_fee - total, 2) as descuadre
from public.fiscal_documents
where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and ncf_number = 'B0200154176';

do $$
declare r record;
begin
  select id, order_id, check_id into r
  from public.fiscal_documents
  where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and ncf_number = 'B0200154176';

  perform public.fn_recompute_fd_for_scope(r.id, r.order_id, r.check_id);
end
$$;

select 'DESPUES' as momento, ncf_number, subtotal, itbis_amount, service_fee, total,
       round(subtotal + itbis_amount + service_fee - total, 2) as descuadre
from public.fiscal_documents
where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and ncf_number = 'B0200154176';

rollback;


-- ─── 2.3 · Confirmar que el rollback funciono ────────────────────────────────
--     Tiene que volver a mostrar itbis_amount 0.00. Si muestra 2326.21,
--     el rollback no corrio y hay que avisar.
select ncf_number, itbis_amount, service_fee
from public.fiscal_documents
where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and ncf_number = 'B0200154176';

-- =============================================================================
-- 20260812_0001 — Policy de UPDATE en fiscal_documents (anulación de ventas)
-- =============================================================================
--
-- PROBLEMA (verificado contra prod el 2026-08-12):
--   `fiscal_documents` tiene RLS activo y para `authenticated` solo existen
--   policies de INSERT (fd_insert) y SELECT (fd_select). No hay ninguna de
--   UPDATE. En Postgres eso no da error: la policy filtra la fila, el UPDATE
--   afecta 0 registros y PostgREST responde 200. Falla en silencio.
--
--   Consecuencia: al anular una venta, el pago SÍ pasa a 'cancelled'
--   (payments_update sí existe) pero el NCF se queda 'active'. La venta
--   sigue apareciendo activa en el historial —que deriva el estado de
--   `fd.status`— y el documento fiscal sigue contando como válido para DGII
--   aunque la venta ya no exista.
--
--   Se ve peor con pago mixto: el historial agrupa por documento fiscal, así
--   que la fila nunca cambia de estado y el cajero puede darle a "Anular"
--   indefinidamente.
--
-- SOLUCIÓN:
--   1. Policy de UPDATE con el MISMO alcance que fd_select/fd_insert (acceso
--      al negocio). Es el mismo criterio que ya usa `payments_update` en
--      prod, así que no introduce un modelo nuevo.
--   2. Grant de columnas acotado a las de anulación. Hoy `authenticated`
--      tiene UPDATE sobre las 45 columnas de la tabla, pero sin policy no
--      podía usarlo para nada: acotarlo no le quita capacidad a nadie y
--      evita que desde el cliente se puedan editar NCF, montos o fechas de
--      emisión. Verificado en el código: la anulación es el ÚNICO update que
--      la app hace sobre esta tabla (sales_repository.dart); el resto de
--      accesos son SELECT, y los flujos de e-CF corren con service_role
--      (policy service_role_all).
--
--   Si mañana algún flujo necesita escribir otra columna, fallará con
--   "permission denied for column" — ruidoso, no en silencio.
--
-- SIN IMPACTO en datos existentes: solo cambia permisos.
-- IDEMPOTENTE.
-- =============================================================================

begin;

drop policy if exists fd_update on public.fiscal_documents;

create policy fd_update on public.fiscal_documents
  for update
  to authenticated
  using (public.user_has_business_access(auth.uid(), business_id))
  with check (public.user_has_business_access(auth.uid(), business_id));

comment on policy fd_update on public.fiscal_documents is
  'Permite anular documentos fiscales del propio negocio. El grant de '
  'columnas limita el UPDATE a status/cancelled_at/cancellation_reason/'
  'cancelled_by.';

-- Acotar qué columnas puede tocar el cliente.
revoke update on public.fiscal_documents from authenticated;
grant update (status, cancelled_at, cancellation_reason, cancelled_by)
  on public.fiscal_documents to authenticated;

commit;

-- =============================================================================
-- VERIFICACIÓN (correr después)
-- =============================================================================
-- -- Debe aparecer fd_update con cmd = 'UPDATE'.
-- select policyname, cmd, roles::text
-- from pg_policies
-- where schemaname = 'public' and tablename = 'fiscal_documents'
-- order by cmd;
--
-- -- Deben quedar exactamente 4 columnas actualizables.
-- select column_name
-- from information_schema.column_privileges
-- where table_schema = 'public' and table_name = 'fiscal_documents'
--   and grantee = 'authenticated' and privilege_type = 'UPDATE'
-- order by column_name;
--
-- -- Daño histórico: NCFs vivos de ventas que ya fueron anuladas.
-- select count(*) as ncf_activos_de_ventas_anuladas
-- from public.fiscal_documents fd
-- join public.orders o on o.id = fd.order_id
-- where fd.status = 'active'
--   and o.status = 'void';
-- =============================================================================

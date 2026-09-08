-- =============================================================================
-- F1a fix — El pago de un canal externo necesita una sesion de caja
--
-- Ver docs/PRD_INTEGRACION_PINCER.md §7.3. Depende de 20260907_0006.
--
-- QUE PASO (encontrado probando en produccion, 2026-09-07)
--   El PRD asumia que un pedido prepagado podia registrarse con
--   `p_cashier_session_id => null`, porque el dinero no pasa por el cajon.
--   Falso: `fn_process_payment_v3` corta ANTES de mirar el metodo de pago:
--
--       if p_cashier_session_id is null then
--         raise exception 'CASH_SESSION_REQUIRED';
--       end if;
--
--   Resultado real del pedido de prueba DEL-020: entro con la comanda, pero con
--   payment_state='failed' y payment_error='CASH_SESSION_REQUIRED'.
--
-- QUE HACE ESTA MIGRACION
--   Resuelve la caja ABIERTA del negocio y se la pasa al cobro. Es lo mismo que
--   hace la app (cashier_repository.getActiveSessionForBusiness): join por
--   `cash_registers.business_id`, la mas reciente.
--
--   El pago NO entra al cuadre de efectivo: `fn_process_payment_v3` solo suma al
--   cajon cuando el metodo es 'cash', y este es 'pincer'. Queda como ingreso del
--   turno por su metodo, que es justo lo que pide el PRD.
--
--   Si NO hay caja abierta (pedido de madrugada), ya no se intenta el cobro para
--   no gastar el intento con un error cripto: el pedido entra igual, con
--   payment_state='failed' y un mensaje que dice que hacer.
--
-- LO QUE **NO** HACE, Y HABRIA QUE HACER ALGUN DIA
--   Lo correcto de fondo es que el guard de `fn_process_payment_v3` aplique solo
--   a efectivo, como ya lo hace el modulo de credito (20260714_0002):
--
--       if v_method_code = 'cash' then ... CASH_SESSION_REQUIRED ... end if;
--
--   Eso es CREATE OR REPLACE de una funcion fiscal que vive divergente del repo
--   ([[project_db_diverges_from_repo_migrations]]) y merece su propia migracion,
--   con el cuerpo vivo capturado antes. Mientras tanto, esto cubre el horario en
--   que el restaurante opera, que es cuando entran los pedidos.
-- =============================================================================

begin;

create or replace function public.fn_external_open_cash_session(p_business_id uuid)
returns uuid
language sql
stable
security definer
set search_path to 'public'
as $$
  select cs.id
    from public.cash_register_sessions cs
    join public.cash_registers cr on cr.id = cs.cash_register_id
   where cr.business_id = p_business_id
     and cs.status = 'open'
     and cs.closed_at is null
   order by cs.opened_at desc
   limit 1;
$$;

comment on function public.fn_external_open_cash_session(uuid) is
  'Caja abierta del negocio, sin filtrar por usuario ni equipo. La usa la '
  'ingesta de canales externos para registrar el cobro: el pedido no lo digita '
  'nadie, asi que no hay "usuario de la caja" a quien atribuirlo.';

revoke all on function public.fn_external_open_cash_session(uuid) from public;
grant execute on function public.fn_external_open_cash_session(uuid) to service_role;

commit;

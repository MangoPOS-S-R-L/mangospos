-- =============================================================================
-- 20261010_0007 — T04: cerrar las ediciones directas de cuentas
-- =============================================================================
--
-- PROBLEMA. Con 20261010_0006 la app nueva edita SOLO por fn_apply_order_edit
-- (versión, reintentos, candado del cobro). Pero las funciones de edición de
-- siempre siguen abiertas para `authenticated`: un equipo con la app anterior
-- (o cualquier cliente) puede llamarlas directo y pisar un cambio posterior
-- sin comparar versiones.
--
-- QUÉ HACE. Quita EXECUTE a anon/authenticated (y PUBLIC) de esas funciones.
-- fn_apply_order_edit (SECURITY DEFINER) las sigue llamando como dueño;
-- service_role conserva el acceso. fn_replace_order_item_modifiers queda
-- abierta: la usa el alta de un ítem recién creado.
--
-- ⚠ CUÁNDO APLICAR. Solo cuando TODOS los equipos tengan la app con T04
--   (Windows, Android, web, macOS e iPad/Mac de la App Store — el repo
--   mangospos-apple hereda el cambio con el merge de upstream). Un equipo con
--   la app anterior deja de poder editar cuentas (error de permisos) hasta
--   que se actualice.
--
-- SALVAGUARDA. Si alguna función SECURITY INVOKER de public (incluidos
-- disparadores) llama a una de estas, la migración se detiene: esa función,
-- llamada por la app, dejaría de funcionar. Revisarla antes de seguir.
--
-- PENDIENTE (fuera de esta migración): las políticas RLS todavía permiten
-- UPDATE directo de order_items/orders por PostgREST. La app nueva no lo hace
-- para editar; cerrarlo por columna requiere revisar cocina, alta de ofertas y
-- anulación, que sí escriben directo.
--
-- IDEMPOTENTE. Reversa: 20261010_0007_close_direct_order_edits_ROLLBACK.sql.
-- =============================================================================

begin;

do $$
declare
  v_names text[] := array[
    'fn_update_item_qty', 'fn_update_item_notes', 'fn_update_item_details',
    'fn_update_item_discount', 'fn_update_item_discount_and_notes',
    'fn_delete_item', 'fn_move_item_to_check', 'fn_move_items_to_check_batch',
    'fn_toggle_item_takeout', 'fn_mark_order_takeout', 'fn_set_delivery_fee',
    'fn_set_order_excluded_taxes', 'fn_assign_customer_to_session',
    'fn_consolidate_keeper_atomic'
  ];
  r record;
begin
  -- Salvaguarda: ninguna función que corre con los permisos de quien la llama
  -- puede depender de las que se cierran.
  for r in
    select p.oid::regprocedure::text as fn
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and not p.prosecdef
       and p.proname <> all (v_names)
       and p.prosrc ~ ('\m(' || array_to_string(v_names, '|') || ')\M')
  loop
    raise exception
      'La función % (SECURITY INVOKER) llama una edición directa: al cerrarla dejaría de funcionar. Revisarla antes de aplicar 20261010_0007.',
      r.fn;
  end loop;

  for r in
    select p.oid::regprocedure::text as fn
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = any (v_names)
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', r.fn);
    execute format('grant execute on function %s to service_role', r.fn);
  end loop;
end $$;

commit;

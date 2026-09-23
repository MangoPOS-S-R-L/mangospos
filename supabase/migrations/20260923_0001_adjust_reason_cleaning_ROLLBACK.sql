-- =============================================================================
-- ROLLBACK de 20260923_0001 — quitar «cleaning» del CHECK
--
-- OJO: si ya hay movimientos con `reason_code = 'cleaning'`, el CHECK nuevo no
-- se puede crear y el bloque ABORTA sin dejar la tabla sin restricción. Eso es
-- a propósito: es mejor no poder revertir que quedarse sin validación.
-- Para revertir de verdad habría que reclasificar esas filas primero.
-- =============================================================================
set local lock_timeout = '5s';

do $$
declare v_n int;
begin
  select count(*) into v_n from public.inventory_movements
   where reason_code = 'cleaning';
  if v_n > 0 then
    raise exception 'Hay % movimientos con reason_code = cleaning. Reclasificarlos '
                    'antes de revertir. No se toco nada.', v_n;
  end if;

  alter table public.inventory_movements
    drop constraint if exists inventory_movements_reason_code_check;

  alter table public.inventory_movements
    add constraint inventory_movements_reason_code_check
    check (
      reason_code is null
      or reason_code in ('physical_count','breakage','expiration','theft',
                         'donation','correction','other')
    );
  raise notice 'CHECK devuelto al catalogo de 20260513_0017.';
end
$$;

notify pgrst, 'reload schema';

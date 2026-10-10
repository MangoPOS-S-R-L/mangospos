-- =============================================================================
-- 20261010_0010 — T07: una conciliación de inventario por orden a la vez
-- =============================================================================
--
-- PROBLEMA. consume_inventory_from_order asienta la DIFERENCIA entre lo que la
-- orden debería haber consumido y lo ya asentado. Repetirla en serie no
-- descuenta dos veces (reintentos de impresión, cocina, emisión o cobro están
-- a salvo). Pero no toma candado: dos transacciones que concilian la MISMA
-- orden a la vez (KDS marcando «servido» mientras se cobra o se confirma a
-- cocina) leen lo mismo ya asentado y asientan la misma diferencia dos veces.
-- Si pasa al cobrar, puede no haber otra conciliación que lo corrija.
--
-- QUÉ HACE. Renombra la función VIVA a consume_inventory_from_order_unlocked
-- (su cuerpo no se copia ni se toca) y pone delante un envoltorio con el
-- mismo nombre y firma que toma un candado consultivo por orden. Todos los
-- llamadores (disparadores, RPC) siguen llamando el mismo nombre.
-- Candado consultivo y no la fila de la orden: el disparador de order_items
-- ya tiene la fila del ítem y la confirmación a cocina toma orden → ítems; un
-- candado de fila aquí podría trabarse en cruz.
--
-- Las guardias de migraciones viejas buscan en la función la marca
-- «UNIFICADA 20260915_0002»: el envoltorio la lleva en su comentario, así se
-- comportan igual que hoy.
--
-- IDEMPOTENTE. Si después de esta migración alguien reemplaza
-- consume_inventory_from_order con un cuerpo nuevo, volver a correrla se
-- DETIENE (no lo cambia por la versión vieja). Reversa: ..._ROLLBACK.sql.
-- =============================================================================

begin;

do $$
declare
  v_current text;
begin
  select p.prosrc into v_current
    from pg_proc p
   where p.oid = to_regprocedure('public.consume_inventory_from_order(uuid)');
  if v_current is null then
    raise exception 'No existe consume_inventory_from_order(uuid): no se aplicó nada.';
  end if;
  if to_regprocedure('public.consume_inventory_from_order_unlocked(uuid)') is null then
    alter function public.consume_inventory_from_order(uuid)
      rename to consume_inventory_from_order_unlocked;
  elsif v_current not like '%consume_inventory_from_order_unlocked%' then
    raise exception 'consume_inventory_from_order cambió después de 20261010_0010 y ya existe '
                    'consume_inventory_from_order_unlocked: revisar a mano. No se aplicó nada.';
  end if;
end $$;

create or replace function public.consume_inventory_from_order(_order_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
-- Envoltorio (20261010_0010) de la conciliación UNIFICADA 20260915_0002, que
-- vive en consume_inventory_from_order_unlocked: una conciliación por orden
-- a la vez (dos simultáneas asentaban la misma diferencia dos veces).
begin
  perform pg_advisory_xact_lock(hashtextextended('consume_inv:' || _order_id::text, 0));
  perform public.consume_inventory_from_order_unlocked(_order_id);
end;
$function$;

comment on function public.consume_inventory_from_order(uuid) is
  'UNIFICADA (20260915_0002) con candado por orden (20261010_0010): toma '
  'pg_advisory_xact_lock y llama consume_inventory_from_order_unlocked.';

-- El envoltorio lo llaman disparadores que corren como quien actualiza la
-- línea (p. ej. el KDS): authenticated lo ejecuta, como antes. La función
-- interna solo la llama el envoltorio (como dueño).
revoke all on function public.consume_inventory_from_order(uuid) from public, anon;
grant execute on function public.consume_inventory_from_order(uuid) to authenticated, service_role;
revoke all on function public.consume_inventory_from_order_unlocked(uuid) from public, anon, authenticated;

commit;

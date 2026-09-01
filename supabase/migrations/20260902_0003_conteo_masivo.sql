-- =============================================================================
-- Que un conteo físico de MILES de líneas se pueda cerrar.
--
-- EL PROBLEMA, encontrado auditando antes de un conteo real desde cero:
--   `fn_physical_count_freeze` crea UNA LÍNEA POR CADA INSUMO ACTIVO del
--   negocio. En un catálogo retail son más de mil.
--
--   Al completar, cada línea contada genera un movimiento, y cada insert en
--   `inventory_movements` dispara DOS triggers fila por fila:
--     · `trg_inventory_stock_sync` (barato, un upsert),
--     · `trg_movements_recompute_menu_availability` → auto-86, que recorre
--       los productos del menú que usan ese insumo y, desde
--       `20260901_0006`, además resuelve las bodegas del punto de venta.
--
--   Mil líneas = mil recálculos DENTRO DE UNA SOLA TRANSACCIÓN. Con el
--   `statement_timeout` que Supabase le pone al rol `authenticated` (suele
--   ser 8 segundos), el cierre revienta a mitad y la sesión se queda en
--   `in_progress`. No se pierde nada —la transacción hace rollback— pero el
--   conteo no se puede cerrar NUNCA, que en un día de inventario es igual de
--   malo.
--
-- ENTREGA:
--   1. `fn_pos_stock_warehouses` deja de llamar dos veces a
--      `fn_resolve_area_warehouse` por producto. Era un error mío en la
--      0006: el `case` la evaluaba para preguntar y otra vez para devolver.
--   2. `statement_timeout` propio para congelar y para completar. Es un
--      trabajo por lotes disparado a mano, no una consulta de pantalla: no
--      tiene por qué morir en el límite pensado para el POS.
--
-- POR QUÉ NO SE APAGA EL AUTO-86 DURANTE EL CIERRE:
--   Es tentador —sería mucho más rápido— pero después del conteo el stock
--   cambió en cientos de insumos y el menú tiene que reflejarlo. Apagarlo
--   dejaría productos agotados vendiéndose hasta el próximo movimiento.
--   Se le da tiempo, no se lo saltea.
--
-- REQUIERE: 20260801_0002 y 20260901_0006.
-- IDEMPOTENTE: sí. REVERSIBLE: sí (ver _ROLLBACK).
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Una sola llamada al resolvedor de área
-- ---------------------------------------------------------------------------

create or replace function public.fn_pos_stock_warehouses(
  p_business_id  uuid,
  p_menu_item_id uuid
) returns uuid[]
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(
    -- (1) La bodega del área del producto, si tiene. Se evalúa UNA vez.
    (
      select array[a.wid]
        from (
          select public.fn_resolve_area_warehouse(
                   p_business_id, p_menu_item_id) as wid
        ) a
       where a.wid is not null
    ),
    -- (2) Las marcadas para el punto de venta, en orden de cascada.
    --     `array_agg` sobre cero filas devuelve NULL, así que un negocio sin
    --     ninguna marcada cae solo al caso (3).
    (
      select array_agg(w.id order by w.is_main desc,
                                     w.created_at asc nulls first,
                                     w.id asc)
        from public.warehouses w
       where w.business_id = p_business_id
         and coalesce(w.is_active, true)
         and w.shows_in_pos
    )
    -- (3) NULL = todas las bodegas. El comportamiento de siempre.
  );
$$;

comment on function public.fn_pos_stock_warehouses(uuid, uuid) is
  'Bodegas de las que sale un producto, en orden de cascada. Un elemento si '
  'resuelve por área; las marcadas shows_in_pos si no; NULL = todas. Se '
  'llama una vez por producto en el auto-86, así que evita evaluar el '
  'resolvedor de área dos veces.';

-- ---------------------------------------------------------------------------
-- 2. Tiempo para los trabajos por lotes del conteo
-- ---------------------------------------------------------------------------

alter function public.fn_physical_count_freeze(uuid)
  set statement_timeout = '120s';

alter function public.fn_physical_count_complete(uuid)
  set statement_timeout = '300s';

comment on function public.fn_physical_count_complete(uuid) is
  'Cierra el conteo: deja el stock EXACTAMENTE en lo contado (delta contra '
  'el stock vivo, no contra el snapshot) y sólo toca las líneas con '
  'counted_quantity no nulo. Tiene statement_timeout propio de 300s porque '
  'es un trabajo por lotes: mil líneas contadas son mil movimientos y mil '
  'recálculos de auto-86 en una sola transacción.';

-- ---------------------------------------------------------------------------
-- 3. Poner en cero lo que no se contó
-- ---------------------------------------------------------------------------
--
-- POR QUÉ HACE FALTA:
--   Completar sólo toca las líneas con `counted_quantity` no nulo. Eso es
--   correcto —permite contar por partes sin borrar lo que no se miró— pero
--   choca de frente con el conteo que REEMPLAZA el inventario: si el
--   objetivo es "el sistema queda con lo que hay físicamente y nada más",
--   toda línea en blanco es existencia fantasma que sobrevive al conteo.
--
--   Con mil líneas, dejar algunas en blanco no es una posibilidad: es lo que
--   va a pasar. Hacerlo a mano son mil llamadas desde la app.
--
--   Esto NO se aplica solo al completar, a propósito: es una decisión del
--   negocio (¿conteo total o parcial?) y la toma quien cierra, no la
--   función.

create or replace function public.fn_physical_count_zero_pending(
  p_session_id uuid
) returns integer
language plpgsql
security definer
set search_path to 'public'
set statement_timeout = '120s'
as $function$
declare
  v_session public.physical_count_sessions;
  v_role text;
  v_count int;
begin
  if p_session_id is null then
    raise exception 'SESSION_ID_REQUIRED';
  end if;

  select * into v_session
    from public.physical_count_sessions where id = p_session_id;
  if v_session.id is null then
    raise exception 'SESSION_NOT_FOUND';
  end if;
  if v_session.status <> 'in_progress' then
    raise exception 'INVALID_STATUS_TRANSITION: solo durante el conteo (status=%)',
      v_session.status;
  end if;

  v_role := public.user_business_role(auth.uid(), v_session.business_id);
  if coalesce(v_role, '') not in ('owner', 'admin', 'manager') then
    raise exception 'INSUFFICIENT_ROLE';
  end if;

  update public.physical_count_lines
     set counted_quantity = 0
   where session_id = p_session_id
     and counted_quantity is null;

  get diagnostics v_count = row_count;
  return v_count;
end;
$function$;

comment on function public.fn_physical_count_zero_pending(uuid) is
  'Pone en CERO las líneas que quedaron sin contar, para el conteo que '
  'reemplaza el inventario: lo que nadie encontró físicamente no existe. '
  'No lo hace fn_physical_count_complete a propósito — contar por partes es '
  'un caso legítimo y ahí las líneas en blanco NO se deben tocar.';

grant execute on function public.fn_physical_count_zero_pending(uuid)
  to authenticated;

commit;

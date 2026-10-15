-- =============================================================================
-- LA PENDA EXPRESS · ACTIVAR INVENTARIO — PASO 2: APLICAR el plan
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- ESCRIBE. Aplica EXACTAMENTE lo que el PASO 1 dejó en `_penda_act_plan`, en
-- una sola transacción: o entra todo, o no entra nada.
--
--   1. Respalda renglones, sesiones y almacenes (para el DESHACER).
--   2. Confirma que cada conteo apunte a su almacén y, si dos conteos del
--      mismo almacén contaron el mismo insumo, los SUMA en un renglón.
--   3. Un ajuste por (almacén, insumo): stock = contado + movido desde el
--      1-oct. Se asienta como «Ajuste por conteo físico» de su sesión, igual
--      que si se cerrara desde la app, y cada renglón queda con su ajuste,
--      su costo y su diferencia.
--   4. El cuadre: cada negativo se compensa con lo que el mismo insumo
--      tenga en otro almacén (la tabla `_penda_act_cuadre` del PASO 1).
--   5. Cierra los 4 conteos del 1-oct. Los 5 del 1-sep NO se tocan: el
--      dueño los deja ABIERTOS para un conteo posterior (12-oct).
--      ⚠️ Esos 5 tienen todavía los números de septiembre tecleados. Si
--      alguien cierra uno desde la app sin volver a teclear TODOS sus
--      renglones, el stock de esos insumos vuelve a lo contado en septiembre.
--
--   La configuración de los almacenes (quién vende de dónde) NO se toca aquí:
--   la cambia el PASO 3, después de las transferencias.
--
-- NO SE CORRE DESDE LA APP: `fn_physical_count_complete` y
-- `fn_inventory_record_movement` exigen sesión de usuario (auth.uid()) y el
-- SQL Editor no la tiene. Los movimientos se insertan directo; el disparador
-- `trg_inventory_stock_sync` mueve el stock igual que siempre.
--
-- VENTAS DURANTE LA CORRIDA: se puede correr con la tienda abierta. Cada
-- ajuste es una DIFERENCIA calculada sobre la foto del PASO 1, así que una
-- venta posterior a la foto se conserva.
-- =============================================================================

set statement_timeout = '15min';

do $$
declare
  v_biz      uuid := '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';
  v_creado   timestamptz;
  v_n        int;
  v_mov      uuid;
  v_ajustes  int := 0;
  v_cuadres  int := 0;
  r          record;
begin
  ---------------------------------------------------------------------------
  -- Guardas
  ---------------------------------------------------------------------------
  if to_regclass('public._penda_act_plan') is null then
    raise exception 'No hay plan. Correr PENDA_ACT_1_preparar.sql primero.';
  end if;

  select count(*) into v_n from public._penda_act_plan where aplicado_en is not null;
  if v_n > 0 then
    raise exception 'El plan YA se aplicó (% filas). No se repite nada.', v_n;
  end if;

  select min(creado_en) into v_creado from public._penda_act_plan;
  if v_creado is null then
    raise exception 'El plan está vacío. Revisar el PASO 1.';
  end if;

  select count(*) into v_n
    from public.physical_count_sessions
   where business_id = v_biz and status = 'in_progress'
     and code in ('PC-2026-000008','PC-2026-000009','PC-2026-000011','PC-2026-000012');
  if v_n <> 4 then
    raise exception 'Se esperaban los 4 conteos del 1-oct abiertos y hay %. No se tocó nada.', v_n;
  end if;

  -- Si alguien tecleó un conteo DESPUÉS de armar el plan, el plan está viejo.
  select count(*) into v_n
    from public.physical_count_lines l
    join public.physical_count_sessions s on s.id = l.session_id
   where s.business_id = v_biz and s.status = 'in_progress'
     and s.code in ('PC-2026-000008','PC-2026-000009','PC-2026-000011','PC-2026-000012')
     and l.updated_at > v_creado;
  if v_n > 0 then
    raise exception '% renglones de conteo cambiaron después de armar el plan. '
                    'Volver a correr el PASO 1. No se tocó nada.', v_n;
  end if;

  -- El plan de antes del 12-oct (tarde) sumaba el conteo del bar al FoodShop.
  -- Desde que «bar descuenta de Bar», ese conteo va al almacén Bar.
  if not exists (select 1 from public._penda_act_plan
                  where almacen = 'Bar' and contado is not null) then
    raise exception 'El plan es de la versión vieja (el conteo del bar no está en el '
                    'almacén Bar). Volver a correr el PASO 1. No se tocó nada.';
  end if;

  if to_regclass('public._penda_act_cuadre') is null then
    raise exception 'Falta _penda_act_cuadre: correr de nuevo el PASO 1. No se tocó nada.';
  end if;

  if to_regclass('public._penda_act_movs') is not null then
    raise exception 'Ya existe _penda_act_movs: hay una corrida anterior sin deshacer. '
                    'No se tocó nada.';
  end if;

  ---------------------------------------------------------------------------
  -- 1. Respaldo
  ---------------------------------------------------------------------------
  create table public._penda_act_movs (
    movement_id uuid primary key,
    tipo        text not null,
    hecho_en    timestamptz not null default now()
  );

  create table public._penda_act_bk_lineas as
  select l.id, l.session_id, l.counted_quantity, l.counter_notes,
         l.stock_at_complete, l.applied_variance, l.unit_cost,
         l.variance_value, l.applied_adjustment_id
    from public.physical_count_lines l
    join public.physical_count_sessions s on s.id = l.session_id
   where s.business_id = v_biz and s.status = 'in_progress'
     and s.code in ('PC-2026-000008','PC-2026-000009','PC-2026-000011','PC-2026-000012');

  create table public._penda_act_bk_sesiones as
  select s.id, s.code, s.warehouse_id, s.status, s.completed_at,
         s.cancelled_at, s.cancellation_reason
    from public.physical_count_sessions s
   where s.business_id = v_biz and s.status = 'in_progress'
     and s.code in ('PC-2026-000008','PC-2026-000009','PC-2026-000011','PC-2026-000012');

  create table public._penda_act_bk_almacenes as
  select w.id, w.name, w.shows_in_pos
    from public.warehouses w
   where w.business_id = v_biz;

  ---------------------------------------------------------------------------
  -- 2a. Reapuntar cada sesión a su almacén
  ---------------------------------------------------------------------------
  update public.physical_count_sessions s
     set warehouse_id = w.id
    from (values
            ('PC-2026-000008','Almacen Principal'),
            ('PC-2026-000009','FoodShop'),
            ('PC-2026-000011','Cocina'),
            ('PC-2026-000012','Bar')) as m(code, almacen),
         public.warehouses w
   where s.business_id = v_biz and s.status = 'in_progress'
     and s.code = m.code
     and w.business_id = v_biz and w.name = m.almacen and coalesce(w.is_active, true)
     and s.warehouse_id is distinct from w.id;

  ---------------------------------------------------------------------------
  -- 2b. Sumar en UN renglón lo contado en varias sesiones del mismo almacén.
  --     El renglón que se queda es el que eligió el PASO 1 (line_id); los
  --     otros quedan en blanco con una nota de a dónde se sumaron.
  ---------------------------------------------------------------------------
  update public.physical_count_lines l
     set counter_notes = concat_ws(' · ', nullif(l.counter_notes, ''),
                           'Sumado al conteo de ' || sk.code || ': '
                           || regexp_replace(round(l.counted_quantity, 4)::text, '\.?0+$', '')),
         counted_quantity = null
    from public._penda_act_plan p
    join public.physical_count_lines k  on k.id = p.line_id
    join public.physical_count_sessions sk on sk.id = k.session_id,
         public.physical_count_sessions s
   where p.lineas_contadas > 1
     and s.id = l.session_id
     and s.business_id = v_biz and s.status = 'in_progress'
     and s.code in ('PC-2026-000008','PC-2026-000009','PC-2026-000011','PC-2026-000012')
     and s.warehouse_id = p.warehouse_id
     and l.item_id = p.item_id
     and l.id <> p.line_id
     and l.counted_quantity is not null;

  update public.physical_count_lines l
     set counted_quantity = p.contado
    from public._penda_act_plan p
   where p.lineas_contadas > 1 and l.id = p.line_id;

  ---------------------------------------------------------------------------
  -- 3. Los ajustes
  ---------------------------------------------------------------------------
  for r in
    select p.*, s.code
      from public._penda_act_plan p
      left join public.physical_count_sessions s on s.id = p.session_id
     order by p.almacen, p.insumo
  loop
    v_mov := null;

    if abs(r.delta) >= 0.0001 then
      insert into public.inventory_movements (
        business_id, warehouse_id, item_id, movement_type, quantity,
        cost_per_unit, reference_id, reference_type, notes
      ) values (
        v_biz, r.warehouse_id, r.item_id, 'adjustment', r.delta,
        nullif(r.costo, 0), r.session_id, 'physical_count',
        case
          when r.contado is not null then
            'Ajuste por conteo físico ' || coalesce(r.code, '') || ' (arranque): contado '
            || regexp_replace(round(r.contado, 4)::text, '\.?0+$', '') || ' el '
            || to_char(r.desde, 'DD-Mon') || ' + movido desde entonces '
            || regexp_replace(round(r.neto, 4)::text, '\.?0+$', '')
          else
            'Ajuste por conteo físico ' || coalesce(r.code, '') || ' (arranque): nadie lo contó el '
            || to_char(r.desde, 'DD-Mon') || '; queda lo movido desde entonces ('
            || regexp_replace(round(r.neto, 4)::text, '\.?0+$', '') || ')'
        end
      )
      returning id into v_mov;

      insert into public._penda_act_movs (movement_id, tipo) values (v_mov, 'conteo');
      v_ajustes := v_ajustes + 1;
    end if;

    if r.line_id is not null then
      update public.physical_count_lines
         set stock_at_complete     = r.stock_hoy,
             applied_variance      = r.delta,
             unit_cost             = r.costo,
             variance_value        = r.delta * r.costo,
             applied_adjustment_id = v_mov
       where id = r.line_id;
    end if;

    update public._penda_act_plan
       set mov_conteo = v_mov, aplicado_en = now()
     where warehouse_id = r.warehouse_id and item_id = r.item_id;
  end loop;

  ---------------------------------------------------------------------------
  -- 4. El cuadre: lo que el PASO 1 dejó en _penda_act_cuadre, como una
  --    transferencia (salida de un almacén, entrada en el otro)
  ---------------------------------------------------------------------------
  for r in
    select c.*, i.name as insumo
      from public._penda_act_cuadre c
      join public.inventory_items i on i.id = c.item_id
     order by c.desde, c.hacia, i.name
  loop
    insert into public.inventory_movements (
      business_id, warehouse_id, item_id, movement_type, quantity,
      cost_per_unit, reference_type, notes
    ) values (
      v_biz, r.desde_wid, r.item_id, 'transfer_out', -r.qty,
      nullif(r.costo, 0), 'conteo_arranque_cuadre',
      'Cuadre del conteo del 1-oct: se vendió desde ' || r.hacia
      || ' lo que estaba aquí, sin transferencia'
    ) returning id into v_mov;
    insert into public._penda_act_movs (movement_id, tipo) values (v_mov, 'cuadre');

    insert into public.inventory_movements (
      business_id, warehouse_id, item_id, movement_type, quantity,
      cost_per_unit, reference_type, notes
    ) values (
      v_biz, r.hacia_wid, r.item_id, 'transfer_in', r.qty,
      nullif(r.costo, 0), 'conteo_arranque_cuadre',
      'Cuadre del conteo del 1-oct: vino de ' || r.desde || ' sin transferencia'
    ) returning id into v_mov;
    insert into public._penda_act_movs (movement_id, tipo) values (v_mov, 'cuadre');

    v_cuadres := v_cuadres + 1;
  end loop;

  ---------------------------------------------------------------------------
  -- 5. Cerrar los 4 de octubre (los de septiembre se quedan abiertos)
  ---------------------------------------------------------------------------
  update public.physical_count_sessions
     set status = 'completed', completed_at = now()
   where business_id = v_biz and status = 'in_progress'
     and code in ('PC-2026-000008','PC-2026-000009','PC-2026-000011','PC-2026-000012');

  raise notice 'LISTO — % ajustes de conteo, % cuadres, 4 conteos de octubre cerrados. '
               'Los de septiembre siguen abiertos.',
               v_ajustes, v_cuadres;
end
$$;


-- ═══ VERIFICAR (una sola consulta) ══════════════════════════════════════════
--   ESPERADO: «diferencia» = 0 en todos los almacenes, o igual a lo vendido o
--   comprado DESPUÉS de armar el plan (columna «movido después»).
with
p as (select * from public._penda_act_plan),
despues as (
  -- solo los pares del plan: un insumo que no está en el plan no se compara
  select im.warehouse_id, sum(im.quantity) as q
    from public.inventory_movements im
    join p on p.warehouse_id = im.warehouse_id and p.item_id = im.item_id
   where im.created_at > p.creado_en
     and im.id not in (select movement_id from public._penda_act_movs)
   group by im.warehouse_id
)
select p.almacen,
       count(*)                                                as insumos,
       round(sum(p.final + p.cuadre), 2)                       as esperado,
       round(sum(coalesce(st.quantity, 0)), 2)                 as stock_ahora,
       round(coalesce(max(d.q), 0), 2)                         as movido_despues,
       round(sum(coalesce(st.quantity, 0)) - sum(p.final + p.cuadre)
             - coalesce(max(d.q), 0), 2)                       as diferencia,
       count(*) filter (where p.aplicado_en is null)           as sin_aplicar
from p
left join public.inventory_stock st
       on st.warehouse_id = p.warehouse_id and st.item_id = p.item_id
left join despues d on d.warehouse_id = p.warehouse_id
group by p.almacen
order by p.almacen;


-- ═══ PARA RECONTAR (correr aparte, después del PASO 2) ═════════════════════
--   Lo que queda NEGATIVO: se vendió desde el 1-oct pero nadie lo contó ese
--   día ni se ha comprado (p. ej. CARNE SALADA −91 lb). Existía y no se
--   contó. Se recuenta en la app con un conteo nuevo SOLO de estos insumos;
--   al cerrarlo, el stock queda en lo contado.
/*
select p.almacen, p.insumo, p.unidad,
       coalesce(regexp_replace(round(p.contado, 2)::text, '\.?0+$', ''), 'nadie') as contado_1oct,
       round(p.neto, 2)                as movido_desde_1oct,
       round(p.final + p.cuadre, 2)    as queda
  from public._penda_act_plan p
 where p.final + p.cuadre < 0
 order by p.almacen, p.final + p.cuadre;
*/


-- ═══ DESHACER ═══════════════════════════════════════════════════════════════
--   Reversa cada movimiento con su contrario (el historial se conserva),
--   y reabre los conteos de octubre con sus renglones como estaban. Después
--   se puede volver a correr el PASO 1.
/*
set statement_timeout = '15min';
do $$
declare r record; v_n int := 0;
begin
  for r in
    select im.* from public.inventory_movements im
    join public._penda_act_movs m on m.movement_id = im.id
  loop
    insert into public.inventory_movements (
      business_id, warehouse_id, item_id, movement_type, quantity,
      cost_per_unit, reference_id, reference_type, notes
    ) values (
      r.business_id, r.warehouse_id, r.item_id, 'adjustment', -r.quantity,
      r.cost_per_unit, r.reference_id, 'conteo_arranque_deshacer',
      'Reversa del conteo de arranque');
    v_n := v_n + 1;
  end loop;

  update public.physical_count_lines l
     set counted_quantity = b.counted_quantity, counter_notes = b.counter_notes,
         stock_at_complete = b.stock_at_complete, applied_variance = b.applied_variance,
         unit_cost = b.unit_cost, variance_value = b.variance_value,
         applied_adjustment_id = b.applied_adjustment_id
    from public._penda_act_bk_lineas b where b.id = l.id;

  update public.physical_count_sessions s
     set warehouse_id = b.warehouse_id, status = b.status, completed_at = b.completed_at,
         cancelled_at = b.cancelled_at, cancellation_reason = b.cancellation_reason
    from public._penda_act_bk_sesiones b where b.id = s.id;

  update public.warehouses w set shows_in_pos = b.shows_in_pos
    from public._penda_act_bk_almacenes b where b.id = w.id;

  update public._penda_act_plan set aplicado_en = null, mov_conteo = null;
  drop table public._penda_act_movs;
  drop table public._penda_act_bk_lineas;
  drop table public._penda_act_bk_sesiones;
  drop table public._penda_act_bk_almacenes;
  raise notice 'Deshecho: % movimientos reversados, sesiones reabiertas.', v_n;
end $$;
*/

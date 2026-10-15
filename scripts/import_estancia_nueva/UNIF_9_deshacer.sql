-- =============================================================================
-- UNIF_9_deshacer.sql — Estancia Nueva · CAFETERÍA (85924083)
--
-- Deshace UNIF_1_aplicar.sql:
--   · cada movimiento de la unificación recibe su INVERSO (transfer_out ↔
--     transfer_in, ajustes con el signo cambiado). No se borra nada del kardex;
--   · las bodegas vuelven a como estaban (nombre, activa, principal, en POS), la
--     bandera de secciones también, y las órdenes de compra que se pasaron a
--     la principal y siguen sin recibir vuelven a su bodega; todo desde el
--     último respaldo.
--
-- Lo que NO deshace: el conteo abandonado que se canceló sigue cancelado (su
-- foto es del 01-oct, aplicarlo sería peor). Las capas de costo no vuelven
-- exactas: los inversos pasan por el motor como cualquier movimiento.
-- Tampoco: las órdenes abiertas que el paso 3 pasó a la principal
-- siguen consumiendo de la principal (el total es el mismo; solo cambia de
-- qué bodega salió). Las ventas hechas después de aplicar se quedan donde
-- cayeron (en la principal).
--
-- Idempotente: invierte solo lo que todavía no tiene inverso.
-- GENERADO por build_unificar_almacen.py. Editar el _tpl, no este archivo.
-- =============================================================================

begin;

set local lock_timeout = '5s';
set local statement_timeout = '300s';

do $deshacer$
declare
  v_biz    constant uuid := '85924083-2e8e-4e64-8192-808ee24674ed';
  REF  constant text := 'unificacion_almacen_20261013';
  UNDO constant text := 'deshacer_unificacion_almacen_20261013';
  v_run timestamptz;
  v_n   int;
begin
  if to_regclass('public.zz_backup_unif_almacen_85924083') is null then
    raise exception 'No existe el respaldo: la unificación nunca se aplicó.';
  end if;

  select max(corrida) into v_run
  from public.zz_backup_unif_almacen_85924083
  where tipo = 'warehouse';

  insert into public.inventory_movements
    (business_id, warehouse_id, item_id, movement_type, quantity,
     cost_per_unit, reference_id, reference_type, reason_code, notes)
  select m.business_id, m.warehouse_id, m.item_id,
         (case m.movement_type::text
            when 'transfer_out' then 'transfer_in'
            when 'transfer_in'  then 'transfer_out'
            else m.movement_type::text end)::public.movement_type,
         -m.quantity, m.cost_per_unit, m.id, UNDO,
         case when m.movement_type::text = 'adjustment' then 'correction' end,
         'Deshace: ' || coalesce(m.notes, 'unificación de almacenes')
  from public.inventory_movements m
  where m.business_id = v_biz
    and m.reference_type like REF || '%'
    and not exists (select 1 from public.inventory_movements u
                     where u.reference_type = UNDO and u.reference_id = m.id);
  get diagnostics v_n = row_count;

  if v_n = 0 then
    raise exception 'No hay nada que deshacer (ya se deshizo o nunca se aplicó).';
  end if;

  update public.warehouses w
     set name         = coalesce(b.datos->>'name', w.name),
         is_active    = (b.datos->>'is_active')::boolean,
         is_main      = (b.datos->>'is_main')::boolean,
         shows_in_pos = coalesce((b.datos->>'shows_in_pos')::boolean, false)
    from public.zz_backup_unif_almacen_85924083 b
   where b.tipo = 'warehouse' and b.corrida = v_run
     and b.ref_id = w.id and w.business_id = v_biz;

  -- Órdenes de compra que se pasaron a la principal y siguen sin recibir.
  update public.purchase_orders po
     set warehouse_id = (b.datos->>'warehouse_id')::uuid
    from public.zz_backup_unif_almacen_85924083 b
   where b.tipo = 'purchase_order' and b.corrida = v_run
     and b.ref_id = po.id and po.business_id = v_biz
     and po.status::text in ('draft', 'sent', 'partial');

  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'business_settings'
                and column_name = 'warehouse_sections_enabled') then
    execute 'update public.business_settings
                set warehouse_sections_enabled = $2
              where business_id = $1
                and warehouse_sections_enabled is distinct from $2'
      using v_biz,
            (select (b.datos->>'warehouse_sections_enabled')::boolean
               from public.zz_backup_unif_almacen_85924083 b
              where b.tipo = 'business_settings' and b.corrida = v_run
              limit 1);
  end if;

  raise notice 'Deshecho: % movimientos invertidos; bodegas como en el respaldo de %.', v_n, v_run;
end
$deshacer$;

commit;

-- Cómo quedaron las bodegas.
select w.name as bodega,
       format('principal=%s · activa=%s · en_POS=%s', coalesce(w.is_main, false),
              coalesce(w.is_active, true), w.shows_in_pos) as estado,
       (select count(*) from public.inventory_stock s
         where s.warehouse_id = w.id and s.quantity <> 0) as items_con_existencia,
       (select round(coalesce(sum(s.quantity), 0), 2) from public.inventory_stock s
         where s.warehouse_id = w.id) as unidades
from public.warehouses w
where w.business_id = '85924083-2e8e-4e64-8192-808ee24674ed'::uuid
order by w.is_main desc nulls last, w.name;

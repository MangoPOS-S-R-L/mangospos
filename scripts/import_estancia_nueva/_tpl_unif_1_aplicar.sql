-- =============================================================================
-- UNIF_1_aplicar.sql — Estancia Nueva · CAFETERÍA (85924083)
--
-- UNA SOLA BODEGA: la principal. Todo lo que haya en las demás se muda a la
-- principal y las demás se APAGAN (no se borran: su kardex queda).
--
-- Y LA EXISTENCIA DE LO CONTADO EL 01-OCT QUEDA EN:
--     contado (cafetería + almacén, del JSON)
--   + todo lo que se movió DESPUÉS del corte (ventas restan; compras, mermas,
--     anulaciones, producción... cuentan con su signo)
--   El corte = __CORTE__ (hora RD): la cafetería se contó en la mañana,
--   antes de abrir (dueño, 13-oct; en la app se empezó a contar a las 11:55 y
--   la primera venta fue 12:58). Así se descuentan TODAS las ventas. El
--   almacén (__PC_CORTE__) se contó a las 14:24, pero de ahí no se vende: lo
--   que se vendió antes salió de los estantes ya contados.
--   Los ajustes de los conteos del 01-oct NO cuentan: el JSON los reemplaza
--   (si no, el almacén se sumaría dos veces).
--   Lo que NO se contó conserva su número; solo se muda a la principal.
--
-- PASOS (todo en una transacción; si algo no cuadra, no queda nada hecho):
--   0. Guardias: ya corrido, una sola principal, conteo del almacén, conteos
--      abiertos (salvo __PC_ABANDONADO__) o posteriores, transferencias sin
--      cerrar, códigos ambiguos, ajustes MANUALES después del corte.
--   1. Respaldo en public.zz_backup_unif_almacen_85924083.
--   2. __PC_ABANDONADO__ (conteo de la cafetería empezado el 01-oct en la app y
--      abandonado, congelado con la foto de ese día) → cancelado: aplicarlo
--      hoy pisaría todo. La principal pasa a llamarse «__NOMBRE_PRINCIPAL__».
--      Las otras bodegas: is_active=false, is_main=false, shows_in_pos=false;
--      warehouse_sections_enabled=false. Órdenes de compra pendientes
--      (draft/sent/partial) que apuntaban a otra bodega → la principal.
--   3. Órdenes ABIERTAS que consumieron de otra bodega se recalculan con
--      consume_inventory_from_order: su consumo pasa a la principal (si no, al
--      anular un ítem devolvería la mercancía a una bodega apagada).
--   4. Mudanza: transfer_out/transfer_in (saldo positivo) o ajuste de
--      corrección (saldo negativo) de cada bodega a la principal.
--   5. Ajuste por conteo en la principal: objetivo − lo que hay.
--      Con capas de costo encendidas (fifo/lifo/average): las ventas desde el
--      corte salieron SIN capa (faltante). Las capas que crea esta corrida se
--      netean de eso, para que lo que queda en capas = la existencia.
--   6. Verificación: otras bodegas en 0, contados = objetivo, no contados
--      con el mismo total de antes, una sola bodega activa.
--
-- ANTES: correr UNIF_0_diagnostico.sql. DESHACER: UNIF_9_deshacer.sql.
-- GENERADO por build_unificar_almacen.py (__N_CONTEO__ códigos). Editar el
-- .py o el _tpl, no este archivo.
-- =============================================================================

begin;

set local lock_timeout = '5s';
set local statement_timeout = '300s';

create temp table _conteo (
  codigo      text primary key,
  descripcion text not null,
  caf         numeric not null,
  alm         numeric not null,
  total       numeric not null
) on commit drop;

insert into _conteo (codigo, descripcion, caf, alm, total) values
__CONTEO_VALUES__;

-- Respaldo y bitácora del reporte. RLS encendido y sin políticas: no se ve
-- por la API, solo desde el SQL Editor.
create table if not exists public.zz_backup_unif_almacen_85924083 (
  id        bigserial primary key,
  corrida   timestamptz not null,
  tipo      text not null,
  ref_id    uuid,
  orden     int,
  datos     jsonb not null
);
alter table public.zz_backup_unif_almacen_85924083 enable row level security;

do $unif$
declare
  v_biz    constant uuid := '__BUSINESS__';
  PC   constant text := '__PC_CORTE__';
  PC_ABANDONADO constant text := '__PC_ABANDONADO__';
  CORTE constant timestamptz := '__CORTE__';
  NOMBRE_PRINCIPAL constant text := '__NOMBRE_PRINCIPAL__';
  REF  constant text := 'unificacion_almacen_20261013';
  TZ   constant text := 'America/Santo_Domingo';
  -- AJUSTES MANUALES (reference_type stock_adjustment o vacío) hechos después
  -- del corte sobre ítems contados. Los de documentos (p. ej. anular una
  -- recepción directa) cuentan siempre, como la compra que anulan.
  --   'abortar' → no aplica nada y avisa (por defecto)
  --   'sumar'   → cuentan, como una compra o una merma
  --   'ignorar' → no cuentan (el conteo del 01-oct manda)
  AJUSTES_MANUALES constant text := 'abortar';

  v_run   timestamptz := clock_timestamp();
  v_main  uuid;
  v_main_name text;
  v_pc    uuid;
  v_corte timestamptz;
  v_n     int;
  v_txt   text;
  v_ord   uuid;
  v_reorders int := 0;
  v_compras int := 0;
  v_apagadas text;
  v_cancelado text;
  v_metodo text;
  v_capa record;
  v_item record;
  v_need numeric;
  v_take numeric;
  v_neteado numeric := 0;
begin
  -- ---------------------------------------------------------------------
  -- 0. Guardias
  -- ---------------------------------------------------------------------
  -- Corrida previa SIN deshacer = movimientos REF sin su inverso.
  if exists (select 1 from public.inventory_movements m
              where m.business_id = v_biz and m.reference_type like REF || '%'
                and not exists (select 1 from public.inventory_movements u
                                 where u.reference_type = 'deshacer_' || REF
                                   and u.reference_id = m.id)) then
    raise exception 'YA SE CORRIÓ (hay movimientos %). Para repetir, primero UNIF_9_deshacer.sql.', REF;
  end if;

  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'inventory_movements'
                    and column_name = 'reason_code')
     or not exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'warehouses'
                       and column_name = 'shows_in_pos') then
    raise exception 'Faltan columnas (inventory_movements.reason_code o warehouses.shows_in_pos): no se aplicó nada.';
  end if;

  select count(*) into v_n
  from public.warehouses
  where business_id = v_biz and coalesce(is_main, false) and coalesce(is_active, true)
    and name <> '__IN_TRANSIT__';
  if v_n <> 1 then
    raise exception 'Se esperaba UNA bodega principal activa y hay %. Marcar la principal en la app y volver a correr.', v_n;
  end if;

  select id, name into v_main, v_main_name
  from public.warehouses
  where business_id = v_biz and coalesce(is_main, false) and coalesce(is_active, true)
    and name <> '__IN_TRANSIT__';

  v_corte := CORTE;

  -- El conteo del almacén: sus ajustes los reemplaza el JSON.
  select id into v_pc
  from public.physical_count_sessions
  where business_id = v_biz and code = PC and status = 'completed';
  if v_pc is null then
    raise exception 'No está el conteo % completado (el almacén del JSON). No se aplicó nada.', PC;
  end if;

  if exists (select 1 from public.warehouses
              where business_id = v_biz and id <> v_main and name = NOMBRE_PRINCIPAL) then
    raise exception 'Ya hay otra bodega llamada «%». No se aplicó nada.', NOMBRE_PRINCIPAL;
  end if;

  -- Conteos abiertos: el abandonado del 01-oct se cancela abajo; otro, aborta.
  select string_agg(code || ' (' || status || ')', ', ') into v_txt
  from public.physical_count_sessions
  where business_id = v_biz and status in ('draft', 'in_progress')
    and not (code = PC_ABANDONADO
             and coalesce((frozen_at at time zone TZ)::date, date '2026-10-01')
                 = date '2026-10-01');
  if v_txt is not null then
    raise exception 'Hay conteos abiertos: %. Cerrarlos o cancelarlos antes.', v_txt;
  end if;

  select string_agg(code, ', ') into v_txt
  from public.physical_count_sessions
  where business_id = v_biz and status = 'completed'
    and (frozen_at at time zone TZ)::date > date '2026-10-01';
  if v_txt is not null then
    raise exception 'Hay conteos completados DESPUÉS del 01-oct (%): decidir si mandan ellos o el JSON. No se aplicó nada.', v_txt;
  end if;

  select count(*) into v_n
  from public.stock_transfers
  where business_id = v_biz and status in ('sent', 'pending_approval');
  if v_n > 0 then
    raise exception 'Hay % transferencias sin cerrar: recibirlas o cancelarlas antes.', v_n;
  end if;

  -- Emparejar por código: sku primero; si no hay sku, código de barras.
  create temp table _match on commit drop as
  select c.*,
         (select count(*) from public.inventory_items i
           where i.business_id = v_biz and i.sku = c.codigo)     as n_sku,
         (select count(*) from public.inventory_items i
           where i.business_id = v_biz and i.barcode = c.codigo) as n_bc,
         null::uuid as item_id
  from _conteo c;

  update _match m
     set item_id = (select i.id from public.inventory_items i
                     where i.business_id = v_biz and i.sku = m.codigo)
   where m.n_sku = 1;
  update _match m
     set item_id = (select i.id from public.inventory_items i
                     where i.business_id = v_biz and i.barcode = m.codigo)
   where m.n_sku = 0 and m.n_bc = 1;

  select string_agg(codigo || ' ' || descripcion, '; ') into v_txt
  from _match where item_id is null and not (n_sku = 0 and n_bc = 0);
  if v_txt is not null then
    raise exception 'Códigos con más de un insumo (ambiguos): %. No se aplicó nada.', v_txt;
  end if;

  select string_agg(z.codigos, ' | ') into v_txt
  from (select string_agg(codigo, ' y ') as codigos from _match
         where item_id is not null group by item_id having count(*) > 1) z;
  if v_txt is not null then
    raise exception 'Dos códigos del conteo caen en el MISMO insumo: %. No se aplicó nada.', v_txt;
  end if;

  select count(*) into v_n from _match where item_id is not null;
  if v_n < __MIN_MATCH__ then
    raise exception 'Solo % de % códigos existen en este negocio: ¿es el negocio correcto? No se aplicó nada.',
      v_n, (select count(*) from _match);
  end if;

  -- ---------------------------------------------------------------------
  -- 1. Respaldo
  -- ---------------------------------------------------------------------
  insert into public.zz_backup_unif_almacen_85924083 (corrida, tipo, ref_id, datos)
  select v_run, 'warehouse', w.id, to_jsonb(w)
  from public.warehouses w where w.business_id = v_biz;

  insert into public.zz_backup_unif_almacen_85924083 (corrida, tipo, ref_id, datos)
  select v_run, 'business_settings', v_biz, to_jsonb(s)
  from public.business_settings s where s.business_id = v_biz;

  insert into public.zz_backup_unif_almacen_85924083 (corrida, tipo, ref_id, datos)
  select v_run, 'stock', s.warehouse_id,
         jsonb_build_object('item_id', s.item_id, 'quantity', s.quantity)
  from public.inventory_stock s
  join public.warehouses w on w.id = s.warehouse_id
  where w.business_id = v_biz and s.quantity <> 0;

  insert into public.zz_backup_unif_almacen_85924083 (corrida, tipo, ref_id, datos)
  select v_run, 'count_session', s.id, to_jsonb(s)
  from public.physical_count_sessions s
  where s.business_id = v_biz and s.code = PC_ABANDONADO
    and s.status in ('draft', 'in_progress');

  -- ---------------------------------------------------------------------
  -- 2. Una sola bodega
  -- ---------------------------------------------------------------------
  -- El conteo abandonado del 01-oct: congelado con la foto de ese día, si
  -- alguien lo aplicara hoy pisaría la existencia. Igual que el botón
  -- Cancelar de la app (fn_physical_count_cancel), con su motivo.
  update public.physical_count_sessions
     set status = 'cancelled', cancelled_at = now(),
         cancellation_reason = 'Abandonado el 01-oct; la cafetería se cargó con '
                               || 'la unificación de almacenes del 13-oct'
   where business_id = v_biz and code = PC_ABANDONADO
     and status in ('draft', 'in_progress')
  returning code into v_cancelado;

  update public.warehouses
     set name = NOMBRE_PRINCIPAL
   where id = v_main and name <> NOMBRE_PRINCIPAL;

  select string_agg(name, ', ' order by name) into v_apagadas
  from public.warehouses
  where business_id = v_biz and id <> v_main and name <> '__IN_TRANSIT__'
    and coalesce(is_active, true);

  update public.warehouses
     set is_active = false, is_main = false, shows_in_pos = false
   where business_id = v_biz and id <> v_main and name <> '__IN_TRANSIT__'
     and (coalesce(is_active, true) or coalesce(is_main, false) or shows_in_pos);

  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'business_settings'
                and column_name = 'warehouse_sections_enabled') then
    execute 'update public.business_settings set warehouse_sections_enabled = false
              where business_id = $1 and warehouse_sections_enabled' using v_biz;
  end if;

  -- Órdenes de COMPRA pendientes que apuntan a una bodega que se apaga: al
  -- recibirlas, la mercancía caería en esa bodega. Pasan a la principal.
  insert into public.zz_backup_unif_almacen_85924083 (corrida, tipo, ref_id, datos)
  select v_run, 'purchase_order', po.id,
         jsonb_build_object('warehouse_id', po.warehouse_id, 'status', po.status)
  from public.purchase_orders po
  where po.business_id = v_biz and po.warehouse_id <> v_main
    and po.status::text in ('draft', 'sent', 'partial');

  update public.purchase_orders po
     set warehouse_id = v_main
   where po.business_id = v_biz and po.warehouse_id <> v_main
     and po.status::text in ('draft', 'sent', 'partial');
  get diagnostics v_compras = row_count;

  -- ---------------------------------------------------------------------
  -- 3. Órdenes abiertas que consumieron de otra bodega
  -- ---------------------------------------------------------------------
  for v_ord in
    select distinct z.reference_id
    from (select im.reference_id
            from public.inventory_movements im
            join public.orders o on o.id = im.reference_id
           where im.business_id = v_biz
             and im.reference_type = 'order' and im.movement_type = 'sale'
             and im.warehouse_id <> v_main
             and o.status in ('open', 'sent', 'served')
             and coalesce(o.status_ext::text, 'open') not in ('paid', 'void')
           group by im.reference_id, im.warehouse_id, im.item_id
          having sum(im.quantity) <> 0) z
  loop
    perform public.consume_inventory_from_order(v_ord);
    v_reorders := v_reorders + 1;
  end loop;

  -- ---------------------------------------------------------------------
  -- Objetivo de cada ítem contado = contado + lo movido después del corte
  -- ---------------------------------------------------------------------
  create temp table _post on commit drop as
  select im.item_id,
         sum(im.quantity) as todo,
         coalesce(sum(im.quantity) filter (
                    where im.movement_type = 'adjustment'
                      and coalesce(im.reference_type, '') in ('', 'stock_adjustment')), 0)
           as ajustes,
         count(*) filter (where im.movement_type = 'adjustment'
                            and coalesce(im.reference_type, '') in ('', 'stock_adjustment'))
           as n_ajustes
  from public.inventory_movements im
  join public.warehouses w on w.id = im.warehouse_id
  where im.business_id = v_biz
    and im.created_at > v_corte
    and w.name <> '__IN_TRANSIT__'
    and coalesce(im.reference_type, '') not like '%unificacion_almacen%'
    -- coalesce: con reference_type o reference_id en NULL (compras, ajustes
    -- a mano) el `not (...)` daría NULL y el movimiento se perdería.
    and not coalesce(im.reference_type = 'physical_count'
                     and im.reference_id in (
                       select s.id from public.physical_count_sessions s
                        where s.business_id = v_biz and s.status = 'completed'
                          and (s.frozen_at at time zone TZ)::date = date '2026-10-01'),
                     false)
    and im.item_id in (select item_id from _match where item_id is not null)
  group by im.item_id;

  select count(*) into v_n from _post where n_ajustes > 0;
  if v_n > 0 and AJUSTES_MANUALES = 'abortar' then
    raise exception '% ítems contados tienen AJUSTES MANUALES después del corte. Ver la sección 5 del diagnóstico y poner AJUSTES_MANUALES = sumar o ignorar. No se aplicó nada.', v_n;
  end if;

  create temp table _obj on commit drop as
  select m.codigo, m.descripcion, m.item_id, m.total,
         coalesce(p.todo, 0)
           - case when AJUSTES_MANUALES = 'ignorar' then coalesce(p.ajustes, 0) else 0 end
           as post
  from _match m
  left join _post p on p.item_id = m.item_id
  where m.item_id is not null;

  -- Total de cada ítem en todas las bodegas, ANTES de mudar (para verificar
  -- que a los no contados no les cambia nada).
  create temp table _antes on commit drop as
  select s.item_id, sum(s.quantity) as q
  from public.inventory_stock s
  join public.warehouses w on w.id = s.warehouse_id
  where w.business_id = v_biz and w.name <> '__IN_TRANSIT__'
  group by s.item_id;

  -- ---------------------------------------------------------------------
  -- 4. Mudanza a la principal
  -- ---------------------------------------------------------------------
  create temp table _mudanza on commit drop as
  select s.warehouse_id, w.name as bodega, s.item_id, s.quantity,
         nullif(coalesce(i.cost, 0), 0) as cost
  from public.inventory_stock s
  join public.warehouses w on w.id = s.warehouse_id
  join public.inventory_items i on i.id = s.item_id
  where w.business_id = v_biz and w.id <> v_main and w.name <> '__IN_TRANSIT__'
    and s.quantity <> 0;

  insert into public.inventory_movements
    (business_id, warehouse_id, item_id, movement_type, quantity,
     cost_per_unit, reference_id, reference_type, reason_code, notes)
  select v_biz, x.warehouse_id, x.item_id,
         (case when x.quantity > 0 then 'transfer_out' else 'adjustment' end)::public.movement_type,
         -x.quantity, x.cost, v_main, REF,
         case when x.quantity < 0 then 'correction' end,
         'Unificación de almacenes: pasa a ' || NOMBRE_PRINCIPAL
  from _mudanza x;

  insert into public.inventory_movements
    (business_id, warehouse_id, item_id, movement_type, quantity,
     cost_per_unit, reference_id, reference_type, reason_code, notes)
  select v_biz, v_main, x.item_id,
         (case when x.quantity > 0 then 'transfer_in' else 'adjustment' end)::public.movement_type,
         x.quantity, x.cost, x.warehouse_id, REF,
         case when x.quantity < 0 then 'correction' end,
         'Unificación de almacenes: viene de ' || x.bodega
  from _mudanza x;

  -- ---------------------------------------------------------------------
  -- 5. Ajuste por conteo en la principal
  -- ---------------------------------------------------------------------
  create temp table _aj on commit drop as
  select o.item_id, o.codigo, o.descripcion, o.total, o.post,
         o.total + o.post as objetivo,
         coalesce((select s.quantity from public.inventory_stock s
                    where s.warehouse_id = v_main and s.item_id = o.item_id), 0) as en_principal
  from _obj o;

  insert into public.inventory_movements
    (business_id, warehouse_id, item_id, movement_type, quantity,
     cost_per_unit, reference_id, reference_type, reason_code, notes)
  select v_biz, v_main, a.item_id, 'adjustment'::public.movement_type,
         a.objetivo - a.en_principal,
         nullif(coalesce(i.cost, 0), 0), v_pc, REF || '_conteo', 'physical_count',
         format('Conteo 01-oct (cafetería + almacén) = %s; movido después del conteo = %s',
                a.total, a.post)
  from _aj a
  join public.inventory_items i on i.id = a.item_id
  where a.objetivo - a.en_principal <> 0;

  -- Capas de costo (solo si el motor está encendido). Las ventas desde el
  -- corte salieron sin capa y quedaron como faltante; las capas que acaba de
  -- crear esta corrida (la mudanza y el ajuste) traen la cantidad completa.
  -- Sin esto, lo que queda en capas superaría la existencia en lo ya vendido
  -- Por cada par bodega-insumo, la más nueva primero, hasta capas = existencia:
  --   · en la principal se recortan SOLO capas de esta corrida;
  --   · en las bodegas apagadas (quedan en 0 para siempre) cualquier capa que
  --     sobre: nadie la consumiría y la valuación por capas la contaría.
  select coalesce(bs.inventory_costing_method, 'last_price') into v_metodo
  from public.business_settings bs where bs.business_id = v_biz;

  if coalesce(v_metodo, 'last_price') <> 'last_price'
     and to_regclass('public.inventory_cost_layers') is not null then
    for v_item in
      select l.warehouse_id, l.item_id,
             sum(l.quantity_remaining)
               - greatest(coalesce(max(s.quantity), 0), 0) as exceso
      from public.inventory_cost_layers l
      join public.warehouses w on w.id = l.warehouse_id
      left join public.inventory_stock s
        on s.warehouse_id = l.warehouse_id and s.item_id = l.item_id
      where l.business_id = v_biz and w.name <> '__IN_TRANSIT__'
        and l.quantity_remaining > 0
        and (l.warehouse_id <> v_main
             or exists (select 1 from public.inventory_cost_layers l2
                          join public.inventory_movements m2 on m2.id = l2.source_movement_id
                         where l2.warehouse_id = l.warehouse_id and l2.item_id = l.item_id
                           and l2.quantity_remaining > 0
                           and m2.reference_type like REF || '%'))
      group by l.warehouse_id, l.item_id
      having sum(l.quantity_remaining)
               - greatest(coalesce(max(s.quantity), 0), 0) > 0
    loop
      v_need := v_item.exceso;
      for v_capa in
        select l.id, l.quantity_remaining
        from public.inventory_cost_layers l
        left join public.inventory_movements m on m.id = l.source_movement_id
        where l.business_id = v_biz and l.warehouse_id = v_item.warehouse_id
          and l.item_id = v_item.item_id and l.quantity_remaining > 0
          and (v_item.warehouse_id <> v_main
               or coalesce(m.reference_type, '') like REF || '%')
        order by l.seq desc
      loop
        exit when v_need <= 0;
        v_take := least(v_capa.quantity_remaining, v_need);
        update public.inventory_cost_layers
           set quantity_remaining = quantity_remaining - v_take,
               notes = concat_ws(' · ', notes,
                                 'neteada ' || v_take || ' por ventas sin capa desde el corte')
         where id = v_capa.id;
        insert into public.zz_backup_unif_almacen_85924083 (corrida, tipo, ref_id, datos)
        values (v_run, 'capa_neteada', v_capa.id,
                jsonb_build_object('warehouse_id', v_item.warehouse_id,
                                   'item_id', v_item.item_id, 'cantidad', v_take));
        v_need := v_need - v_take;
        v_neteado := v_neteado + v_take;
      end loop;
    end loop;
  end if;

  -- ---------------------------------------------------------------------
  -- 6. Verificación: si algo no cuadra, se deshace todo
  -- ---------------------------------------------------------------------
  select count(*) into v_n
  from public.inventory_stock s
  join public.warehouses w on w.id = s.warehouse_id
  where w.business_id = v_biz and w.id <> v_main and w.name <> '__IN_TRANSIT__'
    and s.quantity <> 0;
  if v_n > 0 then
    raise exception 'VERIFICACIÓN: quedan % existencias fuera de la principal. No se aplicó nada.', v_n;
  end if;

  select count(*) into v_n
  from _aj a
  left join public.inventory_stock s on s.warehouse_id = v_main and s.item_id = a.item_id
  where coalesce(s.quantity, 0) <> a.objetivo;
  if v_n > 0 then
    raise exception 'VERIFICACIÓN: % ítems contados no quedaron en su objetivo. No se aplicó nada.', v_n;
  end if;

  select count(*) into v_n
  from (
    select coalesce(x.item_id, y.item_id) as item_id,
           coalesce(x.q, 0) as antes, coalesce(y.q, 0) as despues
    from _antes x
    full join (select s.item_id, sum(s.quantity) as q
                 from public.inventory_stock s
                 join public.warehouses w on w.id = s.warehouse_id
                where w.business_id = v_biz and w.name <> '__IN_TRANSIT__'
                group by s.item_id) y on y.item_id = x.item_id
  ) z
  where z.item_id not in (select item_id from _obj)
    and z.antes <> z.despues;
  if v_n > 0 then
    raise exception 'VERIFICACIÓN: % ítems NO contados cambiaron de total. No se aplicó nada.', v_n;
  end if;

  select count(*) into v_n
  from public.warehouses
  where business_id = v_biz and coalesce(is_active, true) and name <> '__IN_TRANSIT__';
  if v_n <> 1 then
    raise exception 'VERIFICACIÓN: quedaron % bodegas activas. No se aplicó nada.', v_n;
  end if;

  -- ---------------------------------------------------------------------
  -- Reporte (queda guardado en la tabla de respaldo, tipo = 'reporte')
  -- ---------------------------------------------------------------------
  insert into public.zz_backup_unif_almacen_85924083 (corrida, tipo, orden, datos)
  select v_run, 'reporte', r.orden,
         jsonb_build_object('concepto', r.concepto, 'resultado', r.resultado)
  from (
    select 1 as orden, 'Bodega única (principal)' as concepto,
           NOMBRE_PRINCIPAL || case when v_main_name <> NOMBRE_PRINCIPAL
                                    then ' (antes «' || v_main_name || '»)' else '' end
             as resultado
    union all
    select 2, 'Bodegas apagadas', coalesce(v_apagadas, 'ninguna (ya era una sola)')
    union all
    select 3, 'Corte (ventas descontadas desde)',
           to_char(v_corte at time zone TZ, 'DD/MM/YYYY HH24:MI') || ' hora RD'
    union all
    select 3, 'Conteo abandonado cancelado', coalesce(v_cancelado, 'ninguno')
    union all
    select 4, 'Órdenes abiertas recalculadas a la principal', v_reorders::text
    union all
    select 4, 'Órdenes de compra pendientes pasadas a la principal', v_compras::text
    union all
    select 5, 'Mudanza a la principal',
           (select format('%s ítems · %s u desde %s bodega(s)', count(distinct item_id),
                          round(coalesce(sum(quantity), 0), 2), count(distinct warehouse_id))
              from _mudanza)
    union all
    select 6, 'Códigos del conteo',
           (select format('%s líneas · %s encontradas · %s no existen en el sistema',
                          count(*), count(item_id),
                          count(*) filter (where item_id is null)) from _match)
    union all
    select 7, 'No existen (no se cargaron)',
           coalesce((select string_agg(codigo || ' ' || descripcion || ' = ' || total, '; ')
                       from _match where item_id is null), 'ninguno')
    union all
    select 8, 'Contado → objetivo',
           (select format('contado %s u · movido después del conteo %s u · objetivo %s u',
                          round(sum(total), 2), round(sum(post), 2), round(sum(objetivo), 2))
              from _aj)
    union all
    select 9, 'Ajuste por conteo en la principal',
           (select format('%s ítems · +%s u / %s u · valor RD$%s',
                          count(*) filter (where a.objetivo <> a.en_principal),
                          round(sum(greatest(a.objetivo - a.en_principal, 0)), 2),
                          round(sum(least(a.objetivo - a.en_principal, 0)), 2),
                          to_char(sum((a.objetivo - a.en_principal) * coalesce(i.cost, 0)),
                                  'FM999,999,990.00'))
              from _aj a join public.inventory_items i on i.id = a.item_id)
    union all
    select 10, 'Ajustes manuales después del corte',
           (select format('%s ítems (%s)', count(*), AJUSTES_MANUALES)
              from _post where n_ajustes > 0)
    union all
    select 11, 'Quedan en NEGATIVO (salió más de lo contado)',
           (select format('%s%s', count(*),
                          coalesce(': ' || string_agg(descripcion || ' ' || trim_scale(objetivo), '; '), ''))
              from _aj where objetivo < 0)
    union all
    select 12, 'Capas de costo (' || coalesce(v_metodo, 'last_price') || ')',
           case when coalesce(v_metodo, 'last_price') = 'last_price'
                then 'motor apagado: nada que netear'
                else 'neteadas ' || trim_scale(v_neteado) || ' u (ventas sin capa desde el corte; bodegas apagadas en 0)'
           end
    union all
    select 13, 'Verificación', '✓ otras bodegas en 0 · contados = objetivo · no contados intactos · 1 bodega activa'
  ) r;

  raise notice 'OK — bodega única "%": unificación aplicada.', v_main_name;
end
$unif$;

commit;

-- Reporte de esta corrida (la última).
select (b.datos->>'concepto') as concepto, (b.datos->>'resultado') as resultado
from public.zz_backup_unif_almacen_85924083 b
where b.tipo = 'reporte'
  and b.corrida = (select max(corrida) from public.zz_backup_unif_almacen_85924083
                    where tipo = 'reporte')
order by b.orden;

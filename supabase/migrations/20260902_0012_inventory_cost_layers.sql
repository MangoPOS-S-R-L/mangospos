-- =============================================================================
-- Capas de costo de inventario (PEPS / UEPS / promedio).
-- Entregables 1, 2 y 5 del informe DH Delgado Hernández & Asociados 02-09-2026.
--
-- CONTEXTO (lo que hay hoy):
--   El costeo real es "último precio": trg_inventory_movement_recost
--   (20260714_0001) deja inventory_items.cost en el costo de la última compra
--   con costo > 0, sin mirar cantidad ni unidad — por eso UNA compra de 1 saco
--   a RD$4,500 revaluó 251 libras de azúcar. Y las salidas por venta se
--   insertan SIN cost_per_unit (consume_inventory_from_order), así que no
--   existe costo de venta. inventory_lots NO es un motor de costeo: es una
--   bitácora de vencimiento opt-in (tracks_lots, default false).
--
-- ENTREGA:
--   1. business_settings.inventory_costing_method — bandera POR NEGOCIO con
--      default 'last_price' = el comportamiento de hoy, byte por byte. Aplicar
--      esta migración NO cambia a ningún negocio; el motor se enciende con un
--      UPDATE de una fila y se apaga igual.
--   2. inventory_cost_layers — una capa por entrada, con fecha, documento
--      (NCF / factura) y proveedor. Es el sustento que exige el Art. 57 del
--      Reglamento 139-98 para el costo unitario.
--   3. inventory_cost_consumptions — qué capa pagó cada salida. Sin esto el
--      costo de venta no es auditable movimiento a movimiento.
--   4. trg_inventory_cost_layers — tercer trigger sobre el ÚNICO punto por
--      donde pasa todo el inventario (after insert on inventory_movements),
--      junto a trg_inventory_stock_sync y trg_inventory_movement_recost. Es el
--      único lugar que también captura las ventas, que insertan directo sin
--      pasar por fn_inventory_record_movement.
--   5. Rellena inventory_movements.cost_per_unit en CADA SALIDA. La columna
--      existe desde el MVP (20260308_0016) y siempre estuvo nula en ventas.
--
-- MÉTODOS:
--   last_price  no hace nada (default, comportamiento heredado).
--   fifo (PEPS) consume la capa más antigua primero.
--   lifo (UEPS) consume la más reciente primero. Art. 303 Código Tributario.
--   average     consume proporcionalmente de TODAS las capas abiertas, de modo
--               que el promedio del remanente no se mueve y el valor retirado
--               es exactamente cantidad × promedio.
--
-- DEVOLUCIONES (crítico en este POS):
--   consume_inventory_from_order es idempotente y postea DELTAS: al editar una
--   orden puede postear un movimiento 'sale' con cantidad POSITIVA. Eso no crea
--   capa nueva — devuelve la cantidad a las capas que se consumieron, en orden
--   inverso, al costo al que salieron. Sin esto el costo se desviaría en cada
--   edición de orden, que aquí es una operación constante.
--
-- FALTANTES (existencia negativa):
--   Si no hay capas suficientes la salida se costea al último costo conocido y
--   la fila queda marcada is_shortfall. No se inventa una capa negativa: el
--   faltante queda visible en v_inventory_cost_shortfalls para reconciliarlo
--   contra el conteo físico. Son los 89 negativos del hallazgo 5.
--
-- LO QUE NO TOCA:
--   inventory_items.cost sigue en último precio. Es el costo de REPOSICIÓN que
--   usan compras, sugerencias de reorden y la valuación vieja. El costo
--   CONTABLE ahora vive en las capas y se lee por v_inventory_valuation_layers.
--   Las dos cifras conviven a propósito y su diferencia es partida de
--   conciliación, tal como pide el informe.
--
-- IDEMPOTENTE: add column / create table / create index if not exists,
-- create or replace function, drop policy + create policy.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Bandera por negocio
-- ---------------------------------------------------------------------------

alter table public.business_settings
  add column if not exists inventory_costing_method text not null
    default 'last_price';

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'business_settings_inventory_costing_method_check'
  ) then
    alter table public.business_settings
      add constraint business_settings_inventory_costing_method_check
      check (inventory_costing_method in
        ('last_price', 'average', 'fifo', 'lifo'));
  end if;
end $$;

comment on column public.business_settings.inventory_costing_method is
  'Método de costeo del inventario. last_price (default) = comportamiento '
  'heredado, sin capas. average/fifo/lifo encienden el motor de capas '
  '(inventory_cost_layers) para ese negocio. UEPS = lifo, Art. 303 del '
  'Código Tributario.';

-- ---------------------------------------------------------------------------
-- 2. Capas de costo
-- ---------------------------------------------------------------------------

create table if not exists public.inventory_cost_layers (
  id                 uuid primary key default gen_random_uuid(),
  -- Orden de llegada REAL. created_at/received_at usan now(), que es el
  -- timestamp de la TRANSACCIÓN: todas las líneas de una misma recepción
  -- comparten valor y dejarían a PEPS/UEPS sin orden determinista. seq
  -- desempata por orden de inserción.
  seq                bigint generated always as identity,
  business_id        uuid not null references public.businesses(id)
                       on delete cascade,
  item_id            uuid not null references public.inventory_items(id)
                       on delete cascade,
  warehouse_id       uuid not null references public.warehouses(id)
                       on delete restrict,
  source_movement_id uuid references public.inventory_movements(id)
                       on delete set null,
  source_type        text not null
                       check (source_type in (
                         'opening', 'purchase', 'transfer_in', 'return',
                         'production_in', 'adjustment'
                       )),
  supplier_id        uuid references public.suppliers(id) on delete set null,
  document_number    text,
  document_date      date,
  received_at        timestamptz not null default now(),
  quantity_in        numeric(14,4) not null check (quantity_in > 0),
  quantity_remaining numeric(14,4) not null check (quantity_remaining >= 0),
  unit_cost          numeric(14,4) not null check (unit_cost >= 0),
  is_estimated       boolean not null default false,
  notes              text,
  created_at         timestamptz not null default now()
);

comment on table public.inventory_cost_layers is
  'Capa de costo: una fila por cada ENTRADA de inventario, con su documento '
  '(NCF o factura), fecha y proveedor. quantity_remaining baja a medida que '
  'las salidas la consumen. Es la base de PEPS, UEPS y promedio.';

comment on column public.inventory_cost_layers.is_estimated is
  'true cuando la entrada llegó SIN costo y hubo que estimarla al último '
  'costo conocido. Marca la deuda documental: son las recepciones directas '
  'sin costo del hallazgo 3 del informe DH.';

create index if not exists idx_inv_cost_layers_open
  on public.inventory_cost_layers
     (business_id, item_id, warehouse_id, received_at, seq)
  where quantity_remaining > 0;

create index if not exists idx_inv_cost_layers_movement
  on public.inventory_cost_layers (source_movement_id);

create index if not exists idx_inv_cost_layers_business
  on public.inventory_cost_layers (business_id, created_at desc);

-- ---------------------------------------------------------------------------
-- 3. Consumos: qué capa pagó cada salida
-- ---------------------------------------------------------------------------

create table if not exists public.inventory_cost_consumptions (
  id                uuid primary key default gen_random_uuid(),
  seq               bigint generated always as identity,
  business_id       uuid not null references public.businesses(id)
                      on delete cascade,
  movement_id       uuid not null references public.inventory_movements(id)
                      on delete cascade,
  layer_id          uuid references public.inventory_cost_layers(id)
                      on delete set null,
  item_id           uuid not null,
  warehouse_id      uuid not null,
  quantity          numeric(14,4) not null check (quantity > 0),
  quantity_returned numeric(14,4) not null default 0
                      check (quantity_returned >= 0),
  unit_cost         numeric(14,4) not null check (unit_cost >= 0),
  extended_cost     numeric(16,4)
                      generated always as (quantity * unit_cost) stored,
  is_shortfall      boolean not null default false,
  created_at        timestamptz not null default now()
);

comment on table public.inventory_cost_consumptions is
  'Detalle del costo de cada salida: qué capa se consumió, cuánto y a qué '
  'costo. quantity_returned registra lo devuelto por edición o cancelación '
  'de orden. is_shortfall = salió sin capa disponible (existencia negativa).';

create index if not exists idx_inv_cost_cons_movement
  on public.inventory_cost_consumptions (movement_id);

create index if not exists idx_inv_cost_cons_open_returns
  on public.inventory_cost_consumptions
     (business_id, item_id, warehouse_id, seq desc)
  where quantity > quantity_returned;

-- ---------------------------------------------------------------------------
-- 4. RLS
-- ---------------------------------------------------------------------------

alter table public.inventory_cost_layers enable row level security;

drop policy if exists "icl_select" on public.inventory_cost_layers;
create policy "icl_select" on public.inventory_cost_layers
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

drop policy if exists "icl_write" on public.inventory_cost_layers;
create policy "icl_write" on public.inventory_cost_layers
  to authenticated
  using (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner','admin','manager'])
  )
  with check (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner','admin','manager'])
  );

alter table public.inventory_cost_consumptions enable row level security;

drop policy if exists "icc_select" on public.inventory_cost_consumptions;
create policy "icc_select" on public.inventory_cost_consumptions
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

drop policy if exists "icc_write" on public.inventory_cost_consumptions;
create policy "icc_write" on public.inventory_cost_consumptions
  to authenticated
  using (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner','admin','manager'])
  )
  with check (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner','admin','manager'])
  );

-- ---------------------------------------------------------------------------
-- 5. Último costo conocido (para entradas sin costo y para faltantes)
-- ---------------------------------------------------------------------------

create or replace function public.fn_inventory_last_known_cost(
  p_business_id uuid,
  p_item_id uuid,
  p_warehouse_id uuid
) returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    -- 1. La capa más reciente de esa bodega, aunque esté agotada.
    (select l.unit_cost
       from public.inventory_cost_layers l
      where l.business_id = p_business_id
        and l.item_id = p_item_id
        and l.warehouse_id = p_warehouse_id
        and l.unit_cost > 0
      order by l.received_at desc, l.seq desc
      limit 1),
    -- 2. La capa más reciente del negocio, en cualquier bodega.
    (select l.unit_cost
       from public.inventory_cost_layers l
      where l.business_id = p_business_id
        and l.item_id = p_item_id
        and l.unit_cost > 0
      order by l.received_at desc, l.seq desc
      limit 1),
    -- 3. El costo maestro (último precio de compra).
    (select ii.cost
       from public.inventory_items ii
      where ii.id = p_item_id
        and ii.business_id = p_business_id),
    0
  )::numeric;
$$;

comment on function public.fn_inventory_last_known_cost(uuid, uuid, uuid) is
  'Costo de respaldo cuando una entrada llega sin costo o una salida no '
  'encuentra capa. Cae en cascada: capa más reciente de la bodega, capa más '
  'reciente del negocio, costo maestro del insumo, 0.';

-- ---------------------------------------------------------------------------
-- 6. Motor de capas
-- ---------------------------------------------------------------------------

create or replace function public.fn_inventory_cost_layers_apply()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_method    text;
  v_type      text := new.movement_type::text;
  v_qty       numeric := new.quantity;
  v_need      numeric;
  v_take      numeric;
  v_total     numeric := 0;
  v_unit      numeric;
  v_pool_qty  numeric;
  v_pool_val  numeric;
  v_need0     numeric;
  v_avg       numeric;
  v_supplier  uuid;
  v_doc_num   text;
  v_doc_date  date;
  v_src       text;
  v_est       boolean := false;
  v_layer     record;
  v_cons      record;
begin
  if v_qty is null or v_qty = 0 then
    return new;
  end if;

  select coalesce(bs.inventory_costing_method, 'last_price')
    into v_method
    from public.business_settings bs
   where bs.business_id = new.business_id
   limit 1;

  -- Default y negocios sin fila de settings: motor apagado, cero cambios.
  if coalesce(v_method, 'last_price') = 'last_price' then
    return new;
  end if;

  -- =======================================================================
  -- CANTIDAD POSITIVA
  -- =======================================================================
  if v_qty > 0 then

    -- Un movimiento de SALIDA con cantidad positiva es una devolución:
    -- edición o cancelación de orden, retorno de transferencia, reverso de
    -- merma. Se devuelve a las capas de donde salió, no se crea capa nueva.
    if v_type in ('sale', 'transfer_out', 'waste', 'production_out') then
      v_need := v_qty;

      for v_cons in
        select c.id, c.layer_id, c.quantity, c.quantity_returned, c.unit_cost
          from public.inventory_cost_consumptions c
         where c.business_id  = new.business_id
           and c.item_id      = new.item_id
           and c.warehouse_id = new.warehouse_id
           and c.quantity > c.quantity_returned
         order by c.seq desc
      loop
        exit when v_need <= 0;

        v_take := least(v_need, v_cons.quantity - v_cons.quantity_returned);

        update public.inventory_cost_consumptions
           set quantity_returned = quantity_returned + v_take
         where id = v_cons.id;

        if v_cons.layer_id is not null then
          update public.inventory_cost_layers
             set quantity_remaining = quantity_remaining + v_take
           where id = v_cons.layer_id;
        end if;

        v_total := v_total + (v_take * v_cons.unit_cost);
        v_need  := v_need - v_take;
      end loop;

      -- Lo que no calza contra un consumo previo entra como capa nueva al
      -- último costo conocido, para no perder la cantidad.
      if v_need > 0 then
        v_unit := public.fn_inventory_last_known_cost(
                    new.business_id, new.item_id, new.warehouse_id);

        insert into public.inventory_cost_layers (
          business_id, item_id, warehouse_id, source_movement_id, source_type,
          received_at, quantity_in, quantity_remaining, unit_cost,
          is_estimated, notes
        ) values (
          new.business_id, new.item_id, new.warehouse_id, new.id, 'return',
          new.created_at, v_need, v_need, v_unit, true,
          'Devolución sin consumo previo que la respalde'
        );

        v_total := v_total + (v_need * v_unit);
      end if;

      if new.cost_per_unit is null then
        update public.inventory_movements
           set cost_per_unit = round(v_total / v_qty, 4)
         where id = new.id;
      end if;

      return new;
    end if;

    -- ---------------------------------------------------------------
    -- Entrada real: nueva capa con su documento.
    -- ---------------------------------------------------------------
    v_src := case v_type
               when 'purchase'      then 'purchase'
               when 'transfer_in'   then 'transfer_in'
               when 'return'        then 'return'
               when 'production_in' then 'production_in'
               else 'adjustment'
             end;

    if new.reference_type = 'purchase_reception_line' then
      select pr.supplier_id,
             nullif(pr.ncf, ''),
             coalesce(pr.document_date, pr.reception_date)
        into v_supplier, v_doc_num, v_doc_date
        from public.purchase_reception_lines prl
        join public.purchase_receptions pr on pr.id = prl.reception_id
       where prl.id = new.reference_id;

    elsif new.reference_type in ('purchase_order', 'purchase_order_item') then
      select po.supplier_id,
             coalesce(nullif(po.ncf, ''), nullif(po.invoice_number, '')),
             coalesce(po.received_date, po.created_at::date)
        into v_supplier, v_doc_num, v_doc_date
        from public.purchase_orders po
       where po.id = new.reference_id;

    elsif new.reference_type = 'direct_receipt' then
      select dr.supplier_id,
             nullif(dr.receipt_number, ''),
             dr.created_at::date
        into v_supplier, v_doc_num, v_doc_date
        from public.direct_receipts dr
       where dr.id = new.reference_id;
    end if;

    v_unit := new.cost_per_unit;
    if v_unit is null or v_unit <= 0 then
      v_unit := public.fn_inventory_last_known_cost(
                  new.business_id, new.item_id, new.warehouse_id);
      v_est  := true;
    end if;

    insert into public.inventory_cost_layers (
      business_id, item_id, warehouse_id, source_movement_id, source_type,
      supplier_id, document_number, document_date, received_at,
      quantity_in, quantity_remaining, unit_cost, is_estimated
    ) values (
      new.business_id, new.item_id, new.warehouse_id, new.id, v_src,
      v_supplier, v_doc_num, coalesce(v_doc_date, new.created_at::date),
      new.created_at, v_qty, v_qty, round(v_unit, 4), v_est
    );

    return new;
  end if;

  -- =======================================================================
  -- CANTIDAD NEGATIVA: salida, consume capas
  -- =======================================================================
  v_need := abs(v_qty);

  if v_method = 'average' then
    -- Promedio: se retira proporcionalmente de todas las capas abiertas, así
    -- el promedio del remanente no se mueve y el valor retirado es
    -- exactamente cantidad × promedio.
    select coalesce(sum(l.quantity_remaining), 0),
           coalesce(sum(l.quantity_remaining * l.unit_cost), 0)
      into v_pool_qty, v_pool_val
      from public.inventory_cost_layers l
     where l.business_id  = new.business_id
       and l.item_id      = new.item_id
       and l.warehouse_id = new.warehouse_id
       and l.quantity_remaining > 0;

    if v_pool_qty > 0 then
      v_avg := v_pool_val / v_pool_qty;

      -- La cuota de cada capa se calcula contra la cantidad ORIGINAL de la
      -- salida, no contra v_need, que va bajando dentro del ciclo. Con v_need
      -- la segunda capa recibía la mitad de lo que le tocaba y el resto se lo
      -- comía la primera en el repaso, moviendo el promedio del remanente.
      v_need0 := least(v_need, v_pool_qty);

      for v_layer in
        select l.id, l.quantity_remaining
          from public.inventory_cost_layers l
         where l.business_id  = new.business_id
           and l.item_id      = new.item_id
           and l.warehouse_id = new.warehouse_id
           and l.quantity_remaining > 0
         order by l.received_at asc, l.seq asc
      loop
        exit when v_need <= 0;

        -- Cuota proporcional de esta capa, topada por lo que le queda y por
        -- lo que falta (la última capa absorbe el redondeo).
        v_take := least(
          v_layer.quantity_remaining,
          v_need,
          round(v_need0 * v_layer.quantity_remaining / v_pool_qty, 4)
        );
        if v_take <= 0 then
          v_take := least(v_layer.quantity_remaining, v_need);
        end if;

        update public.inventory_cost_layers
           set quantity_remaining = quantity_remaining - v_take
         where id = v_layer.id;

        insert into public.inventory_cost_consumptions (
          business_id, movement_id, layer_id, item_id, warehouse_id,
          quantity, unit_cost
        ) values (
          new.business_id, new.id, v_layer.id, new.item_id, new.warehouse_id,
          v_take, round(v_avg, 4)
        );

        v_total := v_total + (v_take * v_avg);
        v_need  := v_need - v_take;
      end loop;

      -- Repaso: las cuotas proporcionales se redondean a 4 decimales, así
      -- que puede quedar polvo sin asignar. Se absorbe contra las capas que
      -- todavía tengan saldo, al mismo promedio. Sin esto, un residuo de
      -- 0.0001 se marcaría como faltante y ensuciaría el reporte de
      -- existencias negativas.
      if v_need > 0 then
        for v_layer in
          select l.id, l.quantity_remaining
            from public.inventory_cost_layers l
           where l.business_id  = new.business_id
             and l.item_id      = new.item_id
             and l.warehouse_id = new.warehouse_id
             and l.quantity_remaining > 0
           order by l.received_at asc, l.seq asc
        loop
          exit when v_need <= 0;

          v_take := least(v_layer.quantity_remaining, v_need);

          update public.inventory_cost_layers
             set quantity_remaining = quantity_remaining - v_take
           where id = v_layer.id;

          insert into public.inventory_cost_consumptions (
            business_id, movement_id, layer_id, item_id, warehouse_id,
            quantity, unit_cost
          ) values (
            new.business_id, new.id, v_layer.id, new.item_id,
            new.warehouse_id, v_take, round(v_avg, 4)
          );

          v_total := v_total + (v_take * v_avg);
          v_need  := v_need - v_take;
        end loop;
      end if;
    end if;

  else
    -- PEPS (fifo) y UEPS (lifo): capa por capa, en orden de recepción.
    for v_layer in
      select l.id, l.quantity_remaining, l.unit_cost
        from public.inventory_cost_layers l
       where l.business_id  = new.business_id
         and l.item_id      = new.item_id
         and l.warehouse_id = new.warehouse_id
         and l.quantity_remaining > 0
       order by
         case when v_method = 'lifo' then l.received_at end desc,
         case when v_method = 'lifo' then l.seq end desc,
         case when v_method = 'fifo' then l.received_at end asc,
         case when v_method = 'fifo' then l.seq end asc
    loop
      exit when v_need <= 0;

      v_take := least(v_layer.quantity_remaining, v_need);

      update public.inventory_cost_layers
         set quantity_remaining = quantity_remaining - v_take
       where id = v_layer.id;

      insert into public.inventory_cost_consumptions (
        business_id, movement_id, layer_id, item_id, warehouse_id,
        quantity, unit_cost
      ) values (
        new.business_id, new.id, v_layer.id, new.item_id, new.warehouse_id,
        v_take, v_layer.unit_cost
      );

      v_total := v_total + (v_take * v_layer.unit_cost);
      v_need  := v_need - v_take;
    end loop;
  end if;

  -- Faltante: salió más de lo que había en capas (existencia negativa).
  -- Se costea al último costo conocido y queda marcado para reconciliar.
  -- El umbral es medio dígito de numeric(14,4): por debajo de eso no hay
  -- negativo real, hay polvo de redondeo.
  if v_need > 0.00005 then
    v_unit := public.fn_inventory_last_known_cost(
                new.business_id, new.item_id, new.warehouse_id);

    insert into public.inventory_cost_consumptions (
      business_id, movement_id, layer_id, item_id, warehouse_id,
      quantity, unit_cost, is_shortfall
    ) values (
      new.business_id, new.id, null, new.item_id, new.warehouse_id,
      v_need, round(v_unit, 4), true
    );

    v_total := v_total + (v_need * v_unit);
  end if;

  -- El costo de venta, por fin, en el propio movimiento.
  if new.cost_per_unit is null then
    update public.inventory_movements
       set cost_per_unit = round(v_total / abs(v_qty), 4)
     where id = new.id;
  end if;

  return new;
end;
$$;

comment on function public.fn_inventory_cost_layers_apply() is
  'Motor de capas de costo. Entradas crean capa con su documento; salidas '
  'consumen capas por PEPS/UEPS/promedio, escriben el detalle en '
  'inventory_cost_consumptions y rellenan inventory_movements.cost_per_unit. '
  'No hace nada si el negocio está en last_price (default).';

-- El trigger corre ANTES que trg_inventory_movement_recost y
-- trg_inventory_stock_sync por orden alfabético del nombre, y no depende de
-- ninguno de los dos. Es after insert: el update que hace sobre la propia
-- fila NO lo vuelve a disparar.
drop trigger if exists trg_inventory_cost_layers on public.inventory_movements;
create trigger trg_inventory_cost_layers
  after insert on public.inventory_movements
  for each row
  execute function public.fn_inventory_cost_layers_apply();

comment on trigger trg_inventory_cost_layers on public.inventory_movements is
  'Mantiene las capas de costo y escribe el costo de cada salida. Inerte '
  'mientras business_settings.inventory_costing_method sea last_price.';

commit;

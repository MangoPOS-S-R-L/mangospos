-- =============================================================================
-- 20260919_0003 — Reporte de comandas: "canceling statement due to statement
--                  timeout" (57014)
-- =============================================================================
--
-- EL PROBLEMA:
--   La versión de 20260919_0001 con las notas de anulación hace, por CADA
--   producto del rango (anulado o no):
--     * una búsqueda en `fiscal_documents` por `order_id` (la nota de la
--       factura anulada), y
--     * una búsqueda en `payments` por `order_id` (la hora del cobro, que
--       solo usa el modo "cobrado sin comanda").
--   Ninguna de las dos columnas tiene índice en el repo: cada búsqueda
--   recorre la tabla completa. El ON del LEFT JOIN LATERAL no lo evita:
--   Postgres calcula el lateral para cada fila y DESPUÉS aplica el ON.
--   Medido en Postgres local: un día de 2,000 productos con 300,000
--   facturas/pagos = 39.7 s por página → el servidor corta la consulta.
--
-- QUÉ HACE:
--   Misma función, mismas columnas y mismo resultado (CREATE OR REPLACE, sin
--   DROP). Solo cambia CUÁNDO corren esas búsquedas:
--     * la nota de anulación, solo para lo anulado;
--     * la hora del cobro, solo en "cobrado sin comanda" y leída una sola
--       vez para todas las órdenes (no una vez por producto).
--   Medido después: 17 ms el día de 2,000 productos; "cobrado sin comanda"
--   con 800 productos, de 11.5 s a milisegundos.
--
-- NO toca datos. IDEMPOTENTE. ROLLBACK = volver a correr 20260919_0001.
-- =============================================================================

begin;

create or replace function public.fn_kitchen_comandas_report(
  p_business_id uuid,
  p_from        timestamptz default null,
  p_to          timestamptz default null,
  -- true = "AÚN SIN COBRAR": ignora el rango y trae lo enviado a cocina de
  -- las órdenes que siguen vivas AHORA (mesas abiertas y órdenes huérfanas),
  -- sin importar cuándo se enviaron.
  p_open_only   boolean     default false,
  -- true = "COBRADO SIN COMANDA": productos cobrados en órdenes con pago en
  -- el rango que NUNCA pasaron por cocina (sin marca, sin heredarla de una
  -- cuenta dividida y sin ser venta rápida). En este modo `kitchen_sent_at`
  -- trae la hora del COBRO (último pago) y `sent_source` = 'none'.
  p_without_comanda boolean default false
)
returns table (
  item_id          uuid,
  order_id         uuid,
  -- Hora del envío a cocina. Casi siempre la marca real; ver `sent_source`.
  kitchen_sent_at  timestamptz,
  item_created_at  timestamptz,
  product_id       uuid,
  product_name     text,
  quantity         numeric,
  notes            text,
  status           text,
  is_takeout       boolean,
  table_name       text,
  origin           text,
  -- Quien digitó el ítem (PIN del mesero). Es el "MESERO:" de la comanda
  -- impresa desde 2026-09-06.
  item_author      text,
  -- Quien abrió la mesa: respaldo cuando el ítem no tiene autor.
  opener_name      text,
  area_codes       text[],
  area_names       text[],
  -- [{"name": "...", "qty": 1}, ...]
  modifiers        jsonb,
  -- Comparador enviado vs. cobrado:
  unit_price       numeric,
  is_courtesy      boolean,
  order_status     text,
  order_closed_at  timestamptz,
  session_closed_at timestamptz,
  -- De dónde sale `kitchen_sent_at`:
  --   'stamp' → la marca del ítem.
  --   'split' → fila creada al dividir la cuenta: hereda la de su original.
  --   'quick' → venta rápida: la comanda se imprime al cobrar y no se marca.
  sent_source      text,
  -- Cobrado a 0: no hay nada que cobrar (precio 0 sin extras con precio, o
  -- unidad gratis de una promoción). Nunca cuenta como pendiente.
  is_zero_value    boolean,
  -- Nota de la anulación (solo en lo anulado), "Quién: motivo":
  --   1. Factura anulada (anular desde el historial): el motivo de ESA
  --      orden (fiscal_documents.cancellation_reason) y quién la anuló.
  --   2. Anular la orden desde la mesa: la línea
  --      "[ANULACION][fecha] usuario: motivo" de la nota de la MESA cuya
  --      hora queda más cerca de la anulación de ESTA orden (una mesa puede
  --      tener varias órdenes anuladas; tomar la última le pegaba a una la
  --      nota de otra).
  void_note        text,
  -- Cuándo se anuló (la hora de la factura anulada, la de la línea de la
  -- nota o, sin nota, el cierre de la orden anulada).
  void_at          timestamptz,
  -- 'factura' | 'mesa' | null (sin nota o solo el producto anulado).
  void_source      text
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_kitchen_on boolean;
begin
  if p_business_id is null then
    raise exception 'BUSINESS_ID_REQUIRED';
  end if;
  if coalesce(p_open_only, false) and coalesce(p_without_comanda, false) then
    raise exception 'INVALID_MODE';
  end if;
  if not coalesce(p_open_only, false)
     and (p_from is null or p_to is null or p_to <= p_from) then
    raise exception 'INVALID_RANGE';
  end if;
  if not (p_business_id in (select public.current_user_business_ids())) then
    raise exception 'UNAUTHORIZED_BUSINESS';
  end if;

  -- Con la cocina apagada no se imprimen comandas (ni la de venta rápida).
  select coalesce(bs.kitchen_enabled, true)
    into v_kitchen_on
  from public.business_settings bs
  where bs.business_id = p_business_id
  limit 1;
  v_kitchen_on := coalesce(v_kitchen_on, true);

  return query
  with candidate_orders as (
    -- Órdenes con algún envío marcado en el rango.
    select distinct oi.order_id
    from public.order_items oi
    join public.orders o on o.id = oi.order_id
    where not coalesce(p_open_only, false)
      and not coalesce(p_without_comanda, false)
      and o.business_id = p_business_id
      and o.created_at < p_to
      and oi.kitchen_sent_at >= p_from
      and oi.kitchen_sent_at <  p_to
    union
    -- Ventas rápidas cobradas en el rango: su comanda sale al cobrar, desde
    -- la pantalla, y NO marca kitchen_sent_at.
    select o.id
    from public.orders o
    join public.table_sessions ts on ts.id = o.session_id
    where not coalesce(p_open_only, false)
      and not coalesce(p_without_comanda, false)
      and v_kitchen_on
      and o.business_id = p_business_id
      and ts.origin::text in ('quick', 'quick_sale')
      and o.closed_at >= p_from
      and o.closed_at <  p_to
    union
    -- Modo "aún sin cobrar": las órdenes vivas ahora mismo, sin importar
    -- cuándo se enviaron. Incluye las huérfanas (orden viva con la mesa ya
    -- cerrada): nadie las va a cobrar desde el salón.
    select o.id
    from public.orders o
    where coalesce(p_open_only, false)
      and o.business_id = p_business_id
      and o.closed_at is null
      and o.status::text not in ('paid', 'canceled')
      and coalesce(o.status_ext::text, '') not in ('void', 'paid')
    union
    -- Modo "cobrado sin comanda": órdenes con pago completado en el rango
    -- (misma base que el reporte de Ventas: la fecha del pago).
    select p.order_id
    from public.payments p
    join public.orders o on o.id = p.order_id
    where coalesce(p_without_comanda, false)
      and o.business_id = p_business_id
      and p.created_at >= p_from
      and p.created_at <  p_to
      and (p.status = 'completed' or p.status is null)
  ),
  -- Hora del cobro (último pago completado) de cada orden: solo la usa
  -- "cobrado sin comanda". Se lee UNA vez para todas las órdenes
  -- (20260919_0003): antes era una consulta a payments por cada producto y,
  -- sin índice en payments.order_id, tumbaba el reporte (57014).
  paid as (
    select p.order_id, max(p.created_at) as paid_at
    from public.payments p
    where coalesce(p_without_comanda, false)
      and p.order_id in (select co.order_id from candidate_orders co)
      and (p.status = 'completed' or p.status is null)
    group by p.order_id
  ),
  items as (
    select
      oi.*,
      -- Estado normalizado: anular deja a veces `status` en 'open' con
      -- `status_ext` = 'void' (visto en prod, MUEBLE12 2026-09-18). El
      -- extendido manda: void → 'canceled', paid → 'paid'.
      case
        when o.status_ext::text = 'void' then 'canceled'
        when o.status_ext::text = 'paid' then 'paid'
        else o.status::text
      end             as o_status,
      o.closed_at     as o_closed_at,
      ts.closed_at    as ts_closed_at,
      ts.origin::text as ts_origin,
      ts.note         as ts_note,
      ts.table_id     as ts_table_id,
      ts.opened_by_employee_id as ts_opener_employee,
      ts.waiter_user_id        as ts_waiter_user,
      o.business_id   as o_business_id,
      pd.paid_at,
      sib.kitchen_sent_at        as sib_sent_at,
      sib.print_area_code        as sib_area_code,
      sib.created_by_employee_id as sib_author
    from candidate_orders co
    join public.order_items oi     on oi.order_id = co.order_id
    join public.orders o           on o.id = oi.order_id
    join public.table_sessions ts  on ts.id = o.session_id
    left join paid pd              on pd.order_id = oi.order_id
    -- Dividir la cuenta (fn_explode_items_to_units / fn_split_items_equally)
    -- deja la marca solo en la fila original y crea las demás sin ella, sin
    -- área y sin autor. Las copias conservan orden, producto y created_at
    -- del original: de ahí se hereda.
    left join lateral (
      select s.kitchen_sent_at, s.print_area_code, s.created_by_employee_id
      from public.order_items s
      where s.order_id = oi.order_id
        and s.kitchen_sent_at is not null
        and s.product_id is not distinct from oi.product_id
        and s.created_at = oi.created_at
      order by s.kitchen_sent_at
      limit 1
    ) sib on oi.kitchen_sent_at is null
    where oi.status::text <> 'draft'
  ),
  sent as (
    select
      i.*,
      case
        when i.kitchen_sent_at is not null then i.kitchen_sent_at
        when i.sib_sent_at is not null then i.sib_sent_at
        when i.ts_origin in ('quick', 'quick_sale')
             and i.status::text = 'paid' then i.o_closed_at
      end as eff_sent_at,
      case
        when i.kitchen_sent_at is not null then 'stamp'
        when i.sib_sent_at is not null then 'split'
        when i.ts_origin in ('quick', 'quick_sale')
             and i.status::text = 'paid' then 'quick'
      end as eff_source,
      case
        when i.kitchen_sent_at is null and i.sib_sent_at is not null
          then i.sib_area_code
        else i.print_area_code
      end as eff_area_code,
      coalesce(i.created_by_employee_id, i.sib_author) as eff_author
    from items i
  )
  select
    x.id,
    x.order_id,
    -- En "cobrado sin comanda" no hay envío: va la hora del cobro.
    case when coalesce(p_without_comanda, false) then x.paid_at
         else x.eff_sent_at end,
    x.created_at,
    x.product_id,
    x.product_name,
    -- Misma cantidad que el reporte de Ventas (get_sales_summary_v2): `qty`
    -- manda (fracciones, productos por peso); `quantity` es el respaldo.
    coalesce(nullif(x.qty, 0), x.quantity::numeric, 1::numeric),
    x.notes,
    x.status::text,
    coalesce(x.is_takeout, false),
    case
      when dt.id is not null then coalesce(dt.label, dt.code, 'Mesa')
      when x.ts_origin = 'manual' then 'Venta manual'
      when x.ts_origin in ('quick', 'quick_sale') then 'Venta rápida'
      else 'Venta'
    end,
    x.ts_origin,
    nullif(trim(concat_ws(' ', e.first_name, e.last_name)), ''),
    coalesce(
      nullif(trim(concat_ws(' ', oe.first_name, oe.last_name)), ''),
      nullif(trim(p.full_name), '')
    ),
    coalesce(nm.codes, legacy.codes, array[]::text[]),
    coalesce(nm.names, legacy.names, array[]::text[]),
    coalesce(mods.list, '[]'::jsonb),
    x.unit_price,
    -- Cortesía: la marca [CORTESIA:…] (solo se escribe si hubo motivo), o una
    -- línea con precio que quedó en cero por descuento. Las unidades gratis
    -- de promociones ([PROMO_AUTO:] con subtotal negativo, [DEAL:]) NO son
    -- cortesía: son parte de una oferta cobrada.
    (
      coalesce(x.notes, '') like '%[CORTESIA:%'
      or (
        coalesce(x.notes, '') not like '%[PROMO_AUTO:%'
        and coalesce(x.notes, '') not like '%[DEAL:%'
        and coalesce(x.unit_price, 0) > 0
        and (
          (
            coalesce(x.subtotal, 0) + coalesce(x.tax, 0) > 0
            and coalesce(x.discounts, 0)
                >= coalesce(x.subtotal, 0) + coalesce(x.tax, 0) - 0.01
          )
          or coalesce(x.total, 1) <= 0.01
        )
      )
    ),
    x.o_status,
    x.o_closed_at,
    x.ts_closed_at,
    case when coalesce(p_without_comanda, false) then 'none'
         else x.eff_source end,
    -- Cobrado a 0 (la cortesía tiene su propia marca y va primero en la app).
    (
      (coalesce(x.unit_price, 0) <= 0 and not coalesce(mods.has_price, false))
      or (
        coalesce(x.unit_price, 0)
          * coalesce(nullif(x.qty, 0), x.quantity::numeric, 1) > 0
        and coalesce(x.discounts, 0)
            >= coalesce(x.unit_price, 0)
               * coalesce(nullif(x.qty, 0), x.quantity::numeric, 1) - 0.01
      )
    ),
    vn.note,
    case
      when x.status::text = 'void' or x.o_status = 'canceled'
        then coalesce(vn.at, case when x.o_status = 'canceled'
                                  then x.o_closed_at end)
    end,
    vn.source
  from sent x
  left join public.dining_tables dt on dt.id = x.ts_table_id
  left join public.employees e      on e.id = x.eff_author
  left join public.employees oe     on oe.id = x.ts_opener_employee
  left join public.profiles p       on p.id = x.ts_waiter_user
  left join lateral (
    select
      array_agg(pa.code order by pa.name, pa.code) as codes,
      array_agg(pa.name order by pa.name, pa.code) as names
    from public.menu_item_print_areas mipa
    join public.print_areas pa on pa.id = mipa.print_area_id
    where mipa.menu_item_id = x.product_id
      and pa.is_active
      and pa.business_id = x.o_business_id
  ) nm on true
  left join lateral (
    select array[pa.code] as codes, array[pa.name] as names
    from public.print_areas pa
    where pa.code = x.eff_area_code
      and pa.business_id = x.o_business_id
      and pa.is_active
    limit 1
  ) legacy on nm.codes is null
  left join lateral (
    select jsonb_agg(
             jsonb_build_object('name', m.name, 'qty', coalesce(m.qty, 1))
             order by m.name
           ) as list,
           bool_or(coalesce(m.price, 0) > 0) as has_price
    from public.order_item_modifiers m
    where m.item_id = x.id
  ) mods on true
  -- Nota de la anulación: solo para lo anulado (ver void_note arriba).
  left join lateral (
    select c.note, c.at, c.source
    from (
      -- 1. Factura anulada: específica de la orden.
      select
        concat_ws(': ', nullif(trim(pf.full_name), ''),
                  nullif(trim(fd.cancellation_reason), '')) as note,
        fd.cancelled_at                                    as at,
        'factura'::text                                    as source,
        1                                                  as prio,
        0::numeric                                         as dist,
        0::bigint                                          as n
      from public.fiscal_documents fd
      left join public.profiles pf on pf.id = fd.cancelled_by
      -- Solo lo anulado (20260919_0003): el ON del join no evita que el
      -- lateral corra para cada producto, y sin índice en
      -- fiscal_documents.order_id cada vuelta recorría la tabla entera.
      where (x.status::text = 'void' or x.o_status = 'canceled')
        and fd.order_id = x.order_id
        and nullif(trim(fd.cancellation_reason), '') is not null
      union all
      -- 2. Nota de la mesa: la línea más cercana a la anulación de esta
      --    orden. La fecha de la línea es hora de pared del dispositivo
      --    (RD); si no se puede leer, cuenta como la más lejana.
      select
        nullif(trim(regexp_replace(
          l.linea, '^\s*\[ANULACION\](\[[^]]*\])?\s*', '')), ''),
        l.at,
        'mesa'::text,
        2,
        coalesce(abs(extract(epoch from (l.at - x.o_closed_at))), 1e12),
        l.n
      from (
        select
          t.linea,
          t.n,
          case
            when t.linea ~ '^\s*\[ANULACION\]\[\d{4}-\d{2}-\d{2}T\d{2}:\d{2}'
              then (replace(substring(trim(t.linea) from 13 for 16), 'T', ' ')
                    || ':00')::timestamp at time zone 'America/Santo_Domingo'
          end as at
        from regexp_split_to_table(coalesce(x.ts_note, ''), E'\n')
               with ordinality as t(linea, n)
        where (x.status::text = 'void' or x.o_status = 'canceled')
          and trim(t.linea) like '[ANULACION]%'
      ) l
    ) c
    where c.note is not null
    -- Empate (p. ej. líneas sin fecha legible): la más reciente de la nota.
    order by c.prio, c.dist, c.n desc
    limit 1
  ) vn on (x.status::text = 'void' or x.o_status = 'canceled')
  where (
      not coalesce(p_open_only, false)
      and not coalesce(p_without_comanda, false)
      and x.eff_sent_at >= p_from
      and x.eff_sent_at <  p_to
    )
    or (
      -- Cobrado sin comanda: se cobró y nunca pasó por cocina.
      coalesce(p_without_comanda, false)
      and x.eff_sent_at is null
      and x.status::text = 'paid'
    )
    or (
      -- Aún sin cobrar: salió a cocina y no está cobrado ni anulado.
      coalesce(p_open_only, false)
      and x.eff_sent_at is not null
      and x.status::text not in ('paid', 'void')
    )
  order by x.eff_sent_at, x.id;
end;
$$;

notify pgrst, 'reload schema';

commit;

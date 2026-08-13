-- ============================================================================
-- Vincular impuesto 10% a los 49 productos
-- Business 6da31542-72e1-4f55-bc28-9837da98a119
-- Complemento de seed_business_6da31542_menu.sql (correr DESPUÉS)
-- ============================================================================
--
-- OBJETIVO: elegir uno de los impuestos YA existentes del negocio (el 10%)
--   y vincularlo a los 49 productos vía `menu_item_taxes`. NO se crea ningún
--   impuesto nuevo y NO se toca el 18%.
--
-- POR QUÉ menu_item_taxes: en MangoPOS es la ÚNICA fuente del impuesto por
--   producto (PRD 2.5 quitó el fallback a una tasa global). Sin vínculo, el
--   producto se cobra con impuesto 0.
--
-- ┌────────────────────────────────────────────────────────────────────────┐
-- │ 🚫 REGLA FIJA: `taxes.is_service_fee` NUNCA se activa. Queda en FALSE   │
-- │    en todos los impuestos, incluida la Propina. Si se pone en true el   │
-- │    sistema FACTURA DOBLE: el servidor (PRD 2.5) lo incluye dentro del   │
-- │    oi.tax_rate consolidado, y el cliente (tax_engine.dart:171-183) lo   │
-- │    excluye de effectiveTaxPct y lo vuelve a sumar como cargo aparte.    │
-- │    10% + 10% = 20%. No depende de service_fee_enabled. NO TOCAR.        │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- ┌────────────────────────────────────────────────────────────────────────┐
-- │ ⚠  RIESGO DE COBRO DOBLE — LEER ANTES DE CORRER                        │
-- ├────────────────────────────────────────────────────────────────────────┤
-- │ Hoy conviven DOS caminos de cálculo para la propina:                   │
-- │                                                                        │
-- │  A) POR PRODUCTO — fn_resolve_order_item_tax_profile /                 │
-- │     fn_populate_item_tax_lines (PRD 2.5, mig 20260430_0001).           │
-- │     Suma TODO lo vinculado en menu_item_taxes, incluidos los           │
-- │     impuestos con is_service_fee = true. Va a oi.tax + oi.tax_lines.   │
-- │     ← Es el camino que activa ESTE script.                             │
-- │                                                                        │
-- │  B) POR ORDEN — calculate_order_totals (mig 20260509_0008, y de nuevo  │
-- │     20260625_0001). Calcula service_fee sobre el subtotal completo,    │
-- │     gobernado por business_settings.service_fee_enabled.               │
-- │                                                                        │
-- │ PRD 2.5 había dejado B en 0, pero las migraciones posteriores lo       │
-- │ restauraron. Los dos caminos están vivos.                              │
-- │                                                                        │
-- │ ⇒ NO ENCIENDAS `service_fee_enabled` si corres este script.            │
-- │   El 10% se cobraría DOS veces. Y ojo: pasa igual tenga el impuesto    │
-- │   is_service_fee en true o en false —                                  │
-- │     · is_service_fee = true  → B suma la tasa real del impuesto        │
-- │     · is_service_fee = false → B cae al fallback legacy y usa          │
-- │       business_settings.service_fee_rate (default 10)                  │
-- │   En ambos casos: 10% por producto + 10% por orden.                    │
-- │                                                                        │
-- │ El PASO 2 aborta solo si detecta el switch encendido.                  │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- Correr los pasos EN ORDEN en Supabase Studio (SQL Editor).
-- ============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- PASO 1 — ¿Qué impuestos tiene el negocio? (solo lectura)
--   Mira la columna `rate` para ubicar el 10%, y copia su `name` exacto
--   al PASO 2. `t.*` trae todas las columnas, así no falla si la BD viva
--   tiene columnas que el repo no refleja.
-- ════════════════════════════════════════════════════════════════════════════

select
  t.*,
  (select count(*)
     from public.menu_item_taxes mit
     join public.menu_items mi on mi.id = mit.item_id
    where mit.tax_id = t.id
      and mi.business_id = t.business_id
      and mi.is_active)                    as productos_vinculados
from public.taxes t
where t.business_id = '6da31542-72e1-4f55-bc28-9837da98a119'::uuid
order by t.rate, t.name;

-- Estado del master switch (debe quedar en FALSE — ver aviso de arriba)
select
  bs.service_fee_enabled,
  bs.service_fee_rate
from public.business_settings bs
where bs.business_id = '6da31542-72e1-4f55-bc28-9837da98a119'::uuid;


-- ════════════════════════════════════════════════════════════════════════════
-- PASO 2 — Vincular. Pon el nombre EXACTO del impuesto de 10% en v_tax_name
--   (única línea que tienes que editar) y corre este bloque.
-- ════════════════════════════════════════════════════════════════════════════

do $$
declare
  -- ▼▼▼ Impuesto a vincular. Confirmado en el PASO 1 del 2026-08-09:
  --     "Propina" · 10.0% · activo · is_service_fee=false
  --     apply_on: zona ✓ manual ✓ | quick ✗ delivery ✗ takeout ✗
  v_tax_name text := 'Propina';
  -- ▲▲▲

  v_business  uuid := '6da31542-72e1-4f55-bc28-9837da98a119';
  v_tax_id    uuid;
  v_tax_rate  numeric;
  v_sf_on     boolean;
  v_matches   int;
  v_linked    int;
  v_exclusive int;
begin
  -- Guarda 1: el impuesto debe existir, estar activo y ser único por nombre.
  select count(*) into v_matches
  from public.taxes
  where business_id = v_business and name = v_tax_name;

  if v_matches = 0 then
    raise exception
      'No existe un impuesto llamado "%" en este negocio. Corre el PASO 1 y '
      'copia el `name` exacto (distingue mayúsculas y espacios).', v_tax_name;
  elsif v_matches > 1 then
    raise exception
      'Hay % impuestos llamados "%" en este negocio. Desambigua por id antes '
      'de continuar.', v_matches, v_tax_name;
  end if;

  select id, rate into v_tax_id, v_tax_rate
  from public.taxes
  where business_id = v_business and name = v_tax_name;

  if not exists (select 1 from public.taxes
                 where id = v_tax_id and coalesce(is_active, true)) then
    raise exception
      'El impuesto "%" existe pero está INACTIVO. Actívalo en Ajustes → '
      'Impuestos antes de vincularlo, o no cobrará nada.', v_tax_name;
  end if;

  -- Guarda 2: cobro doble. Si el master switch está encendido, abortar.
  select coalesce(service_fee_enabled, false) into v_sf_on
  from public.business_settings
  where business_id = v_business;

  if coalesce(v_sf_on, false) then
    raise exception
      'ABORTADO: business_settings.service_fee_enabled está en TRUE. Vincular '
      '"%" (% %%) por producto con ese switch encendido cobra la propina DOS '
      'veces (una por item vía menu_item_taxes, otra por orden vía '
      'calculate_order_totals). Apágalo en Ajustes y vuelve a correr.',
      v_tax_name, v_tax_rate;
  end if;

  -- 1) Todos los productos en modo EXCLUSIVO (pedido explícito del dueño).
  --    Ya vienen así del seed; esto lo deja garantizado e idempotente.
  update public.menu_items
  set tax_mode = 'exclusive'
  where business_id = v_business
    and tax_mode is distinct from 'exclusive';

  -- 2) Vincular el impuesto a todos los productos activos que no lo tengan.
  insert into public.menu_item_taxes (item_id, tax_id)
  select mi.id, v_tax_id
  from public.menu_items mi
  where mi.business_id = v_business
    and mi.is_active
    and not exists (
      select 1 from public.menu_item_taxes x
      where x.item_id = mi.id and x.tax_id = v_tax_id
    );

  get diagnostics v_linked = row_count;

  select count(*) into v_exclusive
  from public.menu_items
  where business_id = v_business and is_active and tax_mode = 'exclusive';

  raise notice 'OK — impuesto "%" (% %%) vinculado a % productos nuevos. '
               'Productos exclusivos: %.',
               v_tax_name, v_tax_rate, v_linked, v_exclusive;
end $$;


-- ════════════════════════════════════════════════════════════════════════════
-- PASO 3 — Verificación
-- ════════════════════════════════════════════════════════════════════════════

-- A) Cobertura por categoría — `con_impuesto` debe igualar `productos`
--    en las 9 categorías, y `tasas` mostrar solo el 10.
select
  c.position,
  c.name                                              as categoria,
  count(*)                                            as productos,
  count(mit.tax_id)                                   as con_impuesto,
  coalesce(string_agg(distinct t.rate::text, '+'), '—') as tasas
from public.menu_items mi
join public.categories c            on c.id = mi.category_id
left join public.menu_item_taxes mit on mit.item_id = mi.id
left join public.taxes t             on t.id = mit.tax_id
where mi.business_id = '6da31542-72e1-4f55-bc28-9837da98a119'::uuid
  and mi.is_active
group by c.position, c.name
order by c.position;

-- B) RED FLAGS — las tres deben dar 0 filas.
--    b1: productos activos sin ningún impuesto vinculado (se cobrarían en 0)
select mi.name
from public.menu_items mi
where mi.business_id = '6da31542-72e1-4f55-bc28-9837da98a119'::uuid
  and mi.is_active
  and not exists (
    select 1 from public.menu_item_taxes x where x.item_id = mi.id
  );

--    b2: algún producto quedó en modo inclusivo
select mi.name, mi.tax_mode
from public.menu_items mi
where mi.business_id = '6da31542-72e1-4f55-bc28-9837da98a119'::uuid
  and mi.is_active
  and mi.tax_mode <> 'exclusive';

--    b3: se coló el 18% (este script NO debe haberlo vinculado)
select mi.name, t.name as impuesto, t.rate
from public.menu_items mi
join public.menu_item_taxes mit on mit.item_id = mi.id
join public.taxes t             on t.id = mit.tax_id
where mi.business_id = '6da31542-72e1-4f55-bc28-9837da98a119'::uuid
  and mi.is_active
  and t.rate <> 10;

-- C) Simulación de cobro — una pizza de 850 debe dar 850 + 85 = 935
select
  mi.name,
  mi.price                                    as precio,
  mi.tax_mode,
  sum(t.rate)                                 as tasa_total,
  round(mi.price * sum(t.rate) / 100.0, 2)    as impuesto,
  round(mi.price * (1 + sum(t.rate) / 100.0), 2) as total_a_cobrar
from public.menu_items mi
join public.menu_item_taxes mit on mit.item_id = mi.id
join public.taxes t             on t.id = mit.tax_id and t.is_active
where mi.business_id = '6da31542-72e1-4f55-bc28-9837da98a119'::uuid
  and mi.sku in ('PZE-003', 'CRV-001', 'BEB-005')
group by mi.name, mi.price, mi.tax_mode
order by mi.price desc;


-- ============================================================================
-- ROLLBACK (si te arrepientes) — desvincula SOLO ese impuesto de este negocio.
-- ============================================================================
-- delete from public.menu_item_taxes mit
-- using public.taxes t, public.menu_items mi
-- where mit.tax_id = t.id
--   and mit.item_id = mi.id
--   and t.business_id = '6da31542-72e1-4f55-bc28-9837da98a119'::uuid
--   and mi.business_id = t.business_id
--   and t.name = 'Propina';   -- ← mismo nombre que usaste en el PASO 2
-- ============================================================================

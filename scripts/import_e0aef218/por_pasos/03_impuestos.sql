-- ============================================================================
-- Import de catálogo — BARRA PAYÁN
-- Business e0aef218-ab95-4ba4-b8ef-036fab1c07c7
-- ============================================================================
--
-- PASO 3 — Vincular el ITBIS 18% a los 54 productos.
--
-- POR QUÉ ES OBLIGATORIO: `menu_item_taxes` es la ÚNICA fuente del impuesto
--   por producto. El PRD 2.5 eliminó el fallback a
--   business_settings.default_tax_rate. Un producto sin fila aquí sale en la
--   factura con ITBIS 0.00 ante la DGII, aunque el impuesto exista y esté
--   activo en el negocio. Sin este paso el catálogo está fiscalmente roto.
--
-- COMO LOS PRECIOS SON 'inclusive', vincular el ITBIS no sube el precio:
--   lo desglosa hacia adentro. El cliente sigue pagando los $450 del menú.
--
-- LEY 10%: NO se vincula. Este negocio no la cobra (decisión del dueño,
--   2026-09-07). Si algún día la cobran, es este mismo script cambiando
--   v_tax_name — pero OJO, entonces habría que decidir si el 10% va incluido
--   en el precio del menú o se suma aparte.
--
-- ┌──────────────────────────────────────────────────────────────────────────┐
-- │ 🚫 NO enciendas `taxes.is_service_fee`. El servidor lo mete dentro del    │
-- │    oi.tax consolidado Y el cliente lo vuelve a sumar aparte: la factura   │
-- │    cobra el impuesto dos veces. Regla fija del dueño, no se toca.         │
-- │ 🚫 NO enciendas `business_settings.service_fee_enabled`: cobraría un 10%  │
-- │    por orden que el menú de Barra Payán no anuncia.                       │
-- └──────────────────────────────────────────────────────────────────────────┘
--
-- ALCANCE: todos los productos activos del negocio, no solo los del import,
--   para no depender del staging (que se borra en el paso 6).
--
-- IDEMPOTENTE: re-ejecutar no duplica vínculos.
-- Requiere el PASO 2.
-- ============================================================================

begin;

do $$
declare
  -- ▼▼▼ EDITA SI EL NOMBRE EXACTO DIFIERE. Sácalo del 00_diagnostico.sql,
  --     consulta 2 (distingue mayúsculas y espacios).
  v_tax_name text := 'ITBIS';
  -- ▲▲▲

  v_business uuid := 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7';
  v_tax_id   uuid;
  v_tax_rate numeric;
  v_matches  int;
  v_linked   int;
  v_items    int;
begin
  -- Guarda 1: el impuesto existe y es único por nombre.
  select count(*) into v_matches
  from public.taxes where business_id = v_business and name = v_tax_name;

  if v_matches = 0 then
    raise exception
      'No existe un impuesto llamado "%" en este negocio. Créalo en '
      'Ajustes → Impuestos (18%%, activo) o corrige v_tax_name arriba.',
      v_tax_name;
  elsif v_matches > 1 then
    raise exception
      'Hay % impuestos llamados "%". Desambigua por id antes de continuar.',
      v_matches, v_tax_name;
  end if;

  select id, rate into v_tax_id, v_tax_rate
  from public.taxes where business_id = v_business and name = v_tax_name;

  -- Guarda 2: activo. Un impuesto inactivo no cobra nada y además baja la
  -- tasa efectiva de los productos inclusive sin avisar.
  if not exists (select 1 from public.taxes
                 where id = v_tax_id and coalesce(is_active, true)) then
    raise exception
      'El impuesto "%" existe pero está INACTIVO: facturaría 0. Actívalo en '
      'Ajustes → Impuestos y vuelve a correr.', v_tax_name;
  end if;

  -- Guarda 3: la tasa es la esperada.
  if v_tax_rate <> 18 then
    raise exception
      'El impuesto "%" tiene tasa % (se esperaba 18). Si la tasa es correcta '
      'quita esta guarda a propósito; si no, corrígela antes de vincular los '
      '54 productos.', v_tax_name, v_tax_rate;
  end if;

  -- Guarda 4: is_service_fee apagado.
  if exists (select 1 from public.taxes
             where id = v_tax_id and coalesce(is_service_fee, false)) then
    raise exception
      'El impuesto "%" tiene is_service_fee = true. Así la factura lo cobra '
      'DOS veces (servidor consolidado + cliente aparte). Apágalo primero.',
      v_tax_name;
  end if;

  -- Vincular
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

  select count(*) into v_items
  from public.menu_items where business_id = v_business and is_active;

  raise notice 'ITBIS vinculado: % productos nuevos (activos en total: %)',
    v_linked, v_items;
end $$;

commit;

-- ============================================================================
-- VERIFICACIÓN
-- ============================================================================

-- Esperado: 54 productos con ITBIS.
select t.name as impuesto, t.rate, count(mit.item_id) as productos
from public.taxes t
left join public.menu_item_taxes mit on mit.tax_id = t.id
left join public.menu_items mi
  on mi.id = mit.item_id and mi.is_active
where t.business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid
group by t.name, t.rate
order by t.name;

-- 🚩 DEBE DAR 0 FILAS. Cualquier producto aquí factura ITBIS 0 ante la DGII.
select mi.name, mi.price
from public.menu_items mi
where mi.business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid
  and mi.is_active
  and not exists (
    select 1 from public.menu_item_taxes x where x.item_id = mi.id
  )
order by mi.name;

-- Desglose de control: qué se declara y qué se cobra.
-- Con 'inclusive' + ITBIS 18%, el Club Sándwich de $450 debe dar
-- base 381.36 · itbis 68.64 · total 450.00
select mi.name, mi.price as total_al_cliente,
       round(mi.price / 1.18, 2) as base_gravada,
       round(mi.price - (mi.price / 1.18), 2) as itbis
from public.menu_items mi
where mi.business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid
  and mi.is_active
order by mi.price desc
limit 5;

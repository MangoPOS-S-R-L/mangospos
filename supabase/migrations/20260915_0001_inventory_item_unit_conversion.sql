-- =============================================================================
-- Equivalencia propia del insumo — «1 unidad = 200 g»
--
-- CONTEXTO:
--   La conversión entre unidades de la MISMA clase ya la resuelve la app
--   (1 lb = 453.59 g, 1 gal = 3785.41 mL). Lo que no puede saber sola es
--   cuánto pesa UN aguacate, cuántos tomates trae una libra o cuánto pesa un
--   mililitro de miel. Es la «custom conversion» / densidad de Toast.
--
--   Sin eso, una receta escrita en gramos no puede descontar de un insumo que
--   se cuenta por unidad. En La Penda, 48 de los 82 insumos que usan las
--   fichas técnicas están en «unidad» y las fichas los piden en g o mL.
--
-- ENTREGA (ADITIVO — ninguna columna existente cambia):
--   inventory_items.conversion_unit    la unidad del otro lado (g, oz, mL, unidad…)
--   inventory_items.conversion_factor  cuánto de esa unidad hay en 1 unidad base
--   Se leen juntas: 1 [unit] = conversion_factor [conversion_unit].
--     unidad → 200 g      (un aguacate)
--     lb     → 2.5 unidad (tomates por libra)
--     ml     → 0.92 g     (densidad)
--
-- EL MOTOR NO CAMBIA: consume_inventory_from_order sigue leyendo
-- recipe_ingredients.quantity en la unidad base del insumo. La conversión la
-- hace la app al GUARDAR la receta, igual que la del empaque (20260608_0002).
--
-- La app funciona con y sin esta migración: si las columnas no existen, lee
-- los insumos sin ellas y no ofrece la equivalencia al guardar.
--
-- NEGOCIOS SIN INSUMOS: no se enteran. La migración NO escribe ninguna fila
-- (las columnas nacen en NULL, sin default), así que ningún negocio ve cambiar
-- sus datos, y el que no tiene insumos no tiene filas que tocar. Lo único que
-- comparten todos es el bloqueo de la tabla, y ese va con tope (abajo).
--
-- Antes y después: `supabase/VERIFICAR_20260915_0001_conversion.sql`.
--
-- IDEMPOTENTE: sí. REVERSIBLE: sí (ver _ROLLBACK).
-- =============================================================================

begin;

-- ALTER TABLE pide un bloqueo EXCLUSIVO de inventory_items. Si una transacción
-- larga lo tiene tomado, sin tope la migración se queda esperando y detrás de
-- ella se encolan las lecturas de insumos de TODOS los negocios. Con el tope,
-- si no consigue el bloqueo en 5 s aborta limpio —no aplica nada— y se vuelve
-- a correr en un momento más tranquilo.
set local lock_timeout = '5s';
set local statement_timeout = '60s';

alter table public.inventory_items
  add column if not exists conversion_unit text;

alter table public.inventory_items
  add column if not exists conversion_factor numeric;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.inventory_items'::regclass
       and conname  = 'inventory_items_conversion_factor_check'
  ) then
    alter table public.inventory_items
      add constraint inventory_items_conversion_factor_check
      check (conversion_factor is null or conversion_factor > 0);
  end if;

  -- Las dos o ninguna: una unidad sin factor (o un factor sin unidad) no
  -- dice nada, y la app no tendría con qué convertir.
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.inventory_items'::regclass
       and conname  = 'inventory_items_conversion_pair_check'
  ) then
    alter table public.inventory_items
      add constraint inventory_items_conversion_pair_check
      check ((conversion_unit is null) = (conversion_factor is null));
  end if;
end $$;

comment on column public.inventory_items.conversion_unit is
  'Equivalencia propia del insumo: 1 [unit] = conversion_factor [conversion_unit]. '
  'Ej: unit = unidad, 200 g (un aguacate). NULL = sin equivalencia.';

comment on column public.inventory_items.conversion_factor is
  'Cuánto de conversion_unit hay en 1 unidad base. Mayor que 0; NULL junto '
  'con conversion_unit.';

commit;

-- PostgREST: refrescar el caché de esquema para que la app vea las columnas
-- sin reiniciar el servicio.
notify pgrst, 'reload schema';

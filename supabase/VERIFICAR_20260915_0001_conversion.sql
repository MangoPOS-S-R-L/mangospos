-- =============================================================================
-- VERIFICAR 20260915_0001_inventory_item_unit_conversion — SOLO LECTURA
--
-- Nada de esto escribe. Correr el bloque 0 ANTES de aplicar la migración y los
-- bloques 1 a 4 DESPUÉS.
-- =============================================================================

-- 0) ANTES: transacciones abiertas hace más de 30 s. Si alguna aparece, la
--    migración puede no conseguir el bloqueo (aborta a los 5 s sin aplicar
--    nada): esperar a que termine y volver a correrla.
select pid,
       usename,
       state,
       now() - xact_start as antiguedad,
       left(query, 120)   as consulta
  from pg_stat_activity
 where xact_start is not null
   and now() - xact_start > interval '30 seconds'
   and pid <> pg_backend_pid()
 order by antiguedad desc;

-- 1) Las dos columnas existen y aceptan NULL.
select column_name, data_type, is_nullable
  from information_schema.columns
 where table_schema = 'public'
   and table_name   = 'inventory_items'
   and column_name in ('conversion_unit', 'conversion_factor')
 order by column_name;

-- 2) Los dos checks existen y están validados.
select conname, convalidated, pg_get_constraintdef(oid) as definicion
  from pg_constraint
 where conrelid = 'public.inventory_items'::regclass
   and conname like 'inventory_items_conversion_%'
 order by conname;

-- 3) La migración no escribió ninguna equivalencia: tiene que dar 0 hasta que
--    se carguen a propósito, negocio por negocio.
select count(*) as insumos_con_equivalencia
  from public.inventory_items
 where conversion_unit is not null
    or conversion_factor is not null;

-- 4) Cuántos negocios tienen insumos y cuántos no. Los que no, no tienen filas
--    en inventory_items: la migración no les tocó nada.
select count(*)                                          as negocios,
       count(*) filter (where exists (
         select 1 from public.inventory_items ii
          where ii.business_id = b.id))                  as con_insumos,
       count(*) filter (where not exists (
         select 1 from public.inventory_items ii
          where ii.business_id = b.id))                  as sin_insumos
  from public.businesses b;

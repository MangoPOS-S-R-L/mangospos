-- =============================================================================
-- Inventario PRD: nuevos movement_type para producción.
--
-- CONCEPTO:
--   Las órdenes de producción consumen materias primas y producen un
--   producto terminado. Necesitan ENUMs propios en `movement_type` para
--   que el Kardex distinga "consumo por producción" de un "ajuste manual",
--   y "ingreso por producción" de una "compra".
--
-- ENTREGA:
--   Agrega valores 'production_in' y 'production_out' al ENUM
--   `public.movement_type`.
--
-- NOTAS IMPORTANTES:
--   - `ALTER TYPE ... ADD VALUE` no puede correr dentro de un bloque
--     `begin/commit` en Postgres. Esta migration NO tiene wrapper.
--   - `ADD VALUE IF NOT EXISTS` para idempotencia.
-- =============================================================================

alter type public.movement_type add value if not exists 'production_in';
alter type public.movement_type add value if not exists 'production_out';

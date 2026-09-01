-- ROLLBACK de 20260901_0001_warehouse_sections.sql
--
-- Seguro de correr: ninguna función de negocio lee estas columnas todavía
-- (F0 es solo captura de datos). Se pierde lo capturado — tipo, área y
-- responsable de cada almacén — pero no hay stock ni movimientos atados.

begin;

drop index if exists public.uq_warehouses_waste;
drop index if exists public.uq_warehouses_production_area;
drop index if exists public.idx_warehouses_keeper;

alter table public.warehouses
  drop constraint if exists warehouses_production_area_fkey;
alter table public.warehouses
  drop constraint if exists warehouses_keeper_employee_fkey;
alter table public.warehouses
  drop constraint if exists warehouses_type_check;

alter table public.warehouses drop column if exists requires_requisition;
alter table public.warehouses drop column if exists keeper_employee_id;
alter table public.warehouses drop column if exists production_area_id;
alter table public.warehouses drop column if exists warehouse_type;

alter table public.business_settings
  drop column if exists warehouse_sections_enabled;

commit;

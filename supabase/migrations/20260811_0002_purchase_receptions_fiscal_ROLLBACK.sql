-- Rollback de 20260811_0002_purchase_receptions_fiscal.sql
-- Elimina las tablas de recepción y el índice del ledger. ATENCIÓN: si ya
-- existen recepciones reales, esto borra su historial fiscal — verificar
-- `select count(*) from purchase_receptions` antes de correr.

begin;

drop index if exists public.uq_inventory_movements_reception_line;

drop table if exists public.purchase_reception_lines;
drop table if exists public.purchase_receptions;

commit;

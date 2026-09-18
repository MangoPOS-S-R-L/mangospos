-- =============================================================================
-- ROLLBACK 20260917_0007 — Abono (saldo prepagado) por mesa
-- =============================================================================
--
-- OJO: esto BORRA los saldos y su historial. Si ya hay mesas con saldo
-- pendiente, el cliente pagó ese dinero y no lo ha consumido — exportá el
-- ledger antes:
--
--   \copy (select * from public.table_deposit_movements order by created_at)
--     to 'table_deposit_movements_backup.csv' csv header
--
-- Los `payments` con método 'table_deposit' NO se tocan: son ventas reales con
-- su NCF emitido. Después del rollback quedan huérfanos de ledger (el cobro
-- siguió siendo válido, solo que ya no se sabe de qué saldo salió).
-- =============================================================================

begin;

drop trigger if exists trg_table_deposit_on_payment      on public.payments;
drop trigger if exists trg_table_deposit_on_payment_void on public.payments;
drop trigger if exists trg_table_deposit_block_method_change on public.payments;

drop function if exists public.fn_table_deposit_on_payment();
drop function if exists public.fn_table_deposit_on_payment_void();
drop function if exists public.fn_table_deposit_block_method_change();
drop function if exists public.fn_table_deposit_for_order(uuid);
drop function if exists public.fn_table_deposit_for_payment(uuid);
drop function if exists public.fn_table_deposit_balance_for_order(uuid);
drop function if exists public.fn_table_deposit_balances(uuid);
drop function if exists public.fn_table_deposit_transfer(uuid, uuid, numeric, text);
drop function if exists public.fn_table_deposit_refund(uuid, numeric, uuid, text);
drop function if exists public.fn_table_deposit_add(uuid, numeric, text, uuid, text, text, text);
drop function if exists public.fn_table_deposit_account(uuid, boolean);
drop function if exists public.fn_ensure_table_deposit_method(uuid);

drop table if exists public.table_deposit_movements;
drop table if exists public.table_deposit_accounts;

-- El método de pago se desactiva en vez de borrarse: los `payments` que ya se
-- cobraron contra el saldo lo referencian por FK.
update public.payment_methods
   set is_active = false
 where code = 'table_deposit';

drop index if exists public.uq_payment_methods_table_deposit;

delete from public.role_permissions rp
 using public.permissions p
 where p.id = rp.permission_id
   and p.code like 'ventas.abono_mesa.%';

delete from public.permissions
 where code like 'ventas.abono_mesa.%';

commit;

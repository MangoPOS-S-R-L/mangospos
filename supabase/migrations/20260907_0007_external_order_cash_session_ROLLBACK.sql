-- Rollback de 20260907_0007_external_order_cash_session.sql
--
-- Volver atras deja los pedidos prepagados otra vez con
-- payment_error='CASH_SESSION_REQUIRED'. El pedido sigue entrando y la comanda
-- sigue saliendo; lo que se pierde es el registro del cobro.
--
-- Ojo: si ya se aplico la version de fn_ingest_external_order que llama a esta
-- funcion, hay que revertir TAMBIEN esa (rollback de 20260907_0006) o la
-- ingesta falla por funcion inexistente.

begin;

drop function if exists public.fn_external_open_cash_session(uuid);

commit;

-- Rollback de 20260924_0003_channel_link_codes.sql
--
-- Quita el autoservicio. Las credenciales YA emitidas siguen funcionando: esto
-- solo borra la forma de emitirlas desde la POS, no el canal. Para cortarle el
-- acceso a un canal hay que revocar su credencial:
--
--   update public.external_api_keys
--      set is_active = false, revoked_at = now()
--    where business_id = '<id>' and channel = 'pincer';

begin;

drop function if exists public.fn_disconnect_channel(uuid, text);
drop function if exists public.fn_channel_link_status(uuid, text);
drop function if exists public.fn_redeem_channel_link_code(text);
drop function if exists public.fn_create_channel_link_code(uuid, text, text);
drop table if exists public.external_channel_link_codes;

commit;

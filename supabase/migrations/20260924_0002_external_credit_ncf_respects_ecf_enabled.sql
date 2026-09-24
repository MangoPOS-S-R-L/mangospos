-- =============================================================================
-- Pincer — apagar la modalidad e-CF no apagaba los E31 de canales externos
--
-- Corrige 20260924_0001.
--
-- EL DEFECTO
--   `fn_external_credit_ncf_type` elegia la serie mirando SOLO las secuencias:
--   si habia una E31 activa, vigente y con numeros, devolvia E31. Nunca leia
--   `fiscal_settings.ecf_enabled`.
--
--   Pero el switch "Modalidad e-CF" de la POS (ecf-onboarding/set_ecf_enabled)
--   al apagarse solo hace dos cosas: pone `ecf_enabled = false` y baja el
--   `default_ncf_type` de E32 a B02. NO desactiva las secuencias: la E31 se
--   queda con `is_active = true`.
--
--   Resultado: un negocio que apaga la modalidad electronica seguia partido —
--   el mostrador emitiendo consumo en papel (B02) y cada pedido externo con
--   RNC saliendo en E31 electronico. Y esa E31 es justo el "limbo" contra el
--   que el propio set_ecf_enabled protege al ENCENDER: una serie E emitida sin
--   que el negocio este en modo electronico no tiene a quien mandarse a firmar.
--
-- LA REGLA
--   E31 solo si el negocio tiene la modalidad e-CF ENCENDIDA. Si esta apagada,
--   la electronica no se considera y queda:
--     - negocio con e-CF encendido        → E31 (si la secuencia esta viva)
--     - negocio con e-CF apagado, con B01 → B01, credito fiscal de papel
--     - negocio con e-CF apagado, sin B01 → NULL, y el cobro cae al default
--       del negocio, igual que un negocio sin credito fiscal
--
--   Asi el switch manda en los dos sentidos y nadie tiene que acordarse de ir
--   a desactivar la secuencia a mano.
--
--   `exists` en vez de subconsulta escalar: si algun negocio llegara a tener
--   mas de una fila en fiscal_settings, un `select ... into` reventaria; asi
--   basta con que una diga que si.
--
-- RIESGO: bajo. Reemplaza una funcion de lectura. No toca secuencias, ni
--   `fn_ingest_external_order`, ni `fn_process_payment_v3`. Rollback:
--   20260924_0002_..._ROLLBACK.sql devuelve la version anterior.
-- =============================================================================

begin;

create or replace function public.fn_external_credit_ncf_type(p_business_id uuid)
returns text
language sql
stable
security definer
set search_path to 'public'
as $$
  select s.ncf_type::text
    from public.ncf_sequences s
   where s.business_id = p_business_id
     and s.is_active
     and s.ncf_type::text in ('E31', 'B01')
     and s.current_number < s.range_end
     and (s.expiration_date is null or s.expiration_date >= current_date)
     -- La electronica solo cuenta con la modalidad e-CF encendida.
     and (
       s.ncf_type::text <> 'E31'
       or exists (
         select 1
           from public.fiscal_settings fs
          where fs.business_id = p_business_id
            and fs.ecf_enabled
       )
     )
   order by case s.ncf_type::text when 'E31' then 0 else 1 end
   limit 1;
$$;

comment on function public.fn_external_credit_ncf_type(uuid) is
  'Serie de credito fiscal que este negocio tiene viva, prefiriendo la '
  'electronica (E31) sobre la de papel (B01). La E31 solo se considera si el '
  'negocio tiene la modalidad e-CF encendida (fiscal_settings.ecf_enabled): '
  'apagar el switch apaga los E31 sin tener que desactivar la secuencia. NULL '
  'si no queda ninguna: el cobro cae al default del negocio en vez de fallar. '
  'La usa la ingesta de canales externos cuando el pedido trae RNC.';

revoke all on function public.fn_external_credit_ncf_type(uuid) from public;
grant execute on function public.fn_external_credit_ncf_type(uuid) to service_role;

commit;

notify pgrst, 'reload schema';

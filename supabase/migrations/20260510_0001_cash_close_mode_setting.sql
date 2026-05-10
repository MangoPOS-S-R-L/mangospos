-- PRD · Modos de Cierre de Caja a Ciegas (Compacto vs Detallado)
-- Sub-fase A · Setting toggle
--
-- Agrega la columna `cash_close_mode` a `business_settings` para que cada
-- negocio elija entre el modo COMPACTO (un solo modal con efectivo + tarjeta
-- + transferencia) y el modo DETALLADO (wizard de 3 pasos: efectivo
-- separado de tarjeta + transferencia, con paso final de revision).
--
-- IMPORTANTE: ambos modos son a ciegas durante el conteo. Ninguno expone
-- el monto esperado al cajero antes de confirmar. La diferencia es solo
-- estructural (UX).
--
-- Default: 'compact' porque es el comportamiento actual del POS.
--
-- RLS: no se agrega politica nueva. La tabla ya tiene `bs_select` (lectura
-- para cualquier miembro del business) y `bs_admin` (escritura solo para
-- owner/admin), que cubren exactamente lo pedido por el PRD.

begin;

alter table public.business_settings
  add column if not exists cash_close_mode text not null default 'compact';

-- CHECK constraint solo si no existe (idempotencia para re-runs).
do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'business_settings_cash_close_mode_check'
      and conrelid = 'public.business_settings'::regclass
  ) then
    alter table public.business_settings
      add constraint business_settings_cash_close_mode_check
      check (cash_close_mode in ('compact', 'detailed'));
  end if;
end$$;

comment on column public.business_settings.cash_close_mode is
  'Modo de cierre de caja preferido del negocio. compact = un solo modal con efectivo + tarjeta + transferencia juntos (comportamiento actual). detailed = wizard de 3 pasos (efectivo, luego tarjeta + transferencia, luego revision). Ambos son a ciegas durante el conteo. Default compact.';

-- Backfill defensivo: cualquier fila con NULL queda en compact.
update public.business_settings
set cash_close_mode = coalesce(cash_close_mode, 'compact')
where cash_close_mode is null;

commit;

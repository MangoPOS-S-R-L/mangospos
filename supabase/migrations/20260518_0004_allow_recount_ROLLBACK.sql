-- Rollback de `20260518_0004_allow_recount.sql`. Elimina la columna —
-- toda configuración del admin se pierde y el comportamiento vuelve a
-- ser "sin botón de recontar".

begin;

alter table public.business_settings
  drop column if exists allow_recount;

commit;

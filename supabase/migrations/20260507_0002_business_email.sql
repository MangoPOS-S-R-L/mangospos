-- 20260507_0002_business_email.sql
--
-- Scope: agregar columna `email` a businesses. La pantalla "Datos del
-- Negocio" creada en 20260507_0001 expone un campo Email que no tenia
-- columna en el schema (BusinessProfileRepository.getProfile() rompia
-- con: column businesses.email does not exist).
--
-- Idempotente: add column if not exists.

begin;

alter table public.businesses
  add column if not exists email text;

comment on column public.businesses.email is
  'Email de contacto del negocio. Editable desde Ajustes > Datos del Negocio. '
  'Se imprime opcionalmente en el header del ticket si se decide en futuras versiones.';

commit;

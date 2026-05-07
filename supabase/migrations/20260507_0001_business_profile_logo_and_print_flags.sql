-- 20260507_0001_business_profile_logo_and_print_flags.sql
--
-- Scope: ampliar el perfil del negocio editable + soporte de logo + toggles
-- para personalizar la representación impresa.
--
-- Cambios:
--   1. businesses: agregar logo_url, logo_storage_path, slogan,
--      ticket_footer_message. Cada row de businesses es UNA sucursal
--      en este modelo, asi que el logo es por sucursal automaticamente.
--   2. business_settings: agregar 3 flags de impresion.
--   3. Storage bucket "business-logos" publico (max 2MB, png/jpg).
--   4. RLS policies para el bucket: solo miembros del business pueden
--      INSERT/UPDATE/DELETE su propio logo; SELECT publico (cualquiera
--      con la URL puede ver el archivo, lo cual es intencional —
--      no hay info sensible en un logo).

begin;

-- ============================================================================
-- 1) businesses: campos editables del perfil
-- ============================================================================

alter table public.businesses
  add column if not exists logo_url text,
  add column if not exists logo_storage_path text,
  add column if not exists slogan text,
  add column if not exists ticket_footer_message text;

comment on column public.businesses.logo_url is
  'URL publica del logo de la sucursal (Storage bucket business-logos). Null si no se subio.';
comment on column public.businesses.logo_storage_path is
  'Path interno al objeto en Storage. Necesario para sobrescribir/borrar al cambiar logo.';
comment on column public.businesses.slogan is
  'Eslogan corto del negocio. Se imprime debajo del nombre si business_settings.show_slogan_on_invoice=true.';
comment on column public.businesses.ticket_footer_message is
  'Mensaje libre al pie del ticket impreso (ej "Gracias por su visita"). Null oculta la seccion.';

-- ============================================================================
-- 2) business_settings: flags de impresion
-- ============================================================================

alter table public.business_settings
  add column if not exists print_logo_on_invoice boolean default false,
  add column if not exists show_slogan_on_invoice boolean default true,
  add column if not exists show_branch_name_on_invoice boolean default true;

comment on column public.business_settings.print_logo_on_invoice is
  'Si TRUE y businesses.logo_url no es null, se imprime el logo en el header de la factura.';
comment on column public.business_settings.show_slogan_on_invoice is
  'Si TRUE y businesses.slogan no es null/vacio, se imprime el eslogan debajo del nombre.';
comment on column public.business_settings.show_branch_name_on_invoice is
  'Si FALSE, NO se imprime "Sucursal: Xxx" en el header de la factura. Default TRUE preserva el comportamiento actual.';

-- ============================================================================
-- 3) Storage bucket para logos
-- ============================================================================

-- Bucket publico: cualquiera con la URL ve el logo. Aceptable porque un
-- logo no es info sensible, y permite que cached_network_image cachee
-- sin lidiar con signed URLs.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'business-logos',
  'business-logos',
  true,
  2097152, -- 2MB
  array['image/png', 'image/jpeg', 'image/jpg']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- ============================================================================
-- 4) RLS policies del bucket
-- ============================================================================

-- SELECT: publico (el bucket ya es publico, esto es por defensa adicional).
drop policy if exists "business_logos_select_public" on storage.objects;
create policy "business_logos_select_public" on storage.objects
  for select
  using (bucket_id = 'business-logos');

-- INSERT/UPDATE/DELETE: solo miembros del business pueden tocar el path
-- de SU business. El path tiene formato "<business_id>/<filename>" — la
-- primera carpeta es el business_id como uuid.
drop policy if exists "business_logos_insert_owner" on storage.objects;
create policy "business_logos_insert_owner" on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'business-logos'
    and public.user_has_business_access(
      auth.uid(),
      (storage.foldername(name))[1]::uuid
    )
  );

drop policy if exists "business_logos_update_owner" on storage.objects;
create policy "business_logos_update_owner" on storage.objects
  for update
  to authenticated
  using (
    bucket_id = 'business-logos'
    and public.user_has_business_access(
      auth.uid(),
      (storage.foldername(name))[1]::uuid
    )
  );

drop policy if exists "business_logos_delete_owner" on storage.objects;
create policy "business_logos_delete_owner" on storage.objects
  for delete
  to authenticated
  using (
    bucket_id = 'business-logos'
    and public.user_has_business_access(
      auth.uid(),
      (storage.foldername(name))[1]::uuid
    )
  );

commit;

-- ============================================================================
-- Smoke check post-deploy
-- ============================================================================
-- 1. Verificar columnas:
--    \d public.businesses
--    \d public.business_settings
--
-- 2. Verificar bucket:
--    select * from storage.buckets where id = 'business-logos';
--
-- 3. Verificar policies:
--    select policyname from pg_policies where tablename = 'objects'
--      and policyname like 'business_logos%';
--    -- Esperado: 4 rows (select, insert, update, delete).

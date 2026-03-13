-- Registration onboarding metadata for MangoPOS businesses.
-- Keeps domain as the source of truth for future subdomain routing.

alter table public.businesses
  add column if not exists business_type text,
  add column if not exists phone text;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.businesses'::regclass
      and conname = 'businesses_business_type_check'
  ) then
    alter table public.businesses
      add constraint businesses_business_type_check
      check (
        business_type is null
        or business_type = any (
          array[
            'Restaurante',
            'Comida Rapida',
            'Cafeteria / Panaderia',
            'Bar / Lounge',
            'Heladeria / Postres',
            'Solo Delivery',
            'Tienda de Conveniencia',
            'Bar de Jugos / Comida Saludable',
            'Food Truck',
            'Otro'
          ]
        )
      );
  end if;
end $$;

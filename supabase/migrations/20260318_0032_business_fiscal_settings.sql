-- 20260318_0032_business_fiscal_settings.sql
-- Preferencia de facturación electrónica y datos fiscales del negocio

alter table public.businesses
  add column if not exists prefer_electronic_billing boolean default false,
  add column if not exists fiscal_rnc varchar(11),
  add column if not exists fiscal_name text;

-- Asegurar RLS para estas columnas (generalmente ya está por negocio)

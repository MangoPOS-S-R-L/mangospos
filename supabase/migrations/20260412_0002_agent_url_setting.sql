-- Store the print agent URL so remote devices (tablets) can reach it.
-- The main PC publishes its agent URL on startup; tablets read it.
ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS agent_url text DEFAULT NULL;

COMMENT ON COLUMN public.business_settings.agent_url
  IS 'URL del agente de impresión local (ej: http://192.168.1.50:4000). '
     'Publicado automáticamente por la PC principal al arrancar.';

-- ================================================================
-- DIAGNÓSTICO DE USUARIO AUTH
-- Muestra los datos crudos del último usuario creado para detectar anomalías
-- ================================================================

SELECT 
  id, 
  email,
  encrypted_password,
  email_confirmed_at,
  raw_user_meta_data,
  app_metadata, 
  created_at,
  updated_at,
  instance_id,
  aud,
  role
FROM auth.users
ORDER BY created_at DESC
LIMIT 1;

SELECT * 
FROM auth.identities
WHERE user_id = (SELECT id FROM auth.users ORDER BY created_at DESC LIMIT 1);

-- ================================================================
-- CORRECCIÓN FINAL (V4): FUNCIÓN RPC PARA CREAR USUARIOS
-- Ahora guarda el business_id en los metadatos para acceso inmediato
-- ================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE OR REPLACE FUNCTION public.create_new_user(
  email text,
  password text,
  user_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  new_uid uuid;
  existing_uid uuid;
  encrypted_pw text;
BEGIN
  -- Verificar si el email ya existe
  SELECT id INTO existing_uid FROM auth.users WHERE auth.users.email = create_new_user.email;
  IF existing_uid IS NOT NULL THEN
    RAISE EXCEPTION 'El usuario con email % ya existe', email;
  END IF;

  new_uid := gen_random_uuid();
  encrypted_pw := crypt(password, gen_salt('bf'));

  -- Asegurar que los metadatos incluyan business_id si vienen en el JSON
  -- (El cliente debe enviarlo dentro de user_metadata)

  INSERT INTO auth.users (
    instance_id,
    id,
    aud,
    role,
    email,
    encrypted_password,
    email_confirmed_at,
    recovery_sent_at,
    last_sign_in_at,
    raw_app_meta_data,
    raw_user_meta_data,
    created_at,
    updated_at,
    confirmation_token,
    recovery_token,
    email_change_token_new,
    email_change,
    is_super_admin
  ) VALUES (
    '00000000-0000-0000-0000-000000000000',
    new_uid,
    'authenticated',
    'authenticated',
    email,
    encrypted_pw,
    now(),
    NULL,
    NULL,
    '{"provider": "email", "providers": ["email"]}'::jsonb,
    user_metadata, -- Aquí ya vendrá el business_id
    now(),
    now(),
    '',
    '',
    '',
    '',
    false
  );

  -- Insertar identidad
  INSERT INTO auth.identities (
    id,
    user_id,
    identity_data,
    provider,
    provider_id,
    last_sign_in_at,
    created_at,
    updated_at
  ) VALUES (
    new_uid,
    new_uid,
    format('{"sub": "%s", "email": "%s", "email_verified": true, "phone_verified": false}', new_uid, email)::jsonb,
    'email',
    new_uid::text,
    NULL,
    now(),
    now()
  );

  RETURN new_uid;
END;
$$;

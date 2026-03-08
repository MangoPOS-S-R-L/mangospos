begin;

create or replace function public.create_new_user(
  email text,
  password text,
  user_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public, auth, extensions
as $$
declare
  new_user_id uuid := gen_random_uuid();
  full_name text;
begin
  if email is null or trim(email) = '' then
    raise exception 'EMAIL_REQUIRED';
  end if;

  if password is null or length(password) < 6 then
    raise exception 'PASSWORD_TOO_SHORT';
  end if;

  full_name := nullif(
    trim(
      coalesce(user_metadata->>'full_name', '') || ' ' ||
      coalesce(user_metadata->>'last_name', '')
    ),
    ''
  );

  if full_name is null or full_name = '' then
    full_name := coalesce(user_metadata->>'full_name', email);
  end if;

  insert into auth.users (
    id,
    instance_id,
    aud,
    role,
    email,
    encrypted_password,
    email_confirmed_at,
    raw_app_meta_data,
    raw_user_meta_data,
    created_at,
    updated_at,
    confirmation_token,
    email_change,
    email_change_token_new,
    recovery_token
  )
  values (
    new_user_id,
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    lower(trim(email)),
    extensions.crypt(password, extensions.gen_salt('bf')),
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    coalesce(user_metadata, '{}'::jsonb),
    now(),
    now(),
    '',
    '',
    '',
    ''
  );

  insert into auth.identities (
    id,
    user_id,
    identity_data,
    provider,
    provider_id,
    last_sign_in_at,
    created_at,
    updated_at
  )
  values (
    gen_random_uuid(),
    new_user_id,
    jsonb_build_object(
      'sub', new_user_id::text,
      'email', lower(trim(email))
    ),
    'email',
    new_user_id::text,
    now(),
    now(),
    now()
  );

  insert into public.profiles (id, email, full_name, created_at, updated_at)
  values (new_user_id, lower(trim(email)), full_name, now(), now())
  on conflict (id) do update
  set email = excluded.email,
      full_name = excluded.full_name,
      updated_at = now();

  return new_user_id;
end;
$$;

grant execute on function public.create_new_user(text, text, jsonb) to authenticated;

commit;

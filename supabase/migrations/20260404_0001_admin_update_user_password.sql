begin;

create or replace function public.admin_update_user_password(
  target_user_id uuid,
  new_password text
)
returns void
language plpgsql
security definer
set search_path = public, auth, extensions
as $$
begin
  if new_password is null or length(new_password) < 6 then
    raise exception 'PASSWORD_TOO_SHORT';
  end if;

  update auth.users
  set
    encrypted_password = extensions.crypt(new_password, extensions.gen_salt('bf')),
    updated_at = now()
  where id = target_user_id;

  if not found then
    raise exception 'USER_NOT_FOUND';
  end if;
end;
$$;

grant execute on function public.admin_update_user_password(uuid, text) to authenticated;

commit;

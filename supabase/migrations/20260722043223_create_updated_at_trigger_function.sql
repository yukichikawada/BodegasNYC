-- Shared trigger function to keep an `updated_at` column current on every
-- UPDATE. Reused by bodegas and reviews (photos/flags have no editable
-- fields besides is_hidden, which is only ever touched by the flags
-- auto-hide trigger, so they don't need this).
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

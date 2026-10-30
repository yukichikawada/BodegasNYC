-- Account deletion (#127, spec D1, eng D2 and D4). Three parts, all
-- re-runnable because the owner applies this to the hosted project with
-- `supabase db push --linked --yes` and QA applies it to the local stack by
-- hand.
--
-- 1. bodegas.created_by: nullable, FK `on delete set null`.
--    Until now the FK cascaded, so deleting a user deleted every bodega they
--    added, and with it every other user's reviews, photos and flags on
--    those bodegas. The privacy policy promises the opposite: "Bodegas you
--    added stay in the shared map without any link to you".
--    RLS is unchanged on purpose: `bodegas_insert` is
--    `with check (auth.uid() = created_by)`, and a NULL created_by makes that
--    comparison NULL, not true, so the column being nullable does not reopen
--    the 2026-08 anonymous-insert hole (20260812013849, reverted by
--    20260815181145). `bodegas_select` (`is_hidden = false or auth.uid() =
--    created_by`) treats an ownerless row as anyone else's.
--    App builds since #144 decode `created_by` as optional, so an ownerless
--    row never breaks an installed build.
--
-- 2. public.auth_user_exists(): true when the caller's auth.users row
--    exists. A deleted user's access token stays valid until it expires (up
--    to an hour); this lets a policy refuse writes from such a token.
--    `security definer` because `authenticated` cannot read auth.users.
--
-- 3. public.storage_paths_owned_by(p_owner, p_after, p_page_size): the
--    `photos` bucket object names whose owner_id is `p_owner`, in name
--    order, one keyset page at a time. The delete-account edge function
--    lists what to remove from here, by owner rather than from
--    public.photos rows, because PhotoService uploads the object before it
--    inserts the row (a failed insert leaves an owned object with no row)
--    and because the photos rows are already gone (cascade) when the sweep
--    runs. The `storage` schema is
--    not exposed through PostgREST, hence a function in `public`. Callable
--    by service_role only.
--
-- 4. photos_objects_insert (20261020000000) gains
--    `and public.auth_user_exists()`, so a second device holding a deleted
--    user's still-valid token cannot upload after the sweep.
--
-- Rollback: reversible only while no bodega has a NULL created_by:
--   alter table public.bodegas drop constraint bodegas_created_by_fkey;
--   alter table public.bodegas add constraint bodegas_created_by_fkey
--       foreign key (created_by) references auth.users(id) on delete cascade;
--   alter table public.bodegas alter column created_by set not null;
-- After the first account deletion it is not, without reassigning rows;
-- this is the one-way part, taken as spec D1. The functions and the policy
-- change can be dropped or restored at any time.

-- 1. created_by: nullable, set null on user delete.
alter table public.bodegas alter column created_by drop not null;
alter table public.bodegas drop constraint if exists bodegas_created_by_fkey;
alter table public.bodegas
    add constraint bodegas_created_by_fkey
    foreign key (created_by) references auth.users(id) on delete set null;

-- 2. Does the caller's user row still exist?
create or replace function public.auth_user_exists()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (select 1 from auth.users u where u.id = (select auth.uid()));
$$;

-- 3. Storage paths a user owns in the photos bucket, one page at a time.
-- `p_after` is the last name of the previous page (null for the first);
-- `p_page_size` is clamped to 1..1000. Prefixed parameter names: in a SQL
-- function a bare `owner` would resolve to storage.objects' own (legacy)
-- `owner` column, not the parameter.
create or replace function public.storage_paths_owned_by(
    p_owner uuid,
    p_after text default null,
    p_page_size integer default 1000
)
returns setof text
language sql
stable
security definer
set search_path = ''
as $$
    select o.name
    from storage.objects o
    where o.bucket_id = 'photos'
      and o.owner_id = p_owner::text
      and (p_after is null or o.name > p_after)
    order by o.name
    limit greatest(1, least(coalesce(p_page_size, 1000), 1000));
$$;

revoke execute on function public.storage_paths_owned_by(uuid, text, integer) from public, anon, authenticated;
grant execute on function public.storage_paths_owned_by(uuid, text, integer) to service_role;

-- 4. No uploads from a deleted user's leftover token. Same policy as
-- 20261020000000 plus the last clause.
drop policy if exists "photos_objects_insert" on storage.objects;
create policy "photos_objects_insert" on storage.objects
    for insert
    to authenticated
    with check (
        bucket_id = 'photos'
        and owner_id = (select auth.uid())::text
        and array_length(storage.foldername(name), 1) = 1
        and case
            when (storage.foldername(name))[1]
                ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            then exists (
                select 1 from public.bodegas b
                where b.id = ((storage.foldername(objects.name))[1])::uuid
            )
            else false
        end
        and public.auth_user_exists()
    );

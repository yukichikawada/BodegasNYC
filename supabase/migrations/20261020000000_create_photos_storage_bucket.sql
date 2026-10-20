-- Storage bucket + storage.objects policies backing PhotoService (#36).
-- Before this, uploads failed with "Bucket not found": the `photos` table
-- existed but no migration created the bucket it points into.
--
-- Convention (mirrors the doc comment on PhotoService.swift): bucket is
-- named "photos"; each object's name is "<bodegaId>/<uuid>.<extension>",
-- and that full bucket-relative path is what public.photos.storage_path
-- stores. The app always re-encodes to JPEG before upload
-- (PhotoImageEncoder: long edge <= 1600px, quality 0.8, so typically well
-- under 1 MB), sending contentType "image/jpeg" with extension "jpg".
-- The bucket only admits image/jpeg, capped at 5 MiB for headroom.
--
-- Public bucket: browsing doesn't require sign-in (same stance as the
-- public read policies on the tables), and PhotoService.publicURL builds
-- public object URLs. Writes are auth-gated:
--   - insert: authenticated, owner is the caller, and the first path
--     segment is the id of an existing (visible) public.bodegas row, with
--     exactly one folder level.
--   - delete: only the object's owner.
--   - no update policy (objects are immutable; nothing upserts).
--
-- Written to be re-runnable (on conflict / drop policy if exists) because
-- it is also applied to the hosted project by hand.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', true, 5242880, array['image/jpeg'])
on conflict (id) do nothing;

drop policy if exists "photos_objects_select" on storage.objects;
create policy "photos_objects_select" on storage.objects
    for select
    using (bucket_id = 'photos');

-- The uuid regex guard runs inside CASE so a malformed folder name yields
-- false instead of a cast error; it is case-insensitive because Swift's
-- UUID string interpolation is uppercase. `objects.name` must be
-- qualified: inside the EXISTS subquery a bare `name` would resolve to
-- public.bodegas.name and the check would silently always fail.
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
    );

drop policy if exists "photos_objects_delete" on storage.objects;
create policy "photos_objects_delete" on storage.objects
    for delete
    to authenticated
    using (
        bucket_id = 'photos'
        and owner_id = (select auth.uid())::text
    );

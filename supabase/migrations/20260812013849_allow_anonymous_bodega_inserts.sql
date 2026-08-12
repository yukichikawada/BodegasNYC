-- TEMPORARY DEV WORKAROUND: Sign in with Apple is blocked on Apple Developer
-- Program enrollment (free "Personal Team" can't register the
-- com.apple.developer.applesignin capability), so there is currently no way
-- to establish an authenticated session at all. This migration lets
-- Add-a-Bodega keep shipping by allowing unauthenticated (anon role)
-- inserts into bodegas.
--
-- Known, accepted drawbacks (see conversation, not re-derived here):
-- - The anon key ships inside the app binary and isn't a secret, so this is
--   a public, unrate-limited write hole on the live project for as long as
--   it's in place.
-- - created_by is now nullable, so anon-authored rows have no owner —
--   bodegas_select's `auth.uid() = created_by` own-row-visibility clause is
--   moot for them, and any future moderation/ownership feature will need to
--   handle created_by IS NULL as a distinct case.
-- - This bypasses the real authenticated-write code path (SessionStore /
--   AddBodegaViewModel's auth gate) rather than exercising it.
--
-- REVERT this migration (or a follow-up one restoring NOT NULL + `to
-- authenticated`) once Sign in with Apple enrollment clears and the app no
-- longer needs an unauthenticated path.

alter table public.bodegas alter column created_by drop not null;

drop policy "bodegas_insert" on public.bodegas;

create policy "bodegas_insert" on public.bodegas
    for insert
    to anon, authenticated
    with check (
        (auth.uid() is null and created_by is null)
        or auth.uid() = created_by
    );

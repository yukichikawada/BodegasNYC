-- Public (anon + authenticated) read of non-hidden rows on all four
-- tables: docs/PRD.md's "make it fast to find a bodega" goal implies
-- browsing shouldn't require signing in first — only writes are
-- auth-gated. Own rows remain visible to their author/uploader/reporter
-- even if hidden.
--
-- Known, accepted gap (see docs/PRD.md and this task's plan notes):
-- bodegas_update has no column-level restriction, so any authenticated
-- user could technically flip is_hidden back to false via a normal
-- update call, undermining the flags auto-hide trigger's intent. A real
-- fix needs either a protective trigger pinning is_hidden/created_by
-- against client-supplied changes, or column-level privileges — both add
-- complexity that isn't safely verifiable without a live project to test
-- the trigger interaction against. Left as documented debt, consistent
-- with the PRD's "immediate edits, revisit only if bad-faith edits become
-- a real problem" MVP stance.
alter table public.bodegas enable row level security;
alter table public.reviews enable row level security;
alter table public.photos  enable row level security;
alter table public.flags   enable row level security;

-- bodegas: public read; any authenticated user can insert/edit (immediate
-- edit model per PRD); no delete policy (default deny).
create policy "bodegas_select" on public.bodegas
    for select
    using (is_hidden = false or auth.uid() = created_by);

create policy "bodegas_insert" on public.bodegas
    for insert
    to authenticated
    with check (auth.uid() = created_by);

create policy "bodegas_update" on public.bodegas
    for update
    to authenticated
    using (true)
    with check (true);

-- reviews: public read; author-only insert/update/delete.
create policy "reviews_select" on public.reviews
    for select
    using (is_hidden = false or auth.uid() = author_id);

create policy "reviews_insert" on public.reviews
    for insert
    to authenticated
    with check (auth.uid() = author_id);

create policy "reviews_update" on public.reviews
    for update
    to authenticated
    using (auth.uid() = author_id)
    with check (auth.uid() = author_id);

create policy "reviews_delete" on public.reviews
    for delete
    to authenticated
    using (auth.uid() = author_id);

-- photos: public read; uploader-only insert/delete; no update policy
-- (nothing mutable besides is_hidden, which only the flags trigger
-- touches via security definer).
create policy "photos_select" on public.photos
    for select
    using (is_hidden = false or auth.uid() = uploaded_by);

create policy "photos_insert" on public.photos
    for insert
    to authenticated
    with check (auth.uid() = uploaded_by);

create policy "photos_delete" on public.photos
    for delete
    to authenticated
    using (auth.uid() = uploaded_by);

-- flags: reporters can see and create their own flags; no update/delete
-- (unflagging isn't a v1 feature — "no human moderation queue for v1").
create policy "flags_select" on public.flags
    for select
    to authenticated
    using (auth.uid() = reporter_id);

create policy "flags_insert" on public.flags
    for insert
    to authenticated
    with check (auth.uid() = reporter_id);

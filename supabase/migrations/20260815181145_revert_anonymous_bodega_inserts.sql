-- Reverts 20260812013849_allow_anonymous_bodega_inserts.sql now that Sign
-- in with Apple works end-to-end (Apple Developer Program enrollment
-- cleared), restoring the auth-gated write path PRD §4.2 specifies.
--
-- The one anon-authored row created while the hole was open (created_by
-- IS NULL, from that migration's own verification step) is deleted first
-- since it has no owner to backfill and would otherwise violate the
-- restored NOT NULL constraint.

delete from public.bodegas where created_by is null;

alter table public.bodegas alter column created_by set not null;

drop policy "bodegas_insert" on public.bodegas;

create policy "bodegas_insert" on public.bodegas
    for insert
    to authenticated
    with check (auth.uid() = created_by);

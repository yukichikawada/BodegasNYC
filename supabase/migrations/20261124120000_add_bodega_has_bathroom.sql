-- Seventh data point: the bodega has a bathroom a customer can use (#194);
-- staff-only does not count. Additive and defaulted, so app builds without
-- #194 keep decoding `bodegas` rows (the column is ignored by their
-- CodingKeys) and their inserts, which omit it, get `false`.
-- `nearby_bodegas` returns `setof public.bodegas` with `select *`, so it
-- returns the new column with no function change.
--
-- Builds with #194 decode `has_bathroom` as a required key, so this
-- migration must be applied before such a build runs against a database.
--
-- No RLS change: the bodegas policies have no column lists.
--
-- Rollback: revert the app PR and KEEP the column. Drop it only when no
-- build carrying `hasBathroom` can still be installed, since those builds
-- fail to decode a row without it (#141 eng review D7, repeated by #194).
-- Then:
--   alter table public.bodegas drop column has_bathroom;

alter table public.bodegas
    add column has_bathroom boolean not null default false;

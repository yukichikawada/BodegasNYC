-- Sixth data point: the bodega has an ATM inside the store (#141). Additive
-- and defaulted, so app builds without #141 keep decoding `bodegas` rows
-- (the column is ignored by their CodingKeys) and their inserts, which omit
-- it, get `false`. `nearby_bodegas` returns `setof public.bodegas` with
-- `select *`, so it returns the new column with no function change.
--
-- Builds with #141 decode `has_atm` as a required key, so this migration
-- must be applied before such a build runs against a database.
--
-- No RLS change: the bodegas policies have no column lists.
--
-- Rollback: revert the app PR and KEEP the column. Drop it only when no
-- build carrying `hasAtm` can still be installed, since those builds fail
-- to decode a row without it (#141 eng review D7). Then:
--   alter table public.bodegas drop column has_atm;

alter table public.bodegas
    add column has_atm boolean not null default false;

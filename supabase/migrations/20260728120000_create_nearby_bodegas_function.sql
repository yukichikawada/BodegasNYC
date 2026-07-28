-- Proximity search for the core "find a bodega near me" loop (docs/PRD.md
-- Section 4.2). PostgREST can't express ST_DWithin filtering through plain
-- query-string filters on a geography column, so this is exposed as an RPC
-- instead of relying on the auto-generated `bodegas` REST endpoint.
--
-- `security invoker` (the default, stated explicitly for clarity): unlike
-- the flags auto-hide trigger, this doesn't need to bypass RLS — it should
-- see exactly what a direct `select * from bodegas` would for the calling
-- role, so `bodegas_select`'s is_hidden/created_by check keeps applying
-- row-by-row.
create or replace function public.nearby_bodegas(
    lat double precision,
    long double precision,
    radius_meters double precision default 1000
)
returns setof public.bodegas
language sql
stable
security invoker
set search_path = public, extensions
as $$
    select *
    from public.bodegas
    where extensions.st_dwithin(
        location,
        extensions.geography(extensions.st_makepoint(long, lat)),
        radius_meters
    )
    order by extensions.st_distance(
        location,
        extensions.geography(extensions.st_makepoint(long, lat))
    );
$$;

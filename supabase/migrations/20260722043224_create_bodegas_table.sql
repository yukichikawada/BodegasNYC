-- Core bodega entity: the five signature data points plus address, hours,
-- and location. `hours` is a jsonb blob rather than a separate table —
-- hours are read far more than they're filtered/queried, and no MVP
-- requirement needs "open now" filtering, so a normalized table would just
-- be a join with no payoff yet.
--
-- No stored `rating` column: community rating is derived at query time
-- from `reviews` (AVG(rating)) in the future networking slice, not stored
-- here — nothing to keep in sync via a trigger for something never queried
-- yet.
create table public.bodegas (
    id uuid primary key default gen_random_uuid(),
    created_by uuid not null references auth.users(id) on delete cascade,
    name text not null,
    location geography(Point, 4326) not null,
    -- Generated from `location` so a plain `select *` hands back ordinary
    -- numeric fields instead of PostgREST's raw-WKB serialization of a
    -- geography column. `location` itself stays reserved for spatial
    -- queries (ST_DWithin) via the GIST index below.
    latitude double precision generated always as (st_y(location::geometry)) stored,
    longitude double precision generated always as (st_x(location::geometry)) stored,
    address text,
    has_cat boolean not null default false,
    serves_hot_food boolean not null default false,
    sells_cigarettes boolean not null default false,
    sells_beer boolean not null default false,
    sells_lotto boolean not null default false,
    hours jsonb,
    is_hidden boolean not null default false,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index bodegas_location_gist_idx on public.bodegas using gist (location);

create trigger set_bodegas_updated_at
before update on public.bodegas
for each row execute function public.set_updated_at();

-- Enables PostGIS for the bodegas.location geography column and
-- proximity queries (ST_DWithin) used by the "bodegas near me" search.
create extension if not exists postgis with schema extensions;

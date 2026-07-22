-- No updated_at/trigger: photos have no editable fields besides is_hidden,
-- which only the flags auto-hide trigger touches.
create table public.photos (
    id uuid primary key default gen_random_uuid(),
    bodega_id uuid not null references public.bodegas(id) on delete cascade,
    uploaded_by uuid not null references auth.users(id) on delete cascade,
    storage_path text not null,
    is_hidden boolean not null default false,
    created_at timestamptz not null default now()
);

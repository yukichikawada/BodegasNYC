-- One review per (bodega, author), enforced at the DB level via the
-- unique constraint below, not just app logic.
create table public.reviews (
    id uuid primary key default gen_random_uuid(),
    bodega_id uuid not null references public.bodegas(id) on delete cascade,
    author_id uuid not null references auth.users(id) on delete cascade,
    rating smallint not null check (rating between 1 and 5),
    body text,
    is_hidden boolean not null default false,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (bodega_id, author_id)
);

create trigger set_reviews_updated_at
before update on public.reviews
for each row execute function public.set_updated_at();

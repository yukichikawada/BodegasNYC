-- One generic flags table rather than per-table flag columns/tables:
-- centralizes the auto-hide logic in one trigger instead of three near
-- duplicates, and generalizes cleanly if more flaggable entity types show
-- up later (see docs/REACH_GOALS.md's "Generalized POI type system").
--
-- Three nullable target FKs + an exclusive-arc CHECK, rather than a
-- polymorphic target_type/target_id design: this keeps real foreign keys
-- (cascade-deletes work, orphans are impossible) while still being one
-- table with one auto-hide trigger.
create table public.flags (
    id uuid primary key default gen_random_uuid(),
    reporter_id uuid not null references auth.users(id) on delete cascade,
    bodega_id uuid references public.bodegas(id) on delete cascade,
    review_id uuid references public.reviews(id) on delete cascade,
    photo_id uuid references public.photos(id) on delete cascade,
    reason text,
    created_at timestamptz not null default now(),
    constraint flags_exactly_one_target check (
        num_nonnulls(bodega_id, review_id, photo_id) = 1
    )
);

-- One flag per (reporter, target). A single UNIQUE(...) across all four
-- columns would NOT actually block a user from flagging the same bodega
-- twice: standard SQL treats NULLs as distinct in unique constraints, and
-- both rows would have review_id/photo_id NULL, which never compare equal.
-- Partial unique indexes sidestep that.
create unique index flags_unique_bodega on public.flags (reporter_id, bodega_id) where bodega_id is not null;
create unique index flags_unique_review on public.flags (reporter_id, review_id) where review_id is not null;
create unique index flags_unique_photo on public.flags (reporter_id, photo_id) where photo_id is not null;

-- Auto-hide via an AFTER INSERT trigger, not a generated column: a
-- generated column can only reference other columns in the *same* row,
-- and is_hidden depends on a COUNT(*) over a different table, which a
-- generated column literally cannot express.
--
-- security definer is required: a flagger usually isn't the content's
-- author, so this needs to bypass the normal author-scoped UPDATE policy
-- on bodegas/reviews/photos. set search_path is a standard hardening
-- measure against search-path hijacking on security definer functions.
create or replace function public.handle_flag_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  threshold constant integer := 3;
  flag_count integer;
begin
  if new.bodega_id is not null then
    select count(*) into flag_count from public.flags where bodega_id = new.bodega_id;
    if flag_count >= threshold then
      update public.bodegas set is_hidden = true where id = new.bodega_id;
    end if;
  elsif new.review_id is not null then
    select count(*) into flag_count from public.flags where review_id = new.review_id;
    if flag_count >= threshold then
      update public.reviews set is_hidden = true where id = new.review_id;
    end if;
  elsif new.photo_id is not null then
    select count(*) into flag_count from public.flags where photo_id = new.photo_id;
    if flag_count >= threshold then
      update public.photos set is_hidden = true where id = new.photo_id;
    end if;
  end if;
  return new;
end;
$$;

create trigger trg_flags_auto_hide
after insert on public.flags
for each row execute function public.handle_flag_insert();

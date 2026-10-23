-- Optional per-photo caption (#107 PR 2). Additive and nullable, so app
-- builds without PR 2 keep decoding `photos` rows (the column is ignored).
-- `char_length` counts characters (code points) of the UTF-8 text, which is
-- what the app counts (`unicodeScalars.count`) for its 140 limit; the app
-- trims and sends NULL for an empty caption, and this check rejects an
-- empty string or anything over 140.
--
-- No RLS change: `photos_insert` checks only `uploaded_by`, and there is
-- still no update policy (caption editing is a TODOS.md follow-up).
--
-- Rollback (loses caption text only):
--   alter table public.photos drop column caption;

alter table public.photos
    add column caption text
    constraint photos_caption_length check (caption is null or char_length(caption) between 1 and 140);

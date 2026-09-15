-- 0028_fix_name_normalization.sql
-- BUG FIX: cng_normalize_name() did not do what it says, and what it does is
-- worse than doing nothing.
--
-- THE DEFECT. 0001 folded Arabic with a single translate() call:
--
--   translate(..., E'ـًٌٍَُِّْأإآىة', E'ااايه')
--
-- `translate(string, from, to)` maps from[i] -> to[i] and DELETES every from[i]
-- beyond the length of `to`. The `from` list is 14 characters and `to` is 5, so
-- the mapping was misaligned end to end:
--
--   * tatweel (ـ) was REPLACED BY alef instead of removed, so `طاليــا`
--     normalized to `طاليااا` — the normalizer INSERTED letters
--   * three diacritics became ا, ا and ي; the rest were deleted
--   * أ, إ, آ, ى and ة fell past the end of `to` and were DELETED rather than
--     folded, so `إبراهيم` -> `براهيم` and `آمال` -> `مال`
--
-- Measured before and after on this schema:
--
--   الماظة        -> الماظ            (should be الماظه)
--   الماظه        -> الماظه
--   إبراهيم       -> براهيم           (should be ابراهيم)
--   آمال          -> مال              (should be امال)
--   طاليــا       -> طاليااا          (should be طاليا)
--
-- WHY IT MATTERS. `normalized_name` is a STORED generated column on `stations`
-- and `units`, and it backs `stations_region_norm_uq` and
-- `units_station_norm_uq` — the constraints that define canonical identity. So
-- `الماظة` and `الماظه` were two different Stations, while unrelated names
-- could collide. It also feeds alias proposal at import. Left in place it would
-- have corrupted canonical Station and Unit identity during the Prompt 21
-- import.
--
-- Nothing in production is affected today: `stations` and `units` are empty and
-- no import has run. This is a latent defect, fixed before it could bite.
--
-- THE FIX. Remove tatweel and diacritics with a regexp, THEN fold letters with
-- an ALIGNED translate() of equal lengths. The behaviour is exactly what 0001's
-- own comment and CLAUDE.md §8 describe; only the implementation changes.

CREATE OR REPLACE FUNCTION cng_normalize_name(p_name text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
  SELECT nullif(
    btrim(
      regexp_replace(
        translate(
          -- Tatweel and the Arabic diacritics carry no identity: remove them.
          regexp_replace(normalize(lower(btrim(p_name)), NFKC), '[ـًٌٍَُِّْٰٓ]', '', 'g'),
          -- Fold orthographic variants. Both sides are SIX characters, so every
          -- mapping is explicit and nothing falls off the end and disappears.
          'أإآٱىة',
          'اااايه'
        ),
        '\s+', ' ', 'g'
      )
    ),
    ''
  );
$$;

COMMENT ON FUNCTION cng_normalize_name(text) IS
  'Deterministic name normalization (NFKC, case, whitespace, Arabic letter '
  'folding: tatweel and diacritics removed; alef variants -> ا, alef maqsura -> '
  'ي, taa marbuta -> ه). Used to propose aliases and detect exact matches only '
  '— never as a runtime resolver.';

-- ---------------------------------------------------------------------------
-- Recompute the stored generated columns
-- ---------------------------------------------------------------------------
-- PostgreSQL does NOT recompute a STORED generated column when the function
-- behind it is replaced — verified on this schema, where the old value stayed
-- until the row was touched. A no-op UPDATE forces it.
--
-- If two rows previously normalized differently and now collide, this raises a
-- unique violation and the migration FAILS. That is deliberate: a collision is
-- a genuine duplicate-identity finding for a human to resolve, and silently
-- merging two Stations is exactly what CLAUDE.md §8 forbids.

UPDATE stations SET station_name = station_name;
UPDATE units    SET unit_name    = unit_name;

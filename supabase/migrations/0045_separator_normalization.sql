-- 0045_separator_normalization.sql
-- Owner-approved (Prompt 21B): normalize whitespace around the literal "/"
-- separator in NAME COMPARISON only.
--
-- WHY. The structural source (`Assets DataBase`) writes compound Station names
-- with spaces around the slash; the asset workbooks write them without. After
-- the existing normalization the two still differ by exactly that whitespace:
--
--   أتــريب / بنــها 1  -> "اتريب / بنها 1"      (structural)
--   أتريب/بنها 1        -> "اتريب/بنها 1"        (asset)
--
-- 0028 already removes tatweel, so the slash spacing is the ONLY residual
-- difference. Measured on the persisted production staging run
-- cdad1e5e-7faa-4f3b-9432-12a720f3dd64: 53 structural identities change
-- comparison form, 78 asset identities gain exactly ONE same-Region candidate
-- covering 281 rows, and there are ZERO identities gaining multiple candidates,
-- ZERO same-Region collisions and ZERO cross-Region collisions.
--
-- SCOPE. This is the approved rule and nothing more:
--
--   "A / B"  =  "A/ B"  =  "A /B"  =  "A/B"   ->   comparison form "A/B"
--
-- It is deliberately NOT generic punctuation normalization. Only whitespace
-- adjacent to the literal "/" is affected; "-", ",", "(" and every other
-- character keep the behaviour they have today. Widening this would start
-- folding names the source distinguishes, which is precisely what data
-- principle #7 ("normalize only when normalization is deterministic") guards.
--
-- WHAT THIS DOES NOT DO. It changes a COMPARISON form. It does not change a
-- canonical or display Station name, does not touch `station_name`,
-- `unit_name`, `source_raw`, `normalized` or any staged row, does not create a
-- Station, Unit, alias or mapping decision, does not resolve an asset, and does
-- not infer a Region or a Unit. Region remains part of identity: two Stations
-- sharing a comparison form in DIFFERENT Regions stay distinct, because
-- `stations_region_norm_uq` is UNIQUE (region_id, normalized_name).
--
-- The owner-confirmed alias `ابنوب` = `ابنوب اسيوط` is untouched and is NOT
-- extended by this rule.

CREATE OR REPLACE FUNCTION cng_normalize_name(p_name text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
  SELECT nullif(
    btrim(
      -- Collapse whitespace AROUND the literal "/" separator, so the four
      -- spacings the sources use compare equal. Applied after the general
      -- whitespace collapse below so it sees a single space at most, and
      -- written as its own step so its scope is obvious and auditable.
      regexp_replace(
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
        ),
        '\s*/\s*', '/', 'g'
      )
    ),
    ''
  );
$$;

COMMENT ON FUNCTION cng_normalize_name(text) IS
  'Deterministic name normalization (NFKC, case, whitespace, Arabic letter '
  'folding: tatweel and diacritics removed; alef variants -> ا, alef maqsura -> '
  'ي, taa marbuta -> ه; whitespace around the literal "/" separator collapsed). '
  'Used to propose aliases and detect exact matches only — never as a runtime '
  'resolver, and never a display name.';

-- ---------------------------------------------------------------------------
-- Recompute the stored generated columns
-- ---------------------------------------------------------------------------
-- PostgreSQL does NOT recompute a STORED generated column when the function
-- behind it is replaced — established in 0028 on this same schema. A no-op
-- UPDATE forces it, and the same rule applies here.
--
-- If two rows previously normalized differently and now collide, this raises a
-- unique violation and the migration FAILS. That is deliberate and is the whole
-- safety property: a collision is a genuine duplicate-identity finding for a
-- human to resolve, and silently merging two Stations is exactly what
-- CLAUDE.md §8 forbids. `stations_region_norm_uq` is Region-scoped, so a
-- collision can only be raised WITHIN one Region — two Regions may legitimately
-- hold the same name.
--
-- Both tables are empty in production today (stations = 0, units = 0), so this
-- recomputes nothing there; it exists so the migration is correct whenever it
-- is applied, not only while the tables happen to be empty.

UPDATE stations SET station_name = station_name;
UPDATE units    SET unit_name    = unit_name;

-- 20261005100000_add_unit_srvs_batch.sql — owner request 2026-10-05: add several relief valves to a Unit at once.
--
-- The Unit window's "Add relief valve" took one serial. cng_admin_add_unit_srvs adds one valve per serial with the same
-- manufacturer / pressure / size / dates, in ONE call, so it is all or nothing: a serial typed twice or already somewhere in
-- the system (cng_srv_serials_refuse_known, which names where) refuses the whole batch and adds nothing. Each valve is added
-- by cng_admin_add_unit_asset itself — the same insert, status and audit row as a single add — so there is one write path.
-- Admin only (cng_require_admin; the actor is derived server-side, never supplied). Additive: no table, column or grant
-- elsewhere is changed.

CREATE OR REPLACE FUNCTION cng_admin_add_unit_srvs(p_unit_id uuid, p jsonb, p_serials text[])
RETURNS uuid[] LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_actor uuid := cng_require_admin();
  v_serials text[];
  v_twice text;
  v_ids uuid[] := '{}';
  s text;
BEGIN
  SELECT array_agg(btrim(x) ORDER BY o) INTO v_serials
    FROM unnest(p_serials) WITH ORDINALITY AS t(x, o) WHERE nullif(btrim(x), '') IS NOT NULL;
  IF v_serials IS NULL THEN RAISE EXCEPTION 'type at least one serial' USING ERRCODE = '22023'; END IF;
  IF cardinality(v_serials) > 200 THEN RAISE EXCEPTION 'at most 200 serials at once' USING ERRCODE = '22023'; END IF;

  SELECT string_agg(k, ', ' ORDER BY k) INTO v_twice
    FROM (SELECT lower(x) AS k FROM unnest(v_serials) x GROUP BY 1 HAVING count(*) > 1) d;
  IF v_twice IS NOT NULL THEN
    RAISE EXCEPTION 'the same serial is typed more than once: %', v_twice USING ERRCODE = '23505';
  END IF;
  -- Every known serial at once, so the message lists them all (the single add re-checks each, harmlessly).
  PERFORM cng_srv_serials_refuse_known(v_serials);

  FOREACH s IN ARRAY v_serials LOOP
    v_ids := v_ids || cng_admin_add_unit_asset('srv', p_unit_id, coalesce(p, '{}'::jsonb) || jsonb_build_object('serial_number', s));
  END LOOP;
  RETURN v_ids;
END; $$;

COMMENT ON FUNCTION cng_admin_add_unit_srvs(uuid, jsonb, text[]) IS
  'Owner request 2026-10-05: add one installed relief valve per serial to a Unit, sharing the other fields; all or nothing. Admin only, audited per valve by cng_admin_add_unit_asset.';
REVOKE ALL ON FUNCTION cng_admin_add_unit_srvs(uuid, jsonb, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_admin_add_unit_srvs(uuid, jsonb, text[]) TO authenticated;

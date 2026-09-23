-- The stale-version refusal in cng_admin_update_record used SQLSTATE 40001 (serialization_failure).
-- PostgREST RETRIES a transaction that fails with 40001, so through the API a stale save looped until the
-- gateway timed out instead of telling the admin. Found by calling the deployed function through the API.
-- PT409 is PostgREST's convention for "respond with HTTP 409": the refusal is immediate and unambiguous.
-- Nothing else in the function changes.

CREATE OR REPLACE FUNCTION cng_admin_update_record(
  p_table text, p_id uuid, p_expected_updated_at timestamptz, p_changes jsonb, p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor uuid := cng_require_admin();
  v_cols text[]; v_bad text[]; v_before jsonb; v_after jsonb; v_set text; v_now timestamptz := clock_timestamp();
BEGIN
  IF p_table IS NULL OR NOT (p_table = ANY (cng_admin_editable_tables())) THEN
    RAISE EXCEPTION 'table % is not editable', p_table USING ERRCODE = '22023';
  END IF;
  IF p_changes IS NULL OR jsonb_typeof(p_changes) <> 'object' OR p_changes = '{}'::jsonb THEN
    RAISE EXCEPTION 'no changes supplied' USING ERRCODE = '22023';
  END IF;
  IF p_expected_updated_at IS NULL THEN
    RAISE EXCEPTION 'the version you edited (updated_at) is required' USING ERRCODE = '22023';
  END IF;

  SELECT array_agg(k) INTO v_bad FROM jsonb_object_keys(p_changes) k
   WHERE k NOT IN (SELECT column_name FROM cng_admin_editable_columns(p_table));
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'these fields cannot be edited: %', array_to_string(v_bad, ', ') USING ERRCODE = '42501';
  END IF;
  SELECT array_agg(k ORDER BY k) INTO v_cols FROM jsonb_object_keys(p_changes) k;

  EXECUTE format('SELECT to_jsonb(t) FROM public.%I t WHERE t.id = $1 FOR UPDATE', p_table) INTO v_before USING p_id;
  IF v_before IS NULL THEN RAISE EXCEPTION 'record not found' USING ERRCODE = '42704'; END IF;
  IF (v_before->>'updated_at')::timestamptz IS DISTINCT FROM p_expected_updated_at THEN
    RAISE EXCEPTION 'this record was changed by someone else; reload it and try again' USING ERRCODE = 'PT409';
  END IF;

  SELECT string_agg(format('%I = r.%I', c, c), ', ') INTO v_set FROM unnest(v_cols) c;
  EXECUTE format(
    'UPDATE public.%I t SET %s, updated_at = $3 FROM jsonb_populate_record(NULL::public.%I, $2) r WHERE t.id = $1 RETURNING to_jsonb(t)',
    p_table, v_set, p_table)
    INTO v_after USING p_id, p_changes, v_now;

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('record_updated', p_table, p_id, v_actor, 'admin_edit',
          format('Admin edited %s: %s. %s', p_table, array_to_string(v_cols, ', '), coalesce(p_reason, '')),
          (SELECT jsonb_object_agg(c, v_before->c) FROM unnest(v_cols) c),
          (SELECT jsonb_object_agg(c, v_after->c) FROM unnest(v_cols) c),
          v_now);
  RETURN v_after;
END;
$$;

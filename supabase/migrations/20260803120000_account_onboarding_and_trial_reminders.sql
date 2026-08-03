CREATE TABLE private.account_onboarding_outbox (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL UNIQUE REFERENCES auth.users (id) ON DELETE CASCADE,
  email text NOT NULL,
  first_name text NOT NULL,
  occurred_at timestamptz NOT NULL,
  attempt_count integer NOT NULL DEFAULT 0,
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  lease_id uuid,
  lease_expires_at timestamptz,
  delivered_at timestamptz,
  last_error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX account_onboarding_outbox_claim_idx
  ON private.account_onboarding_outbox (next_attempt_at, occurred_at)
  WHERE delivered_at IS NULL;

REVOKE ALL ON TABLE private.account_onboarding_outbox
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.handle_account_onboarding_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  confirmation_time timestamptz;
  display_name text;
  first_name text;
BEGIN
  IF COALESCE(NEW.is_anonymous, false)
    OR NULLIF(btrim(NEW.email), '') IS NULL
  THEN
    RETURN NEW;
  END IF;

  confirmation_time := COALESCE(
    NEW.confirmed_at,
    NEW.email_confirmed_at,
    NEW.phone_confirmed_at
  );
  IF confirmation_time IS NULL THEN
    RETURN NEW;
  END IF;

  display_name := COALESCE(
    NULLIF(btrim(NEW.raw_user_meta_data ->> 'given_name'), ''),
    NULLIF(btrim(NEW.raw_user_meta_data ->> 'full_name'), ''),
    NULLIF(btrim(NEW.raw_user_meta_data ->> 'name'), '')
  );
  first_name := COALESCE(
    split_part(regexp_replace(display_name, '\s+', ' ', 'g'), ' ', 1),
    'there'
  );

  INSERT INTO private.account_onboarding_outbox (
    user_id,
    email,
    first_name,
    occurred_at
  )
  VALUES (
    NEW.id,
    btrim(NEW.email),
    first_name,
    confirmation_time
  )
  ON CONFLICT (user_id) DO UPDATE SET
    email = EXCLUDED.email,
    first_name = EXCLUDED.first_name,
    occurred_at = EXCLUDED.occurred_at,
    updated_at = clock_timestamp()
  WHERE private.account_onboarding_outbox.delivered_at IS NULL;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.handle_account_onboarding_user()
  FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA private TO supabase_auth_admin;
GRANT EXECUTE ON FUNCTION private.handle_account_onboarding_user()
  TO supabase_auth_admin;

CREATE TRIGGER on_auth_user_account_onboarding_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION private.handle_account_onboarding_user();

CREATE TRIGGER on_auth_user_account_onboarding_confirmed
  AFTER UPDATE OF confirmed_at, email_confirmed_at, phone_confirmed_at
  ON auth.users
  FOR EACH ROW
  WHEN (
    COALESCE(
      OLD.confirmed_at,
      OLD.email_confirmed_at,
      OLD.phone_confirmed_at
    ) IS NULL
    AND COALESCE(
      NEW.confirmed_at,
      NEW.email_confirmed_at,
      NEW.phone_confirmed_at
    ) IS NOT NULL
  )
  EXECUTE FUNCTION private.handle_account_onboarding_user();

CREATE OR REPLACE FUNCTION public.claim_account_onboarding_events(
  p_lease_id uuid,
  p_limit integer DEFAULT 100,
  p_lease_seconds integer DEFAULT 300
)
RETURNS TABLE (
  id uuid,
  user_id uuid,
  email text,
  first_name text,
  occurred_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  lease_now timestamptz := clock_timestamp();
BEGIN
  IF p_lease_id IS NULL
    OR p_limit IS NULL
    OR p_limit < 1
    OR p_limit > 500
    OR p_lease_seconds IS NULL
    OR p_lease_seconds < 30
    OR p_lease_seconds > 900
  THEN
    RAISE EXCEPTION 'invalid account onboarding lease'
      USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  WITH candidates AS (
    SELECT outbox.id
    FROM private.account_onboarding_outbox AS outbox
    WHERE outbox.delivered_at IS NULL
      AND outbox.next_attempt_at <= lease_now
      AND outbox.attempt_count < 20
      AND (
        outbox.lease_expires_at IS NULL
        OR outbox.lease_expires_at <= lease_now
      )
    ORDER BY outbox.occurred_at, outbox.id
    FOR UPDATE SKIP LOCKED
    LIMIT p_limit
  ), leased AS (
    UPDATE private.account_onboarding_outbox AS outbox
    SET
      attempt_count = outbox.attempt_count + 1,
      lease_id = p_lease_id,
      lease_expires_at = lease_now
        + make_interval(secs => p_lease_seconds),
      updated_at = lease_now
    FROM candidates
    WHERE outbox.id = candidates.id
    RETURNING outbox.*
  )
  SELECT
    leased.id,
    leased.user_id,
    leased.email,
    leased.first_name,
    leased.occurred_at
  FROM leased
  ORDER BY leased.occurred_at, leased.id;
END;
$$;

CREATE OR REPLACE FUNCTION public.complete_account_onboarding_events(
  p_lease_id uuid,
  p_event_ids uuid[]
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  updated_count integer;
BEGIN
  IF p_lease_id IS NULL
    OR p_event_ids IS NULL
    OR cardinality(p_event_ids) < 1
    OR cardinality(p_event_ids) > 500
  THEN
    RAISE EXCEPTION 'invalid account onboarding completion'
      USING ERRCODE = '22023';
  END IF;

  UPDATE private.account_onboarding_outbox AS outbox
  SET
    delivered_at = clock_timestamp(),
    lease_id = NULL,
    lease_expires_at = NULL,
    last_error = NULL,
    updated_at = clock_timestamp()
  WHERE outbox.id = ANY (p_event_ids)
    AND outbox.lease_id = p_lease_id
    AND outbox.delivered_at IS NULL;

  GET DIAGNOSTICS updated_count = ROW_COUNT;
  RETURN updated_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.fail_account_onboarding_events(
  p_lease_id uuid,
  p_event_ids uuid[],
  p_error text
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  updated_count integer;
BEGIN
  IF p_lease_id IS NULL
    OR p_event_ids IS NULL
    OR cardinality(p_event_ids) < 1
    OR cardinality(p_event_ids) > 500
  THEN
    RAISE EXCEPTION 'invalid account onboarding failure'
      USING ERRCODE = '22023';
  END IF;

  UPDATE private.account_onboarding_outbox AS outbox
  SET
    next_attempt_at = clock_timestamp()
      + make_interval(
        secs => LEAST(3600, power(2, LEAST(outbox.attempt_count, 10))::integer)
      ),
    lease_id = NULL,
    lease_expires_at = NULL,
    last_error = left(COALESCE(p_error, 'unknown error'), 2000),
    updated_at = clock_timestamp()
  WHERE outbox.id = ANY (p_event_ids)
    AND outbox.lease_id = p_lease_id
    AND outbox.delivered_at IS NULL;

  GET DIAGNOSTICS updated_count = ROW_COUNT;
  RETURN updated_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_due_trial_reminders(
  p_now timestamptz DEFAULT clock_timestamp(),
  p_window_seconds integer DEFAULT 82800
)
RETURNS TABLE (
  subscription_id text,
  customer_email text,
  customer_name text,
  trial_end bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_now IS NULL
    OR p_window_seconds IS NULL
    OR p_window_seconds < 300
    OR p_window_seconds > 86400
  THEN
    RAISE EXCEPTION 'invalid trial reminder window'
      USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  SELECT
    subscription.id,
    btrim(customer.email),
    customer.name,
    trial.ending_at_epoch
  FROM stripe.subscriptions AS subscription
  JOIN stripe.customers AS customer
    ON customer.id = subscription.customer
  CROSS JOIN LATERAL (
    SELECT CASE
      WHEN jsonb_typeof(subscription.trial_end) = 'number'
      THEN (subscription.trial_end #>> '{}')::bigint
    END AS ending_at_epoch
  ) AS trial
  WHERE subscription.status = 'trialing'
    AND trial.ending_at_epoch IS NOT NULL
    AND NULLIF(btrim(customer.email), '') IS NOT NULL
    AND subscription.default_payment_method IS NULL
    AND customer.invoice_settings ->> 'default_payment_method' IS NULL
    AND customer.default_source IS NULL
    AND to_timestamp(trial.ending_at_epoch) > p_now
    AND to_timestamp(trial.ending_at_epoch) - interval '7 days' <= p_now
    AND to_timestamp(trial.ending_at_epoch) - interval '7 days'
      > p_now - make_interval(secs => p_window_seconds)
  ORDER BY subscription.id;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_account_onboarding_events(
  uuid,
  integer,
  integer
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.complete_account_onboarding_events(uuid, uuid[])
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fail_account_onboarding_events(
  uuid,
  uuid[],
  text
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.list_due_trial_reminders(timestamptz, integer)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.claim_account_onboarding_events(
  uuid,
  integer,
  integer
) TO service_role;
GRANT EXECUTE ON FUNCTION public.complete_account_onboarding_events(uuid, uuid[])
  TO service_role;
GRANT EXECUTE ON FUNCTION public.fail_account_onboarding_events(
  uuid,
  uuid[],
  text
) TO service_role;
GRANT EXECUTE ON FUNCTION public.list_due_trial_reminders(timestamptz, integer)
  TO service_role;

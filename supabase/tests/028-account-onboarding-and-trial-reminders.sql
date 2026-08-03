begin;
select plan(14);

create temporary table account_onboarding_test_users (
  kind text primary key,
  id uuid not null,
  created_at timestamptz not null
);

insert into account_onboarding_test_users (kind, id, created_at)
values
  ('confirmed', gen_random_uuid(), '2026-08-03 10:00:00+00'),
  ('unconfirmed', gen_random_uuid(), '2026-08-03 10:01:00+00'),
  ('anonymous', gen_random_uuid(), '2026-08-03 10:02:00+00');

insert into auth.users (
  id,
  email,
  raw_user_meta_data,
  raw_app_meta_data,
  is_anonymous,
  email_confirmed_at,
  created_at,
  updated_at
)
select
  id,
  kind || '@example.com',
  case
    when kind = 'confirmed' then '{"full_name":"Alex Morgan"}'::jsonb
    when kind = 'unconfirmed' then '{"given_name":"Riley"}'::jsonb
    else '{}'::jsonb
  end,
  jsonb_build_object('provider', 'email'),
  kind = 'anonymous',
  case when kind = 'confirmed' then created_at else null end,
  created_at,
  created_at
from account_onboarding_test_users;

select ok(
  to_regclass('private.account_onboarding_outbox') is not null,
  'Account onboarding outbox is private'
);

select ok(
  not has_table_privilege(
    'anon',
    'private.account_onboarding_outbox',
    'SELECT'
  )
    and not has_table_privilege(
      'authenticated',
      'private.account_onboarding_outbox',
      'SELECT'
    ),
  'Client roles cannot read account onboarding events'
);

select ok(
  has_function_privilege(
    'service_role',
    'public.claim_account_onboarding_events(uuid,integer,integer)',
    'EXECUTE'
  )
    and not has_function_privilege(
      'authenticated',
      'public.claim_account_onboarding_events(uuid,integer,integer)',
      'EXECUTE'
    ),
  'Only service code can claim account onboarding events'
);

select results_eq(
  $$
  select count(*)
  from private.account_onboarding_outbox
  where user_id = (
    select id from account_onboarding_test_users where kind = 'confirmed'
  )
  $$,
  array[1::bigint],
  'Confirmed accounts are queued on insert'
);

select results_eq(
  $$
  select first_name
  from private.account_onboarding_outbox
  where user_id = (
    select id from account_onboarding_test_users where kind = 'confirmed'
  )
  $$,
  array['Alex'::text],
  'The first name is derived from auth metadata'
);

select results_eq(
  $$
  select count(*)
  from private.account_onboarding_outbox
  where user_id = (
    select id from account_onboarding_test_users where kind = 'unconfirmed'
  )
  $$,
  array[0::bigint],
  'Unconfirmed accounts are not queued'
);

select results_eq(
  $$
  select count(*)
  from private.account_onboarding_outbox
  where user_id = (
    select id from account_onboarding_test_users where kind = 'anonymous'
  )
  $$,
  array[0::bigint],
  'Anonymous accounts are not queued'
);

update auth.users
set email_confirmed_at = '2026-08-03 10:05:00+00'
where id = (
  select id from account_onboarding_test_users where kind = 'unconfirmed'
);

select results_eq(
  $$
  select first_name
  from private.account_onboarding_outbox
  where user_id = (
    select id from account_onboarding_test_users where kind = 'unconfirmed'
  )
  $$,
  array['Riley'::text],
  'First confirmation queues an account once'
);

update auth.users
set email_confirmed_at = email_confirmed_at + interval '1 minute'
where id = (
  select id from account_onboarding_test_users where kind = 'unconfirmed'
);

select results_eq(
  $$
  select count(*)
  from private.account_onboarding_outbox
  where user_id = (
    select id from account_onboarding_test_users where kind = 'unconfirmed'
  )
  $$,
  array[1::bigint],
  'Later auth updates do not duplicate onboarding'
);

create temporary table account_onboarding_test_lease (id uuid primary key);
insert into account_onboarding_test_lease values (gen_random_uuid());

select results_eq(
  $$
  select count(*)
  from public.claim_account_onboarding_events(
    (select id from account_onboarding_test_lease),
    100,
    300
  )
  where user_id in (select id from account_onboarding_test_users)
  $$,
  array[2::bigint],
  'Pending onboarding events can be leased'
);

select results_eq(
  $$
  select count(*)
  from private.account_onboarding_outbox
  where lease_id = (select id from account_onboarding_test_lease)
    and first_name in ('Alex', 'Riley')
  $$,
  array[2::bigint],
  'Leased events retain their delivery variables'
);

select results_eq(
  $$
  select public.complete_account_onboarding_events(
    (select id from account_onboarding_test_lease),
    array(
      select id
      from private.account_onboarding_outbox
      where lease_id = (select id from account_onboarding_test_lease)
    )
  )
  $$,
  array[2],
  'Leased onboarding events can be completed'
);

insert into stripe.customers (id, email, name, invoice_settings, default_source)
values
  ('cus_loops_due', 'due@example.com', 'Alex Morgan', '{}'::jsonb, null),
  ('cus_loops_subscription_card', 'card@example.com', null, '{}'::jsonb, null),
  (
    'cus_loops_customer_card',
    'customer-card@example.com',
    null,
    '{"default_payment_method":"pm_customer"}'::jsonb,
    null
  ),
  ('cus_loops_future', 'future@example.com', null, '{}'::jsonb, null);

insert into stripe.subscriptions (
  id,
  customer,
  status,
  trial_end,
  default_payment_method
)
values
  (
    'sub_loops_due',
    'cus_loops_due',
    'trialing',
    to_jsonb(extract(epoch from '2026-08-10 11:00:00+00'::timestamptz)::bigint),
    null
  ),
  (
    'sub_loops_subscription_card',
    'cus_loops_subscription_card',
    'trialing',
    to_jsonb(extract(epoch from '2026-08-10 11:00:00+00'::timestamptz)::bigint),
    'pm_subscription'
  ),
  (
    'sub_loops_customer_card',
    'cus_loops_customer_card',
    'trialing',
    to_jsonb(extract(epoch from '2026-08-10 11:00:00+00'::timestamptz)::bigint),
    null
  ),
  (
    'sub_loops_future',
    'cus_loops_future',
    'trialing',
    to_jsonb(extract(epoch from '2026-08-10 13:00:00+00'::timestamptz)::bigint),
    null
  );

select results_eq(
  $$
  select subscription_id
  from public.list_due_trial_reminders(
    '2026-08-03 12:00:00+00'::timestamptz,
    82800
  )
  where subscription_id like 'sub_loops_%'
  $$,
  array['sub_loops_due'::text],
  'Only due cardless trials are returned'
);

select ok(
  has_function_privilege(
    'service_role',
    'public.list_due_trial_reminders(timestamp with time zone,integer)',
    'EXECUTE'
  )
    and not has_function_privilege(
      'authenticated',
      'public.list_due_trial_reminders(timestamp with time zone,integer)',
      'EXECUTE'
    ),
  'Only service code can list due trial reminders'
);

select * from finish();
rollback;

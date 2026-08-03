import Stripe from "stripe";

import {
  getCustomerId,
  getStripeCustomer,
  getUserIdFromCustomer,
} from "./billing-bridge";
import { env } from "./env";
import { sendLoopsTransactional } from "./loops";
import { buildTrialEndingEmail } from "./trial-email-payload";

const TRIAL_FINAL_REMINDER_TRANSACTIONAL_ID = "cmryjal6600130jvelcx1sol2";

export type TrialEndingEmailReceipt = {
  transactionalId: string;
  trialEnd: number;
  userId: string | null;
};

export async function sendTrialEndingEmail(event: Stripe.Event) {
  if (event.type !== "customer.subscription.trial_will_end") {
    return null;
  }

  if (!env.LOOPS_API_KEY) {
    return null;
  }

  const subscription = event.data.object as Stripe.Subscription;
  const customerId = getCustomerId(subscription);
  if (!customerId) {
    return null;
  }

  const customer = await getStripeCustomer(customerId);
  if (!customer) {
    return null;
  }

  const payload = buildTrialEndingEmail({
    subscription,
    customer,
    now: Date.now(),
  });
  if (!payload) {
    return null;
  }

  await sendLoopsTransactional({
    apiKey: env.LOOPS_API_KEY,
    transactionalId: TRIAL_FINAL_REMINDER_TRANSACTIONAL_ID,
    email: payload.email,
    dataVariables: payload.dataVariables,
    idempotencyKey: event.id,
  });

  return {
    transactionalId: TRIAL_FINAL_REMINDER_TRANSACTIONAL_ID,
    trialEnd: subscription.trial_end!,
    userId: getUserIdFromCustomer(customer),
  } satisfies TrialEndingEmailReceipt;
}

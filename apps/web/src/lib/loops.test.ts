import assert from "node:assert/strict";
import test from "node:test";

import { sendLoopsEvent, sendLoopsTransactional } from "./loops.ts";

test("sends lifecycle events with contact data and idempotency", async () => {
  let request: { url: string; init?: RequestInit } | undefined;

  await sendLoopsEvent({
    apiKey: "loops-key",
    email: "alex@example.com",
    userId: "user-123",
    eventName: "anarlogAccountConfirmed",
    firstName: "Alex",
    idempotencyKey: "account-onboarding:event-123",
    fetcher: async (url, init) => {
      request = { url: String(url), init };
      return Response.json({ success: true });
    },
  });

  assert.equal(request?.url, "https://app.loops.so/api/v1/events/send");
  assert.equal(
    new Headers(request?.init?.headers).get("Idempotency-Key"),
    "account-onboarding:event-123",
  );
  assert.deepEqual(JSON.parse(String(request?.init?.body)), {
    email: "alex@example.com",
    userId: "user-123",
    eventName: "anarlogAccountConfirmed",
    firstName: "Alex",
  });
});

test("sends transactionals without putting idempotency in the body", async () => {
  let request: { init?: RequestInit } | undefined;

  await sendLoopsTransactional({
    apiKey: "loops-key",
    transactionalId: "transactional-123",
    email: "alex@example.com",
    dataVariables: { firstName: "Alex" },
    idempotencyKey: "trial-ending:sub-123:1785945600",
    fetcher: async (_url, init) => {
      request = { init };
      return Response.json({ success: true });
    },
  });

  assert.equal(
    new Headers(request?.init?.headers).get("Idempotency-Key"),
    "trial-ending:sub-123:1785945600",
  );
  assert.deepEqual(JSON.parse(String(request?.init?.body)), {
    transactionalId: "transactional-123",
    email: "alex@example.com",
    dataVariables: { firstName: "Alex" },
  });
});

test("surfaces Loops API errors", async () => {
  await assert.rejects(
    sendLoopsEvent({
      apiKey: "invalid-key",
      email: "alex@example.com",
      userId: "user-123",
      eventName: "anarlogAccountConfirmed",
      firstName: "Alex",
      idempotencyKey: "account-onboarding:event-123",
      fetcher: async () => new Response("invalid token", { status: 401 }),
    }),
    /Loops request failed \(401\): invalid token/,
  );
});

const LOOPS_API_URL = "https://app.loops.so/api/v1";

async function sendLoopsRequest({
  path,
  apiKey,
  idempotencyKey,
  body,
  fetcher,
}: {
  path: "/events/send" | "/transactional";
  apiKey: string;
  idempotencyKey: string;
  body: Record<string, unknown>;
  fetcher: typeof fetch;
}) {
  const response = await fetcher(`${LOOPS_API_URL}${path}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
      "Idempotency-Key": idempotencyKey,
    },
    body: JSON.stringify(body),
  });

  if (!response.ok && response.status !== 409) {
    throw new Error(
      `Loops request failed (${response.status}): ${await response.text()}`,
    );
  }
}

export function sendLoopsEvent({
  apiKey,
  email,
  userId,
  eventName,
  firstName,
  idempotencyKey,
  fetcher = fetch,
}: {
  apiKey: string;
  email: string;
  userId: string;
  eventName: string;
  firstName: string;
  idempotencyKey: string;
  fetcher?: typeof fetch;
}) {
  return sendLoopsRequest({
    path: "/events/send",
    apiKey,
    idempotencyKey,
    body: {
      email,
      userId,
      eventName,
      firstName,
    },
    fetcher,
  });
}

export function sendLoopsTransactional({
  apiKey,
  transactionalId,
  email,
  dataVariables,
  idempotencyKey,
  fetcher = fetch,
}: {
  apiKey: string;
  transactionalId: string;
  email: string;
  dataVariables: Record<string, string | number>;
  idempotencyKey: string;
  fetcher?: typeof fetch;
}) {
  return sendLoopsRequest({
    path: "/transactional",
    apiKey,
    idempotencyKey,
    body: {
      transactionalId,
      email,
      dataVariables,
    },
    fetcher,
  });
}

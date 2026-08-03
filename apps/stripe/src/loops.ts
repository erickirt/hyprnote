const LOOPS_TRANSACTIONAL_URL = "https://app.loops.so/api/v1/transactional";
const MAX_RATE_LIMIT_RETRIES = 3;

type Fetcher = (
  input: RequestInfo | URL,
  init?: RequestInit,
) => Promise<Response>;

function getRetryDelayMs(response: Response) {
  const retryAfterSeconds = Number(response.headers.get("Retry-After") ?? "1");
  if (!Number.isFinite(retryAfterSeconds) || retryAfterSeconds < 0) {
    return 1_000;
  }
  return Math.min(retryAfterSeconds * 1_000, 5_000);
}

export async function sendLoopsTransactional({
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
  fetcher?: Fetcher;
}) {
  const request = {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
      "Idempotency-Key": idempotencyKey,
    },
    body: JSON.stringify({
      transactionalId,
      email,
      dataVariables,
    }),
  } satisfies RequestInit;

  for (let attempt = 0; attempt <= MAX_RATE_LIMIT_RETRIES; attempt += 1) {
    const response = await fetcher(LOOPS_TRANSACTIONAL_URL, request);
    if (response.ok || response.status === 409) {
      return;
    }
    if (response.status === 429 && attempt < MAX_RATE_LIMIT_RETRIES) {
      await new Promise((resolve) =>
        setTimeout(resolve, getRetryDelayMs(response)),
      );
      continue;
    }
    throw new Error(
      `Loops transactional send failed (${response.status}): ${await response.text()}`,
    );
  }
}

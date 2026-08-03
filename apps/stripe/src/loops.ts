const LOOPS_TRANSACTIONAL_URL = "https://app.loops.so/api/v1/transactional";

type Fetcher = (
  input: RequestInfo | URL,
  init?: RequestInit,
) => Promise<Response>;

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
  const response = await fetcher(LOOPS_TRANSACTIONAL_URL, {
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
  });

  if (!response.ok && response.status !== 409) {
    throw new Error(
      `Loops transactional send failed (${response.status}): ${await response.text()}`,
    );
  }
}

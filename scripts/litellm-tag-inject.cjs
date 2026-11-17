// litellm-tag-inject.cjs — stamp x-litellm-tags on openwiki's LiteLLM calls.
//
// LiteLLM 1.93.0 reads `x-litellm-tags` off the request and writes it to
// LiteLLM_SpendLogs.request_tags, so per-repo attribution needs no virtual key
// per repo. openwiki builds its ChatOpenAI with only a baseURL and exposes no
// header knob (dist/agent/index.js:701), so the header goes on the global fetch
// instead of a fork. Loaded via --require from openwiki-pinned.sh.
//
// No-op unless ATLAS_TAG_REPO is set, so interactive `openwiki` is untouched.
// Ceiling: breaks silently if openwiki stops using global fetch -- detected by
// the tag disappearing from /spend/tags.
// Cap for generation. openwiki is the only atlas path that sets no max_tokens,
// so it inherits litellm's injected 65536 default and 1.7% of its calls (12 of
// 697 measured) end at exactly that --
// runaway generations that hold an engine slot for ~40 min and land in the wiki
// truncated. Mean completion is 2171 tokens, so 16384 is 7.5x headroom.
// ponytail: cap only, no finish_reason guard -- openwiki streams, so detecting
// truncation means parsing SSE. Count `completion_tokens == CAP` in
// LiteLLM_SpendLogs by repo tag instead; add the guard if that count is nonzero.
const CAP = 16384;

function capMaxTokens(body) {
  if (typeof body !== 'string') return body;   // streams/Buffers: leave alone
  try {
    const o = JSON.parse(body);
    if (!o || typeof o !== 'object') return body;
    if (!('max_tokens' in o)) o.max_tokens = CAP;
    return JSON.stringify(o);
  } catch {
    return body;                                // not JSON: not ours to touch
  }
}

// The local engine's prefill memory guard (oMLX, jundot/omlx#1885) rejects with a 400 whose
// predicted transient is broken -- 21.67 GB for a min_chunk of 32 tokens, on a
// kv_len of 6437. The rejection is transient: it depends on what is resident at
// that instant. But the private route has no fallback by design
// (openwiki-llm-env.sh, "no cloud path for private code"), so one 400 killed a
// 50-minute `--init` and took its half-written pages with it.
// Retry the rejected call instead of raising anyone's memory ceiling.
// ponytail: fixed backoff, no jitter -- one client, no thundering herd to avoid.
// Only guard rejections retry; every other 400 is a real bad request and must
// surface.
//
// The tail is long on purpose. What clears the rejection is not elapsed time,
// it is whatever holds memory finishing (measured 2026-08-19). With
// scheduler.max_concurrent_requests = 3 and ~9.4 tok/s, one 16384-token
// generation runs ~29 min, so a short backoff only covers "a prefill happened
// to collide with mine". Waiting ~8 min beats losing a 50-minute --init, which
// is what the alternative costs.
const RETRY_MS = process.env.ATLAS_GUARD_RETRY_MS
  ? [1, 2, 3, 4, 5].map(() => Number(process.env.ATLAS_GUARD_RETRY_MS))
  : [5000, 15000, 45000, 120000, 300000];   // ~8 min total

// Two failure modes share this wrapper, and they look nothing alike.
//
// The socket one has no response at all: fetch throws. The proxy's uvicorn runs
// with the default `timeout_keep_alive = 5` (measured 2026-08-19), so an
// idle pooled connection is closed server-side after 5 s. openwiki does minutes
// of local work between generations -- OmniZenit's fatal gap was 235 s -- and
// undici then writes to a socket the server already closed. Nothing reaches the
// proxy, so nothing is logged anywhere, which is exactly the unexplained
// `terminated` error.
//
// Retrying is safe because the request never executed: the failure is on write,
// before the server saw it. ponytail: one retry, no backoff -- a fresh
// connection is all it needs. Ceiling: if a socket ever dies *after* the server
// accepted the request, this re-sends it and pays for one duplicate generation.
// Cheap next to losing the run; revisit if duplicate pages ever show up.
const SOCKET_ERR = /socket|ECONNRESET|EPIPE|other side closed|terminated/i;

async function sendWithSocketRetry(send) {
  try {
    return await send();
  } catch (e) {
    if (!SOCKET_ERR.test(`${e?.code ?? ''} ${e?.message ?? ''} ${e?.cause?.code ?? ''} ${e?.cause?.message ?? ''}`)) throw e;
    process.stderr.write(`litellm-tag-inject: socket died (${e?.cause?.message ?? e?.message}), reconnecting once\n`);
    return send();
  }
}

async function withGuardRetry(send) {
  for (let i = 0; ; i++) {
    const res = await sendWithSocketRetry(send);
    if (res.status !== 400) return res;
    let msg;
    try { msg = await res.clone().text(); } catch { return res; }
    if (!/memory guard/i.test(msg)) return res;
    if (i >= RETRY_MS.length) {
      // Giving up kills the run. Say so -- the silent version of this is what
      // made the first --init failure look like an unexplained `terminated`.
      process.stderr.write(
        `litellm-tag-inject: engine prefill guard still rejecting after ${RETRY_MS.length} retries, giving up\n`);
      return res;
    }
    process.stderr.write(
      `litellm-tag-inject: engine prefill guard rejected, retry ${i + 1}/${RETRY_MS.length} in ${RETRY_MS[i]}ms\n`);
    await new Promise((r) => setTimeout(r, RETRY_MS[i]));
  }
}

const repo = process.env.ATLAS_TAG_REPO;
const base = process.env.OPENAI_COMPATIBLE_BASE_URL;
if (repo && base) {
  const origin = new URL(base).origin;
  const orig = globalThis.fetch;
  globalThis.fetch = function (input, init) {
    const url = typeof input === 'string' ? input : input?.url ?? '';
    // origin has no trailing slash, so a bare startsWith would also match a
    // port that merely begins with the same digits (:4000 vs :40001).
    if (url !== origin && !url.startsWith(origin + '/')) return orig(input, init);
    const headers = new Headers(init?.headers ?? input?.headers);
    headers.set('x-litellm-tags', `repo:${repo},tool:openwiki`);
    const next = { ...init, headers, body: capMaxTokens(init?.body) };
    // Retry needs to re-send the same request; a Request object is single-use,
    // so only the string-url form (the one openwiki uses) is retried.
    if (typeof input !== 'string') return orig(input, next);
    return withGuardRetry(() => orig(input, next));
  };
}

// self-check for litellm-tag-inject.cjs: a throwaway server records what arrives.
const http = require('http');
const assert = require('assert');
const seen = [];
const bodies = [];
// /guard rejects with the real engine guard 400 until the Nth try, then succeeds.
let guardHits = 0, guardRejects = 0, killHits = 0;
// /bad400 always 400s with an ordinary bad request -- must NOT be retried.
let badHits = 0;
const srv = http.createServer((req, res) => {
  seen.push(req.headers['x-litellm-tags'] ?? null);
  let b = '';
  req.on('data', (c) => { b += c; });
  req.on('end', () => {
    bodies.push(b);
    if (req.url.includes('/guard')) {
      if (++guardHits <= guardRejects) {
        res.writeHead(400, { 'content-type': 'application/json' });
        return res.end(JSON.stringify({ error: { message:
          'oMLX prefill memory guard rejected this prompt: Prefill context too large' } }));
      }
      return res.end('{"ok":true}');
    }
    if (req.url.includes('/killonce')) {
      if (++killHits === 1) return req.socket.destroy();   // no response at all
      return res.end('{"ok":true}');
    }
    if (req.url.includes('/bad400')) {
      badHits++;
      res.writeHead(400);
      return res.end('{"error":{"message":"Invalid model name"}}');
    }
    res.end('{}');
  });
});
srv.listen(1842, '127.0.0.1', async () => {
  const base = `http://127.0.0.1:${srv.address().port}/v1`;
  process.env.OPENAI_COMPATIBLE_BASE_URL = base;
  process.env.ATLAS_TAG_REPO = 'atlas';
  process.env.ATLAS_GUARD_RETRY_MS = '5';   // read once, at require time below
  require(require('path').join(__dirname, '..', 'scripts', 'litellm-tag-inject.cjs'));

  await fetch(base + '/chat/completions', { method: 'POST', body: '{"model":"m"}' });
  assert.strictEqual(seen[0], 'repo:atlas,tool:openwiki', 'tag missing on proxy call');
  assert.strictEqual(JSON.parse(bodies[0]).max_tokens, 16384, 'max_tokens cap not injected');

  // an explicit max_tokens wins over the cap
  await fetch(base + '/chat/completions', { method: 'POST', body: '{"max_tokens":7}' });
  assert.strictEqual(JSON.parse(bodies[1]).max_tokens, 7, 'cap overrode an explicit max_tokens');

  // headers already present must survive
  await fetch(base + '/x', { headers: { authorization: 'Bearer k' } });
  assert.strictEqual(seen[2], 'repo:atlas,tool:openwiki');

  // a guard rejection is retried until it clears
  guardRejects = 2; guardHits = 0;
  let r = await fetch(base + '/guard', { method: 'POST', body: '{}' });
  assert.strictEqual(r.status, 200, 'guard rejection was not retried');
  assert.strictEqual(guardHits, 3, `expected 3 attempts, got ${guardHits}`);

  // it gives up rather than looping forever
  guardRejects = 99; guardHits = 0;
  r = await fetch(base + '/guard', { method: 'POST', body: '{}' });
  assert.strictEqual(r.status, 400, 'guard retry never gave up');
  assert.strictEqual(guardHits, 6, `expected 1 try + 5 retries, got ${guardHits}`);

  // an ordinary 400 must surface immediately, not be retried
  badHits = 0;
  r = await fetch(base + '/bad400', { method: 'POST', body: '{}' });
  assert.strictEqual(r.status, 400);
  assert.strictEqual(badHits, 1, 'retried a non-guard 400');

  // a socket the server kills mid-request is retried once on a fresh connection
  killHits = 0;
  r = await fetch(base + '/killonce', { method: 'POST', body: '{}' });
  assert.strictEqual(r.status, 200, 'socket death was not retried');
  assert.strictEqual(killHits, 2, `expected 1 kill + 1 retry, got ${killHits}`);

  // a port that merely shares a prefix with ours must not be tagged
  const ourPort = String(srv.address().port);
  const prefixPortNum = Number(`${ourPort}1`);   // e.g. 1842 -> 18421, still a valid port
  const prefixPort = http.createServer((q, r) => { seen.push(q.headers['x-litellm-tags'] ?? null); r.end(); });
  await new Promise((res) => prefixPort.listen(prefixPortNum, '127.0.0.1', res));
  await fetch(`http://127.0.0.1:${prefixPortNum}/x`);
  assert.strictEqual(seen[seen.length - 1], null, 'tagged a port-prefix origin');
  prefixPort.close();

  // a different origin must not be tagged
  const other = http.createServer((q, r) => { seen.push(q.headers['x-litellm-tags'] ?? null); r.end(); });
  other.listen(0, '127.0.0.1', async () => {
    await fetch(`http://127.0.0.1:${other.address().port}/`);
    assert.strictEqual(seen[seen.length - 1], null, 'tagged a non-proxy origin');
    console.log('ok: tag injected, max_tokens capped, headers preserved, origins scoped, guard 400 retried, non-guard 400 not, dead socket reconnected');
    srv.close(); other.close();
  });
});

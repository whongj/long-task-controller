import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout } from 'node:timers/promises';
import { test } from 'node:test';
import { authorize, claim, finish, initialize, openLedger, requestStop, review } from '../controller.mjs';
import { codex, fixture, supervise } from '../host.mjs';

const plan = (workspace) => ({
  goal: 'Verify two local fixtures', workspace,
  steps: ['first', 'second'].map((id) => ({
    id, action: 'local-verification', acceptance: 'Fixture returns a pass event', message: 'Verify local fixture',
  })),
});

function setup(t, adapter = fixture, customize = () => {}) {
  const workspace = mkdtempSync(join(tmpdir(), 'ltc-test-'));
  const path = join(workspace, 'run.db');
  const ledger = openLedger(path);
  const runPlan = plan(workspace);
  customize(runPlan);
  initialize(ledger, runPlan, adapter.id);
  t.after(() => { ledger.close(); rmSync(workspace, { recursive: true, force: true }); });
  return { ledger, workspace, path };
}

test('unattended requires finite operator authorization; Codex remains foreground only', (t) => {
  const { ledger } = setup(t);
  assert.throws(() => claim(ledger, fixture, true), /authorization/);
  assert.throws(() => authorize(ledger, 1, Infinity, fixture), /finite/);
  assert.throws(() => authorize(ledger, 1, 1, codex), /unavailable/);
  const actual = setup(t, codex).ledger;
  assert.throws(() => authorize(actual, 1, 1, codex), /unavailable/);
});

test('deadline cancels in-flight owned process and stops dispatch across reopen', async (t) => {
  const { ledger, path } = setup(t, fixture, (p) => { p.steps[0].delayMs = 60_000; });
  authorize(ledger, 1, 1, fixture);
  const ticket = claim(ledger, fixture, true);
  const result = await supervise(ticket, fixture, () => ledger.get().inFlight.stopRequested);
  assert.equal(result.reason, 'DEADLINE');
  assert.equal(result.cancellation, 'CONFIRMED_OWNED_GROUP_EXITED');
  assert.equal(result.outcome, 'UNKNOWN');
  finish(ledger, ticket, result);
  const reopened = openLedger(path);
  try {
    assert.throws(() => claim(reopened, fixture, true), /cannot dispatch/);
    assert.throws(() => review(reopened, 1, 'resume', 'checked'), /stale/);
    review(reopened, 4, 'resume', 'Inspected workspace and verified prior execution stopped');
    assert.throws(() => authorize(reopened, 1, 10, fixture), /stale/);
    assert.throws(() => claim(reopened, fixture, true), /authorization/);
    assert.equal(reopened.receipts().filter((r) => r.type === 'DISPATCH_RESERVED').length, 1);
  } finally { reopened.close(); }
});

test('expired idle grant cannot be used after process restart', async (t) => {
  const { ledger, path } = setup(t);
  authorize(ledger, 1, 1, fixture);
  await setTimeout(1050);
  const reopened = openLedger(path);
  try {
    assert.equal(claim(reopened, fixture, true), null);
    assert.equal(reopened.get().pause.reason, 'DEADLINE');
    assert.equal(reopened.receipts().filter((r) => r.type === 'DISPATCH_RESERVED').length, 0);
  } finally { reopened.close(); }
});

test('concurrent processes reserve once; operator can stop the active worker', async (t) => {
  const { ledger, path } = setup(t, fixture, (p) => { p.steps[0].delayMs = 6000; });
  authorize(ledger, 1, 15, fixture);
  const launch = () => {
    const child = spawn(process.execPath, [new URL('../cli.mjs', import.meta.url).pathname, 'run', path], { stdio: 'ignore' });
    return new Promise((resolve) => child.once('close', resolve));
  };
  const a = launch();
  const b = launch();
  for (let i = 0; i < 200 && ledger.get().status !== 'RUNNING'; i++) await setTimeout(10);
  assert.equal(ledger.get().status, 'RUNNING');
  requestStop(ledger);
  assert.deepEqual((await Promise.all([a, b])).sort(), [0, 1]);
  assert.equal(ledger.get().pause.reason, 'HUMAN_STOP');
  assert.equal(ledger.receipts().filter((r) => r.type === 'DISPATCH_RESERVED').length, 1);
});

test('safety event stops a mock host with zero retries and cannot be resumed in the same run', async (t) => {
  const { ledger } = setup(t);
  const mock = { ...fixture, command: () => [process.execPath, ['-e',
    'console.log(JSON.stringify({type:"error",error:{code:"cyber_safety_warning"}})); setInterval(() => {}, 1000)']] };
  authorize(ledger, 1, 10, mock);
  const ticket = claim(ledger, mock, true);
  const result = await supervise(ticket, mock, () => false);
  assert.equal(result.reason, 'PLATFORM_SAFETY');
  assert.equal(result.cancellation, 'CONFIRMED_OWNED_GROUP_EXITED');
  finish(ledger, ticket, result);
  assert.throws(() => claim(ledger, mock, true), /cannot dispatch/);
  assert.throws(() => review(ledger, 4, 'resume', 'reviewed'), /unavailable/);
  assert.equal(ledger.receipts().filter((r) => r.type === 'DISPATCH_RESERVED').length, 1);
});

test('an unconfirmed outcome stays unknown; review and a new grant are needed', (t) => {
  const { ledger } = setup(t);
  const ticket = claim(ledger, fixture, false);
  finish(ledger, ticket, { reason: 'HUMAN_STOP', outcome: 'UNKNOWN', cancellation: 'UNCONFIRMED' });
  assert.equal(ledger.get().pause.cancellation, 'UNCONFIRMED');
  assert.equal(ledger.get().cursor, 0);
  assert.throws(() => review(ledger, 3, 'resume', ''), /reference/);
  review(ledger, 3, 'resume', 'Operator confirmed the old worker exited and inspected effects');
  authorize(ledger, 4, 20, fixture);
  assert.equal(claim(ledger, fixture, true).step.id, 'first');
});

test('each accepted step needs evidence and overall results wait for review', async (t) => {
  const { ledger } = setup(t);
  authorize(ledger, 1, 10, fixture);
  for (let i = 0; i < 2; i++) {
    const ticket = claim(ledger, fixture, true);
    finish(ledger, ticket, await supervise(ticket, fixture, () => false));
  }
  assert.equal(ledger.get().status, 'READY_FOR_REVIEW');
  assert.equal(ledger.get().evidence.length, 2);
  review(ledger, 6, 'close', 'Fixture evidence checked');
  assert.equal(ledger.get().status, 'CLOSED');
});

test('actions reserved for HITL pause before dispatch and accept human evidence', (t) => {
  const { ledger } = setup(t, fixture, (p) => { p.steps[0].action = 'local-candidate'; });
  authorize(ledger, 1, 10, fixture);
  assert.equal(claim(ledger, fixture, true), null);
  assert.equal(ledger.get().pause.outcome, 'NOT_STARTED');
  review(ledger, 3, 'accept', 'Human verified the candidate independently');
  assert.equal(ledger.get().evidence[0].kind, 'HUMAN_REVIEW');
  assert.equal(ledger.get().authorizationId, null);
});

test('headless Codex step rejects before reserving work', async (t) => {
  const { ledger, path } = setup(t, codex);
  const child = spawn(process.execPath, [new URL('../cli.mjs', import.meta.url).pathname, 'step', path, '2'], { stdio: 'ignore' });
  assert.equal(await new Promise((resolve) => child.once('close', resolve)), 1);
  assert.equal(ledger.get().status, 'READY');
  assert.equal(ledger.receipts().length, 1);
});

test('watchdog uses a fail-fast read when another writer locks the ledger', async (t) => {
  const { ledger, path } = setup(t, fixture, (p) => { p.steps[0].delayMs = 10000; });
  authorize(ledger, 1, 4, fixture);
  const ticket = claim(ledger, fixture, true);
  const worker = supervise(ticket, fixture, () => ledger.stopRequested(ticket.id));
  const { DatabaseSync } = await import('node:sqlite');
  const blocker = new DatabaseSync(path);
  blocker.exec('BEGIN EXCLUSIVE');
  try {
    const result = await worker;
    assert.equal(result.reason, 'LEDGER_UNAVAILABLE');
    assert.equal(result.cancellation, 'CONFIRMED_OWNED_GROUP_EXITED');
  } finally {
    blocker.exec('ROLLBACK');
    blocker.close();
  }
});

test('an original monotonic cap wins over a later wall-clock estimate', async (t) => {
  const { ledger } = setup(t, fixture, (p) => { p.steps[0].delayMs = 10000; });
  authorize(ledger, 1, 10, fixture);
  const ticket = claim(ledger, fixture, true);
  const result = await supervise(ticket, fixture, () => false, performance.now() + 150);
  assert.equal(result.reason, 'DEADLINE');
  assert.equal(result.cancellation, 'CONFIRMED_OWNED_GROUP_EXITED');
});

test('a safety event during cancellation makes the pause non-resumable', async (t) => {
  const { ledger } = setup(t);
  const mock = { ...fixture, command: () => [process.execPath, ['-e',
    'process.on("SIGTERM",()=>{console.log(JSON.stringify({type:"safety.warning"}));process.exit(0)});setInterval(()=>{},1000)']] };
  authorize(ledger, 1, 1, mock);
  const ticket = claim(ledger, mock, true);
  const result = await supervise(ticket, mock, () => false);
  assert.equal(result.reason, 'PLATFORM_SAFETY');
  finish(ledger, ticket, result);
  assert.throws(() => review(ledger, 4, 'resume', 'reviewed'), /unavailable/);
});

test('terminal suspend requests a stop while the watchdog is still running', { timeout: 5000 }, async (t) => {
  const { workspace } = setup(t);
  const moduleUrl = new URL('../host.mjs', import.meta.url).href;
  const code = `
    import { supervise, fixture } from ${JSON.stringify(moduleUrl)};
    const run = supervise({
      workspace: ${JSON.stringify(workspace)}, step: { delayMs: 3000 }, deadline: Date.now() + 3500,
    }, fixture, () => false);
    process.send('ready');
    process.send(await run);
  `;
  const child = spawn(process.execPath, ['--input-type=module', '-e', code], {
    stdio: ['ignore', 'ignore', 'ignore', 'ipc'],
  });
  const exited = once(child, 'close');
  t.after(() => { if (child.exitCode === null) child.kill('SIGTERM'); });
  const [ready] = await once(child, 'message');
  assert.equal(ready, 'ready');
  const outcome = once(child, 'message');
  assert.equal(child.kill('SIGTSTP'), true);
  const [result] = await outcome;
  assert.equal(result.reason, 'HUMAN_STOP');
  assert.equal(result.cancellation, 'CONFIRMED_OWNED_GROUP_EXITED');
  assert.deepEqual(await exited, [0, null]);
});

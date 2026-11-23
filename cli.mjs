#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { readFileSync, realpathSync, statSync } from 'node:fs';
import { performance } from 'node:perf_hooks';
import { authorize, claim, finish, initialize, openLedger, requestStop, review } from './controller.mjs';
import { codex, fixture, supervise } from './host.mjs';

const [command, dbPath, ...args] = process.argv.slice(2);
const counts = { init: 2, status: 0, authorize: 2, run: 0, step: [0, 1], stop: 0, review: 3 };
const adapters = new Map([[codex.id, codex], [fixture.id, fixture]]);
function requireForeground() {
  if (!process.stdin.isTTY || !process.stdout.isTTY) throw new Error('The Codex adapter requires a foreground terminal');
  const [group, foreground] = execFileSync('/bin/ps', ['-o', 'pgid=', '-o', 'tpgid=', '-p', String(process.pid)], {
    encoding: 'utf8', timeout: 1000, stdio: ['ignore', 'pipe', 'ignore'],
  }).trim().split(/\s+/).map(Number);
  if (!(group > 0 && group === foreground)) throw new Error('The Codex adapter cannot run in a background job');
}
let ledger;
try {
  if (!dbPath || !Object.hasOwn(counts, command) || ![counts[command]].flat().includes(args.length)) {
    throw new Error('Usage: node cli.mjs <init|status|authorize|run|step|stop|review> <ledger.db> [arguments]. See README.md.');
  }
  ledger = openLedger(dbPath);
  if (command === 'init') {
    const plan = JSON.parse(readFileSync(args[0], 'utf8'));
    plan.workspace = realpathSync(plan.workspace);
    if (!statSync(plan.workspace).isDirectory() || !adapters.has(args[1])) throw new Error('Invalid workspace or adapter');
    initialize(ledger, plan, args[1]);
  } else {
    const state = ledger.get();
    const adapter = adapters.get(state.adapter);
    if (!adapter) throw new Error('Unknown adapter');
    if (command === 'authorize') authorize(ledger, Number(args[0]), Number(args[1]), adapter);
    if (command === 'stop') requestStop(ledger);
    if (command === 'review') review(ledger, Number(args[0]), args[1], args[2]);
    if (command === 'run' || command === 'step') {
      const foregroundSeconds = args.length ? Number(args[0]) : null;
      if (foregroundSeconds !== null && (!Number.isSafeInteger(foregroundSeconds) || foregroundSeconds <= 0 ||
          foregroundSeconds > Math.floor((8.64e15 - Date.now()) / 1000))) throw new Error('Invalid foreground timeout');
      if (command === 'step' && adapter.id === 'codex') {
        if (foregroundSeconds === null) throw new Error('Specify a finite foreground timeout for Codex');
        requireForeground();
      }
      const duration = state.deadline === null ? Infinity : Math.max(0, state.deadline - Date.now());
      const monotonicDeadline = performance.now() + duration;
      do {
        const ticket = claim(ledger, adapter, command === 'run', () => performance.now() >= monotonicDeadline);
        if (!ticket) break;
        if (foregroundSeconds !== null) ticket.deadline = Date.now() + foregroundSeconds * 1000;
        const result = await supervise(ticket, adapter, () => ledger.stopRequested(ticket.id), monotonicDeadline);
        if (finish(ledger, ticket, result).status !== 'READY') break;
      } while (command === 'run');
    }
  }
  const { state: { plan, ...state }, receipts } = ledger.snapshot();
  const operatorView = { goal: plan.goal, nextStep: plan.steps[state.cursor]?.id ?? null, ...state };
  console.log(JSON.stringify({ state: operatorView, receiptSequence: receipts.length, receipts }, null, 2));
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
} finally {
  ledger?.close();
}

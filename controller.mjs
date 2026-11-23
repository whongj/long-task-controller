import { createHash, randomUUID } from 'node:crypto';
import { closeSync, lstatSync, openSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';

const supervisorId = randomUUID();

export const digest = (value) => createHash('sha256').update(JSON.stringify(value)).digest('hex');

export function validatePlan(plan) {
  if (!plan || typeof plan.goal !== 'string' || !plan.goal.trim() ||
      typeof plan.workspace !== 'string' || !plan.workspace ||
      !Array.isArray(plan.steps) || !plan.steps.length) throw new Error('Invalid plan');
  const steps = plan.steps.map(({ id, action, acceptance, message, delayMs }) => {
    if (typeof id !== 'string' || !/^[a-zA-Z0-9_-]{1,60}$/.test(id) ||
        !['local-verification', 'local-candidate'].includes(action) ||
        typeof acceptance !== 'string' || !acceptance.trim() ||
        typeof message !== 'string' || !message.trim() ||
        !Number.isSafeInteger(delayMs ?? 0) || (delayMs ?? 0) < 0) throw new Error('Invalid step');
    return { id, action, acceptance, message, delayMs: delayMs ?? 0 };
  });
  if (new Set(steps.map(({ id }) => id)).size !== steps.length) throw new Error('Duplicate step ID');
  return { goal: plan.goal, workspace: plan.workspace, steps };
}

export function openLedger(path) {
  try { closeSync(openSync(path, 'wx', 0o600)); }
  catch (error) {
    if (error.code !== 'EEXIST' || !lstatSync(path).isFile()) throw error;
  }
  const db = new DatabaseSync(path);
  db.exec(`
    PRAGMA busy_timeout = 5000;
    PRAGMA synchronous = FULL;
    CREATE TABLE IF NOT EXISTS state (slot INTEGER PRIMARY KEY CHECK (slot = 1), body TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS receipt (seq INTEGER PRIMARY KEY, body TEXT NOT NULL);
  `);
  const reader = new DatabaseSync(path, { readOnly: true });
  reader.exec('PRAGMA busy_timeout = 0');
  const get = (connection = db) => {
    const row = connection.prepare('SELECT body FROM state WHERE slot=1').get();
    if (!row) throw new Error('Initialize the run first');
    const state = JSON.parse(row.body);
    if (digest(state.plan) !== state.planSha256) throw new Error('Plan digest mismatch');
    return state;
  };
  const write = (state, type, detail = {}) => {
    db.prepare('INSERT OR REPLACE INTO state VALUES (1, ?)').run(JSON.stringify(state));
    db.prepare('INSERT INTO receipt (body) VALUES (?)').run(JSON.stringify({
      type, time: new Date().toISOString(), planSha256: state.planSha256, ...detail,
    }));
    return state;
  };
  const transaction = (fn) => {
    db.exec('BEGIN IMMEDIATE');
    try {
      const value = fn();
      db.exec('COMMIT');
      return value;
    } catch (error) {
      db.exec('ROLLBACK');
      throw error;
    }
  };
  const receipts = () => db.prepare('SELECT body FROM receipt ORDER BY seq').all().map(({ body }) => JSON.parse(body));
  return {
    get, write, transaction, receipts,
    close() { reader.close(); db.close(); },
    exists: () => !!db.prepare('SELECT slot FROM state WHERE slot=1').get(),
    stopRequested(id) {
      const flight = get(reader).inFlight;
      return flight?.id !== id || flight.stopRequested;
    },
    snapshot() {
      db.exec('BEGIN');
      try { return { state: get(), receipts: receipts() }; }
      finally { db.exec('COMMIT'); }
    },
  };
}

export function initialize(ledger, plan, adapter) {
  return ledger.transaction(() => {
    if (ledger.exists()) throw new Error('Run already initialized');
    const fixed = validatePlan(plan);
    return ledger.write({
      plan: fixed, planSha256: digest(fixed), adapter, status: 'READY', cursor: 0,
      deadline: null, authorizationId: null, supervisorId: null, inFlight: null, pause: null, evidence: [],
    }, 'INITIALIZED');
  });
}

export function authorize(ledger, expectedReceipt, seconds, adapter) {
  return ledger.transaction(() => {
    const state = ledger.get();
    if (!(adapter.unattended && state.adapter === adapter.id)) {
      throw new Error('Unattended execution is unavailable for this host');
    }
    if (!Number.isSafeInteger(seconds) || seconds <= 0) throw new Error('Specify a finite positive duration in seconds');
    if (state.status !== 'READY' || state.authorizationId ||
        state.pause || expectedReceipt !== ledger.receipts().length) {
      throw new Error('Authorization is stale or the run is not ready');
    }
    const deadline = Date.now() + seconds * 1000;
    if (!Number.isSafeInteger(deadline) || deadline > 8.64e15) throw new Error('Deadline is out of range');
    state.deadline = deadline;
    state.authorizationId = randomUUID();
    return ledger.write(state, 'AUTHORIZED', { deadline, authorizationId: state.authorizationId });
  });
}

function pause(ledger, state, reason, detail = {}) {
  state.status = 'WAITING_HUMAN';
  state.pause = { reason, ...detail };
  state.deadline = null;
  state.authorizationId = null;
  state.supervisorId = null;
  state.inFlight = null;
  return ledger.write(state, 'PAUSED', state.pause);
}

export function claim(ledger, adapter, unattended, expired = () => false) {
  return ledger.transaction(() => {
    const state = ledger.get();
    if (state.adapter !== adapter.id || state.status !== 'READY') throw new Error('Run cannot dispatch');
    if (state.deadline !== null && (Date.now() >= state.deadline || expired())) {
      pause(ledger, state, 'DEADLINE');
      return null;
    }
    if (unattended && !(adapter.unattended && state.authorizationId)) {
      throw new Error('Explicit current authorization is required');
    }
    if (unattended && state.supervisorId && state.supervisorId !== supervisorId) {
      throw new Error('The previous supervisor owns this authorization; stop and review before restarting');
    }
    if (!unattended && state.authorizationId) throw new Error('End the active authorization before an interactive step');
    const step = state.plan.steps[state.cursor];
    if (step.action !== 'local-verification') {
      pause(ledger, state, 'REVIEW_REQUIRED', { stepId: step.id, outcome: 'NOT_STARTED' });
      return null;
    }
    const ticket = { id: randomUUID(), ownerPid: process.pid, step, deadline: state.deadline };
    if (unattended) state.supervisorId = supervisorId;
    state.inFlight = { id: ticket.id, ownerPid: ticket.ownerPid, stepId: step.id, stopRequested: false };
    state.status = 'RUNNING';
    ledger.write(state, 'DISPATCH_RESERVED', { id: ticket.id, stepId: step.id });
    return { ...ticket, workspace: state.plan.workspace };
  });
}

export function requestStop(ledger) {
  return ledger.transaction(() => {
    const state = ledger.get();
    if (state.status === 'RUNNING' && !state.inFlight.stopRequested) {
      state.inFlight.stopRequested = true;
      return ledger.write(state, 'STOP_REQUESTED', { id: state.inFlight.id });
    }
    if (state.status === 'READY') return pause(ledger, state, 'HUMAN_STOP');
    return state;
  });
}

export function finish(ledger, ticket, result) {
  return ledger.transaction(() => {
    const state = ledger.get();
    if (state.inFlight?.id !== ticket.id) throw new Error('Dispatch reservation has changed');
    let reason = result.reason;
    if (!reason && state.inFlight.stopRequested) reason = 'HUMAN_STOP';
    if (!reason && state.deadline !== null && Date.now() >= state.deadline) reason = 'DEADLINE';
    if (reason || !result.evidence?.passed) {
      return pause(ledger, state, reason || 'MISSING_EVIDENCE', {
        stepId: ticket.step.id, cancellation: result.cancellation ?? 'NOT_REQUESTED',
        outcome: result.outcome ?? 'UNKNOWN', diagnostic: result.diagnostic ?? null,
      });
    }
    state.inFlight = null;
    state.evidence.push({ stepId: ticket.step.id, ...result.evidence });
    state.cursor++;
    state.status = state.cursor === state.plan.steps.length ? 'READY_FOR_REVIEW' : 'READY';
    if (state.status === 'READY_FOR_REVIEW') {
      state.deadline = null;
      state.authorizationId = null;
      state.supervisorId = null;
    }
    return ledger.write(state, 'EVIDENCE_ACCEPTED', { stepId: ticket.step.id, evidence: result.evidence });
  });
}

function ownerGone(pid) {
  try {
    process.kill(pid, 0);
    return false;
  } catch (error) {
    return error.code === 'ESRCH';
  }
}

export function review(ledger, seq, decision, evidence) {
  return ledger.transaction(() => {
    const state = ledger.get();
    if (seq !== ledger.receipts().length) throw new Error('Review is stale; inspect the latest receipts');
    if (typeof evidence !== 'string' || !evidence.trim()) throw new Error('A review evidence reference is required');
    if (state.status === 'RUNNING' && ownerGone(state.inFlight.ownerPid) && decision === 'reconcile') {
      return pause(ledger, state, 'SUPERVISOR_LOST', { stepId: state.inFlight.stepId, outcome: 'UNKNOWN', reconciliationRef: evidence });
    }
    if (decision === 'accept' && state.status === 'WAITING_HUMAN' &&
        state.pause.reason === 'REVIEW_REQUIRED' &&
        ['PROCESS_EXITED', 'NOT_STARTED'].includes(state.pause.outcome)) {
      state.evidence.push({ stepId: state.plan.steps[state.cursor].id, passed: true, kind: 'HUMAN_REVIEW', ref: evidence });
      state.cursor++;
      state.status = state.cursor === state.plan.steps.length ? 'READY_FOR_REVIEW' : 'READY';
      state.pause = null;
    } else if (decision === 'close' && ['WAITING_HUMAN', 'READY_FOR_REVIEW'].includes(state.status)) {
      state.status = 'CLOSED';
    } else if (decision === 'resume' && state.status === 'WAITING_HUMAN' &&
      ['DEADLINE', 'HUMAN_STOP', 'SUPERVISOR_LOST'].includes(state.pause.reason)) {
      // The operator attests that the old execution is stopped and its effects were checked.
      state.status = 'READY';
      state.pause = null;
    } else {
      throw new Error('This decision is unavailable for the current reason');
    }
    return ledger.write(state, 'HUMAN_DECISION', { decision, evidence });
  });
}

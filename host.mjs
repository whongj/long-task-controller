import { spawn } from 'node:child_process';
import { performance } from 'node:perf_hooks';

const fixtureCode = `
const delay = Number(process.argv[1]);
setTimeout(() => process.stdout.write('{"type":"fixture.pass"}\\n'), delay);
`;

export const fixture = {
  id: 'fixture', unattended: true,
  command: ({ step }) => [process.execPath, ['-e', fixtureCode, String(step.delayMs)]],
  observe: (event) => event.type === 'fixture.pass' ? { passed: true, kind: 'SYNTHETIC' } : undefined,
};

export const codex = {
  id: 'codex', unattended: false,
  command: ({ step }) => ['codex', [
    '-a', 'never', 'exec', '--json', '--ephemeral', '--sandbox', 'read-only',
    '--ignore-user-config', '--skip-git-repo-check', '--',
    `Perform only this authorized local, read-only verification. No external requests or writes. ${step.message}
Use the status marker LOCAL_VERIFICATION_COMPLETE only after finding direct evidence. Acceptance: ${step.acceptance}`,
  ]],
  observe(event, observed) {
    if (event.type === 'item.completed' && event.item?.type === 'agent_message') {
      observed.agentReported = event.item.text?.includes('LOCAL_VERIFICATION_COMPLETE') === true;
    }
    if (event.type === 'turn.completed') observed.finished = true;
    // The CLI can announce transport recovery while a foreground operator is still waiting.
    // Only the known loopback/network failure message is treated as a transport notice.
    if (event.type === 'error' && /^Reconnecting\.\.\. \d+\/\d+ \(stream disconnected before completion: Connection refused \(os error \d+\)\)$/.test(event.message ?? '')) {
      return undefined;
    }
    if (!event.type || ['error', 'turn.failed'].includes(event.type)) return { reason: 'HOST_SIGNAL', diagnostic: 'ERROR_EVENT' };
    return undefined;
  },
  finalize: ({ agentReported, finished }) => ({
    reason: finished && agentReported ? 'REVIEW_REQUIRED' : 'MISSING_EVIDENCE',
    outcome: finished ? 'PROCESS_EXITED' : 'UNKNOWN', diagnostic: 'INDEPENDENT_VERIFICATION_REQUIRED',
  }),
};

const platformCodes = new Set(['policy_violation', 'safety_violation', 'content_policy_violation', 'cyber_safety_warning']);

export function safetyReason(event) {
  const signals = [event.type, event.code, event.error?.code, event.error?.type, event.item?.type, event.status];
  return signals.some((value) => platformCodes.has(value) ||
    ['safety.warning', 'safety.refusal', 'policy.denied', 'refusal'].includes(value));
}

function groupGone(pid) {
  if (!pid) return false;
  try {
    process.kill(-pid, 0);
    return false;
  } catch (error) {
    return error.code === 'ESRCH';
  }
}

export function supervise(ticket, adapter, shouldStop, monotonicDeadline = Infinity) {
  if (!['darwin', 'linux'].includes(process.platform)) throw new Error('This runner requires macOS or Linux');
  if (ticket.deadline !== null && Date.now() >= ticket.deadline) {
    return Promise.resolve({ reason: 'DEADLINE', outcome: 'NOT_STARTED' });
  }
  const wallLimit = ticket.deadline === null ? Infinity : performance.now() + Math.max(0, ticket.deadline - Date.now());
  const timeLimit = Math.min(monotonicDeadline, wallLimit);
  const [binary, args] = adapter.command(ticket);
  if (performance.now() >= timeLimit || (ticket.deadline !== null && Date.now() >= ticket.deadline)) {
    return Promise.resolve({ reason: 'DEADLINE', outcome: 'NOT_STARTED' });
  }
  try {
    if (shouldStop()) return Promise.resolve({ reason: 'HUMAN_STOP', outcome: 'NOT_STARTED' });
  } catch {
    return Promise.resolve({ reason: 'LEDGER_UNAVAILABLE', outcome: 'NOT_STARTED' });
  }

  return new Promise((resolve) => {
    let child;
    const observed = {};
    let output = '';
    let evidence;
    let reason;
    let diagnostic;
    let stoppingAt;
    let outputBytes = 0;
    const signal = (name) => {
      if (!child.pid) return;
      try { process.kill(-child.pid, name); } catch { /* group status is checked separately */ }
    };
    const checkReason = () => {
      if (performance.now() >= timeLimit || (ticket.deadline !== null && Date.now() >= ticket.deadline)) return 'DEADLINE';
      try { return shouldStop() ? 'HUMAN_STOP' : null; }
      catch { return 'LEDGER_UNAVAILABLE'; }
    };
    const stop = (why, code) => {
      if (reason) {
        if (why === 'PLATFORM_SAFETY') { reason = why; diagnostic = code; }
        return;
      }
      reason = why;
      diagnostic = code;
      stoppingAt = performance.now();
      signal('SIGTERM');
    };
    const operatorSignals = ['SIGINT', 'SIGTERM', 'SIGTSTP'];
    const onInterrupt = () => stop('HUMAN_STOP');
    const complete = (result) => {
      clearInterval(watchdog);
      for (const name of operatorSignals) process.removeListener(name, onInterrupt);
      child.stdout.destroy();
      child.stderr.destroy();
      child.unref();
      resolve(result);
    };
    const stopped = () => ({
      reason, diagnostic, cancellation: groupGone(child.pid) ? 'CONFIRMED_OWNED_GROUP_EXITED' : 'UNCONFIRMED',
      outcome: 'UNKNOWN',
    });
    for (const name of operatorSignals) process.on(name, onInterrupt);
    try {
      child = spawn(binary, args, { cwd: ticket.workspace, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
    } catch {
      for (const name of operatorSignals) process.removeListener(name, onInterrupt);
      resolve({ reason: 'HOST_SIGNAL', diagnostic: 'START_ERROR', outcome: 'UNKNOWN' });
      return;
    }
    const watchdog = setInterval(() => {
      const why = checkReason();
      if (why) stop(why);
      if (!reason) return;
      const elapsed = performance.now() - stoppingAt;
      if (elapsed >= 250 && !groupGone(child.pid)) signal('SIGKILL');
      if (elapsed >= 1500) complete(stopped());
    }, 25);

    function observeLine(line) {
      if (!line.trim()) return;
      try {
        const event = JSON.parse(line);
        if (!event || typeof event.type !== 'string') throw new Error('Invalid event envelope');
        if (safetyReason(event)) return stop('PLATFORM_SAFETY', 'SAFETY_EVENT');
        if (reason) return;
        const observation = adapter.observe(event, observed);
        if (observation?.reason) stop(observation.reason, observation.diagnostic);
        if (observation?.passed) evidence = observation;
      } catch {
        stop('HOST_SIGNAL', 'INVALID_EVENT');
      }
    }
    const countBytes = (length) => {
      outputBytes += length;
      if (outputBytes > 1024 * 1024) stop('HOST_SIGNAL', 'OUTPUT_LIMIT');
    };
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      countBytes(Buffer.byteLength(chunk));
      if (outputBytes > 1024 * 1024) return;
      output += chunk;
      const lines = output.split('\n');
      output = lines.pop();
      for (const line of lines) observeLine(line);
    });
    child.stderr.on('data', (chunk) => countBytes(chunk.length));
    child.on('error', () => {
      stop('HOST_SIGNAL', 'START_ERROR');
      complete({ reason, diagnostic, outcome: 'UNKNOWN' });
    });
    child.on('close', (code) => {
      observeLine(output);
      const why = checkReason();
      if (why) stop(why);
      if (reason) {
        if (groupGone(child.pid)) complete(stopped());
      } else if (!groupGone(child.pid)) {
        stop('HOST_SIGNAL', 'GROUP_STILL_ACTIVE');
      } else if (code !== 0) {
        complete({ reason: 'HOST_SIGNAL', diagnostic: 'NONZERO_EXIT', outcome: 'UNKNOWN' });
      } else if (adapter.finalize) {
        complete(adapter.finalize(observed));
      } else {
        complete({ evidence, outcome: 'PROCESS_EXITED' });
      }
    });
  });
}

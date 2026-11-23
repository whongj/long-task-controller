# Long Task Controller

A local controller for evidence-based progress, bounded execution and handover to an operator. This preview has two parts.

- **Loop reducer** accepts a fixed target and validated progress events. It checks evidence binding, detects repeated lack of progress and enforces handoff checkpoints. A result of `TARGET_MET` is an input to the operator's review.
- **Execution supervisor** reserves one local verification at a time, keeps a durable ledger, stops owned work at the deadline and exposes the state for human review. It has an offline fixture and a foreground-only Codex adapter.

## Run the offline walkthrough

Use macOS or Linux and Node.js 22.13 or newer. No package install, network, or credentials are needed. PowerShell 7.4 or newer is needed for the Loop reducer tests.

From the repository root:

```sh
run_dir=$(mktemp -d)
node cli.mjs init "$run_dir/demo.db" test/demo-plan.json fixture
node cli.mjs authorize "$run_dir/demo.db" 1 1
node cli.mjs run "$run_dir/demo.db"
node cli.mjs status "$run_dir/demo.db"
```

The first command under supervision sleeps for two seconds. The one-second grant expires, the owned process is cancelled, and the receipt records `DEADLINE`. Read the latest state and sequence (the number of receipts) before making a decision. A background supervisor can also be stopped with `node cli.mjs stop "$run_dir/demo.db"` from another terminal.

```sh
node cli.mjs review "$run_dir/demo.db" 4 resume 'Verified the fixture process exited and made no changes'
node cli.mjs authorize "$run_dir/demo.db" 5 10
node cli.mjs run "$run_dir/demo.db"
node cli.mjs review "$run_dir/demo.db" 10 close 'Reviewed both synthetic fixture results'
node --test
```

A fixture result is marked `SYNTHETIC`. To run the actual Loop reducer against synthetic files and see evidence acceptance and negative cases, run `pwsh -NoProfile -File test/loop.test.ps1`. Integrators can use the [Loop schemas](schemas/) and the example in that test. The reducer takes a workspace root with a stage list at `governance/workflow-transitions.json` and, for trusted mode, an evidence index rooted in that workspace. Use distinct paths for input state, output state and the report.

## Operator decisions

| Flow | Example | Decision |
|---|---|---|
| HOTL (human supervises) | A pre-authorized local verification with a live deadline | The supported adapter may continue within the grant. The operator can inspect or stop it. |
| HOTL with review | Review all validated steps at the end of a batch | The operator checks evidence before closing the run. |
| HITL (human decides before execution) | A local candidate requiring separate judgment, scope change, deadline, unknown outcome, or safety signal | The supervisor pauses. The operator reviews the exact run and receipt sequence. |

A plan fixes the goal, workspace, ordered steps, permitted action types and acceptance text. A plan change starts a separate, intentionally reviewed run. A fresh grant requires a finite positive number of seconds and the current receipt sequence. A process that restarts after dispatch cannot silently repeat in-flight work. When an abandoned owner is gone, `review <db> <sequence> reconcile "<evidence>"` records an unknown outcome. Inspect the workspace and confirm the previous execution and its effects before using `resume`; then grant time again if the host supports unattended execution. A platform safety pause can be closed after review. Its restricted action is never automatically retried.

## Host coverage

| Host | Allowed operation | Evidence |
|---|---|---|
| Offline fixture | Unattended with an explicit grant or foreground | Process-group cancellation and synthetic events, tested locally |
| Codex CLI | Foreground terminal `step <db> <timeout-seconds>` for an authorized local read-only check | Structured CLI events where available, followed by operator verification. Use `review ... accept "<evidence>"` only for a result you independently verified. Unknown or failed runs remain paused. |
| Codex desktop Goal | Observation and handoff through the operator's existing workflow | The CLI supervisor does not control desktop tasks. |

Run Codex only in trusted projects. The native read-only sandbox and approval policy govern host permissions. The plan's working directory sets the initial location and does not restrict all reads to that directory. The wrapper stops for observed structured policy signals and generic errors. Codex CLI versions and platform surfaces can expose different signals. An error, refusal, ambiguous result, or lack of independent evidence cannot drive automatic continuation. See [Codex non-interactive mode](https://developers.openai.com/codex/noninteractive).

Process exit is separate from action outcome. Owned process groups provide bounded local cancellation, with limitations for escaped descendants, abrupt host loss and any previously issued external request. Treat the account running this tool and the local SQLite ledger as trusted operator resources. The digest detects accidental drift and does not defend against someone who can modify both the ledger and the program. See [design decisions](docs/decisions.md) and [security reporting](SECURITY.md).

For the sources behind the project and the changes we made, see [Sources and changes](docs/decisions.md#sources-and-changes). For what happens when Codex raises a safety concern and how to verify the stop behavior, see [Codex safety and operator response](SECURITY.md#codex-safety-and-operator-response).

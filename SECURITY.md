# Security

For a security problem, use this repository's private vulnerability reporting on GitHub when enabled, or contact the repository owner privately. Include the affected version, the observed behavior and a minimal reproduction using synthetic data. Keep credentials, prompts and real task logs out of public issues.

## Codex safety and operator response

The goal is to keep work within its authorized scope and stop when Codex raises a safety concern. OpenAI controls platform warnings and account decisions. Our time limits bound locally supervised work. Platform decisions remain outside the controller's authority. [OpenAI safety guidance](https://help.openai.com/en/articles/20001259-troubleshooting-openai-daybreak)

| When | What the preview does | What the operator does |
|---|---|---|
| Before starting Codex | Requires a real foreground terminal and a finite timeout. The adapter uses Codex's native read-only sandbox and keeps extra approvals disabled for the run. Background Codex commands are refused before dispatch. | Choose a trusted local project and a clearly authorized read-only check. Record the workspace, allowed action, and acceptance criterion. |
| A structured safety signal is observed | Stops dispatch, requests cancellation of the owned process group, and writes `PLATFORM_SAFETY` to the run ledger. The pause cannot be resumed in that run, including when the signal arrives during cancellation. | Review the original platform message. Close the restricted run. If a clearly permitted task was blocked unexpectedly, report it privately through the official support channel. |
| A safety message is visible only in the platform UI | The controller acts on events delivered by its host adapter. Desktop Goal provides observation and handoff. | Stop the affected action through the platform, preserve the relevant facts privately, and review the original request and authorization. |
| The supervised step times out, the host reports a failure, or a result is uncertain | Halts affected work and records the last observed outcome. Process-group exit and action outcome are recorded separately. | Before using any available resume action, verify that the earlier execution stopped and check its effects. Leave the outcome unknown if the evidence is incomplete. |

Keep the timestamp, product surface, exact platform message, and request ID if available. Share a redacted description privately with OpenAI Support. Keep raw prompts, project data, and credentials out of the public issue tracker. [OpenAI troubleshooting and support instructions](https://help.openai.com/en/articles/20001259-troubleshooting-openai-daybreak#contacting-support)

### Verification and rollout

- The offline tests simulate safety events, including one received during cancellation, and check that dispatch does not repeat and `resume` is refused. They also cover expiry during a live step and uncertain outcomes. [Supervisor tests](test/controller.test.mjs)
- On a real host, validate admission, event receipt, deadline, cancellation, and handoff with a harmless authorized read-only task. Record the exact host version and observed coverage. Synthetic events establish controller behavior. Real trials establish what the host actually exposes.
- Keep Codex foreground-only until the proposed unattended entry point has independent evidence for reliable safety-event delivery, timely local cancellation, and recovery after an unknown outcome. An operator must be able to review those receipts. The offline fixture is the current unattended entry. [Host coverage](README.md#host-coverage)

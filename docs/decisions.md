# Design decisions

## Sources and changes

| Source | Practice we drew on | What we built for this project | How to verify it |
|---|---|---|---|
| Anthropic, [Effective harnesses for long-running agents](https://www.anthropic.com/research/effective-harnesses-for-long-running-agents) | Establish a starting baseline, make incremental progress, and leave artifacts for the next session. | We pin the ordered acceptance criteria and validator references. A passing criterion requires evidence and a validator result, and the reducer requires a handoff reference at a compaction checkpoint. | The portable Loop tests change a criterion, claim a pass without evidence, and try to continue without the required handoff. [Loop tests](../test/loop.test.ps1) |
| OpenAI, [Symphony specification](https://github.com/openai/symphony/blob/main/SPEC.md) | Track a worker's lifecycle, detect stalls, and reconcile runtime state. | We reserve work before dispatch, record cancellation separately from its outcome, and require review before retrying after an unknown outcome. The operator sets the run's time limit. | The supervisor tests cover concurrent dispatch, an in-flight deadline, and recovery after an unknown outcome. [Supervisor tests](../test/controller.test.mjs) |
| LangChain, [LangGraph interrupts](https://docs.langchain.com/oss/python/langgraph/interrupts) | Persist state at an interrupt and resume from an explicit decision. | We bind the human decision to the current receipt sequence. A stale decision is rejected, a resumed run needs a fresh grant for unattended work, and a safety pause cannot be resumed in the same run. | The supervisor tests exercise stale review, fresh authorization, and a safety event that arrives during cancellation. [Supervisor tests](../test/controller.test.mjs) |

For the Codex integration, the official CLI guide documents structured output and sandbox options. OpenAI's Help Center explains platform safety messages and the support channel. Our choice is a finite, foreground-only, read-only Codex step followed by human verification. The offline fixture exercises unattended mode. [Codex non-interactive mode](https://developers.openai.com/codex/noninteractive) · [OpenAI safety guidance](https://help.openai.com/en/articles/20001259-troubleshooting-openai-daybreak) · [Operator safety procedure](../SECURITY.md#codex-safety-and-operator-response)

## Freeze the target while allowing evidence to change

We considered allowing edits to the acceptance list during a run. A later pass could then reflect easier criteria. The reducer hashes the ordered criterion IDs, descriptions and validator references. Status and evidence can change while that hash stays fixed. The supervisor independently fixes the run plan and keeps authority out of the progress event.

## Reconcile effects before any retry

We considered retrying a process whenever its exit or response was missing. A missing response can follow a completed action, so the retry might repeat the effect. A recorded reservation allows the operator to identify the affected step, check what happened, and decide whether a new authorization is warranted.

## Return control when authorization expires

We considered letting the agent or scheduler renew its own execution window after a progress update. That would let a work report extend the operator's original consent. We keep the deadline under operator control. The supervisor stops further dispatch at expiry and attempts to cancel the owned process group. The receipt records what the host observed while the effect of the action can remain unknown.

The tests measure behavior under the stated adapter. Overnight productivity and account outcomes remain unmeasured.

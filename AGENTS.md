# Repository guidance

## Project and primary checks

This repository ships a MainStage Lua device script for connecting an SL88 MK2
keyboard via the SL Link SysEx protocol. The product is
`MainStageScript/STUDIOLOGIC/SL.device/config.lua`; the Swift files in
`Scripts/` are standalone hardware-debugging probes, not a build target.

Before changing `config.lua`, read its SIX RULES banner. For changes affecting
display pacing, the session clock, or flushing, also read
`docs/config-lua-history.md`. The byte-level protocol authority is
`docs/implementing-sl-link.md`, backed by the upstream protocol spec pinned at
commit `4c0824d`; do not infer protocol behavior solely from existing code.

Run the offline gate for every `config.lua` change:

```bash
./Scripts/run-lua-tests.sh
```

It syntax-checks with `luac -p` then runs `Tests/lua/harness.lua`. Add durable
regressions to that harness rather than a throwaway test. Verify an assertion
fails against the bug it protects before relying on it. `lua` and `luac` are
required (on macOS: `brew install lua`).

Detailed task playbooks remain under `.claude/skills/` and should be read when
applicable:

- `lua-harness`: offline tests for message bytes, queues, timer behavior, and
  MainStage callbacks.
- `probe-mainstage-internals`: static inspection of the installed MainStage
  host; its findings are hypotheses that require hardware confirmation.
- `test-mainstage-script`: the deploy/relaunch/observe workflow for real SL88
  hardware. Do not start a hardware round-trip unless the user has requested
  it or it is necessary to complete their requested verification.

## Load-bearing invariants

- Send at most one outbound message per flush and keep it within
  `FLUSH_BUDGET`; MainStage silently drops an oversized returned array.
- Gate display output with `displayFlushReady`, one display message per timer
  tick, because the keyboard can drop a message while painting the prior one.
- Gate every `settriggertimer` call with `timerPending`. It is one-shot; an
  unconditional re-arm from frequent inbound MIDI can postpone the timer
  indefinitely.
- Memoized drawing regions must not overlap unless the explicit escape hatch
  in `config.lua` is used.
- `outport` is the short CoreMIDI name `LINK`, not the display name `SL LINK`.
- Do not drop A-encoder/A-button or long-press traffic based on the published
  spec: the physical keyboard differs in those respects.

## Hardware work

Physical verification requires an attached SL88 MK2 and an explicit, sound
observation path. Establish a positive control before accepting a negative
result; a CoreMIDI source sniffer cannot observe an outbound destination send,
so provoke a reply when appropriate. Run offline checks before deployment.

For a MainStage restart, use `Scripts/restart-mainstage.sh --save --debug`.
Confirm it actually replaced the process and recreated `/tmp/lua.log`, then
wait for the user to confirm the concert has loaded rather than guessing from
a delay or log line. Turn `LUA_DEBUG` off and stop any temporary sniffer after
the run. Document durable hardware findings in `docs/mainstage-integration.md`.

## Versioning and scope

`VERSION` is the semantic-version source of truth; `SCRIPT_VERSION` in
`config.lua` must match it (the harness enforces this). Changing existing
MIDI-Learn CC mappings or install layout is major; compatible feature/screens
are minor; fixes and tuning are patch.

Keep edits focused. Cap noisy probe and debug output. The existing worktree may
contain user changes: preserve unrelated changes and never reset or overwrite
them. Commit messages should be brief; investigation detail belongs in `docs/`.

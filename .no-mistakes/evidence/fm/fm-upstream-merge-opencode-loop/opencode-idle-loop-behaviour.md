# OpenCode idle repair loop - behaviour transcript

Source: bin/fm-test-run.sh tests/fm-opencode-secondmate-arm.test.sh tests/fm-turnend-guard.test.sh ... (exit 0)
Each line below is the real .opencode/plugins/fm-primary-watch-arm.js factory driven through session.idle;
a 'model turn' is a client.session.promptAsync call counted by the driver.

ok - watch-arm: arms the plain primary checkout
ok - watch-arm: a root failing the AGENTS.md/bin shape gate stays silent, as the shell owner requires
ok - watch-arm: arms a treehouse-leased LINKED secondmate home via its marker (regression)
ok - watch-arm: stays silent in a crewmate/scout linked task worktree
ok - watch-arm: an empty marker cannot spoof inclusion; linked worktree stays exempt
ok - watch-arm: honours the first-line marker contract when the marker has extra lines
ok - watch-arm: a blank first line cannot spoof inclusion via a later line
ok - watch-arm: an unterminated marker is rejected exactly as the shell owner rejects it
ok - watch-arm: strips only ASCII blanks, matching the shell owner under LC_ALL=C
ok - watch-arm: a symlinked marker cannot spoof inclusion, matching the shell owner's [ -L ] rejection
ok - watch-arm: a marked secondmate home spawns a real arm child on session.idle (regression)
ok - watch-arm: empty/healthy/unexplained-cycle closes are idle; real FAILED and wakes keep their kinds
ok - watch-arm: a healthy-watcher close does not start a model turn
ok - watch-arm: an empty cycle close does not start a model turn
ok - watch-arm: an actionable wake still delivers a model turn
ok - turnend-guard: a loaded watch-arm coordinator suppresses the idle repair turn
ok - watch-arm: a registered process-event source arms supervision without task.meta
ok - turnend-guard: a coordinator that declines (read-only) hands the idle to the shell guard
ok - watch-arm: benign idle cycles leave the failure retry budget intact
ok - watch-arm: an idle successor close during restoration is retried silently, not accepted as armed
ok - watch-arm: a watcher that outlived the cycle floor replenishes the idle re-arm budget
ok - watch-arm: exhausted silent re-arm queues one durable check and never prompts
ok - watch-arm: empty closes between real failures do not hide the failure
ok - watch-arm: an unestablishable home re-arms every idle but spends only one model turn
ok - watch-arm: an exhaustion notice that was not delivered does not retire the attempt
ok - watch-arm: a notice settling after a replenish cannot silence the current budget
ok - watch-arm: a replaced session surfaces once on a budget only a completed cycle replenishes
ok - watch-arm: alternating sessions each surface once and never repay the failure budget
ok - watch-arm: a failure retry that finds no remaining need does not prompt
ok - watch-arm: a slow-confirming retry launch is a success, not a watcher failure
ok - watch-arm: a crewmate/scout worktree stays silent on idle (no arm, no model turn)
ok - watch-arm: an attached arm reports the wake its cycle delivered instead of a false failure
ok - watch-arm: a delivered wake consumed by the handling turn still closes the attached arm cleanly
ok - watch-arm: a cycle that delivered no wake of its own still fails loudly
ok - watch-arm: re-arm surfaces every queued wake and an open remote decision after downtime
ok - watch-arm: marker publication failure retains stale-lock recovery evidence
ok - watch-arm: a wake queued after handling drain is recovered once at successor arm
ok - watch-arm: interrupted handling leaves its wake durable for successor re-drain
ok - watch-arm: malformed recovery state is quarantined without a successor loop
ok - watch-arm: publication after recovery handoff is surfaced
ok - watch-arm: restart publishes recovery before clearing a reused-pid watcher lock
ok - watch-arm: markerless legacy queues are adopted and recovered
ok - watch-arm: a watcher close during handling keeps the printed acknowledgement valid
ok - watch-arm: a moved recovery generation consumes handled rows and names its remedy
ok - watch-arm: downtime marker publication does not follow symlinks

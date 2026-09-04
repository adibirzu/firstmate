# Regression proof: late exhaustion-notice settle vs. replenished budget

New case: tests/fm-opencode-secondmate-arm.test.sh::test_late_settle_cannot_latch_a_replenished_budgets_notice

## RED - .opencode/plugins/fm-primary-watch-arm.js at the pre-fix parent (3025613, un-keyed boolean latch)
```
ok - watch-arm: an exhaustion notice that was not delivered does not retire the attempt
not ok - a late settle from a spent budget must not retire the current budget's notice: expected exit 0, got 1
```
Every other case in the file still passed at that commit; only the new interleaving failed,
i.e. the spent budget's late success latched the marker and the home went silent with nothing delivered.

## GREEN - target commit cfc0ffe (notice keyed to sessionID + budget token)
```
ok - watch-arm: an exhaustion notice that was not delivered does not retire the attempt
ok - watch-arm: a notice settling after a replenish cannot silence the current budget
ok - watch-arm: a replaced session surfaces once on a budget only a completed cycle replenishes
ok - watch-arm: alternating sessions each surface once and never repay the failure budget
```

Stability: the arm suite was re-run 3 further times, exit 0 each time.

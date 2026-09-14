---
name: quota-array-dispatch
description: >-
  One-release pointer skill: load router-dispatch instead. Retained only so
  existing triggers keep resolving while callers migrate, and it restates no
  ranking or selection rule.
user-invocable: false
metadata:
  internal: true
---

# quota-array-dispatch

This skill is a one-release pointer and owns no procedure.
Load `router-dispatch` instead: it is now the single owner of the subscription-aware profile-array selection judgment boundary, and the procedure that used to live here moved there.
This file will be removed in a later release once callers have migrated.

---
name: project-skill-profile
description: >-
  Agent-only reference for per-project skill allowlists: detect which skills a
  project usually needs, record hits, and load only that profile into crewmate
  briefs and OpenCode overlays. Also owns the feature vs prd-finish validation
  ladder (changed tests during feature work; full suite + high-thinking review
  when a PRD finishes).
user-invocable: false
metadata:
  internal: true
---

# project-skill-profile

Load before scaffolding or spawning work that should restrict skills to a
project's habitual set, before recording that a crewmate needed an extra skill,
and before choosing feature vs PRD-finish validation.

## Skill allowlist

`bin/fm-project-skills-lib.sh` is the one owner.

| Surface | Role |
|--------|------|
| `config/project-skills.json` | Optional home-local defaults and per-project `skills[]` |
| `data/project-skills/<slug>.json` | Learned hit counts (`hits`) |
| Brief `# Skills to load` | Emitted by `fm_project_skills_brief_section` |
| OpenCode overlay | `fm_project_skills_opencode_permission_json` deny-all except resolved skills |

Resolve order: always (`no-mistakes`) → baseline env → config → learned hits →
names detected in the brief. Missing config never invents skills.

When a worker loads a skill outside the profile and it was necessary, firstmate
records it with `fm_project_skills_observe <repo> <skill>`.

## Validation ladder

`bin/fm-validation-lib.sh` is the one owner.

| Phase | Tests | Review |
|-------|-------|--------|
| `feature` (default) | `--changed` / tests for newly developed files only | Stage 1 only |
| `prd-finish` | Full suite | Stage 1 + forced high-thinking Stage 2 |

Ship briefs record `validation=<phase>` on the Delivery contract line beside
`mode=`. Spawn refuses when the explicit `--validation` disagrees with the brief.

## Triggers

- Before writing or adjusting a ship/scout brief's skill section or validation phase.
- Before OpenCode crew/scout launch when the skill overlay must match the project profile.
- When a PRD (or equivalent finish gate) is ready and validation must flip to `prd-finish`.

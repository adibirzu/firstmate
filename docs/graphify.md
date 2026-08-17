# Graphify fleet orientation index

Graphify is an optional, fleet-only orientation index.
Agents consult it before a broad read of unfamiliar code so they spend tokens on the files that matter, not on a first pass through the tree.

It is not part of firstmate's required toolchain.
A home without Graphify installed behaves as it always has: agents read source.

## Install

The measured CLI surface is Graphify 0.9.43 (`extract --out --no-cluster --code-only` and `query --budget --graph`).
Install the published package that provides the `graphify` binary:

```sh
uv tool install graphifyy
```

The helper refuses to run when `graphify` is not on `PATH` and tells the caller to read source instead.

## Fleet-only boundary

Graphify is an external, disposable, per-project index stored under the firstmate home, never inside a project clone.
DevVisualization remains the sole canonical product graph.
Do not wire Graphify into DevVisualization, and do not feed Graphify output into DevVisualization or any project.
That crossing is a separate, unratified product decision.

The home-layout fact (`data/graphify/` under the effective `FM_HOME`) is owned by [configuration.md](configuration.md).
`bin/fm-graphify.sh` owns the build and query commands.

## Trigger

Graph-first is mandatory only when an agent is about to broadly explore unfamiliar code, discover relevant files, map ownership, or trace cross-file relationships.
It is not an every-session query.
Firstmate loads [`graphify-orientation`](../.agents/skills/graphify-orientation/SKILL.md) at that trigger.
The skill owns the agent procedure, including fallback to source.

## Freshness

When the graph substitutes for reading code, accept zero unverified staleness.
`bin/fm-graphify.sh query` validates the target tree's current revision and dirty-tree state at query time, then rebuilds or prints `GRAPHIFY_FALLBACK=source`.
Scheduled rebuilds are a non-authoritative cache only.
Do not query a graph that was rebuilt on a timer and treat it as current.

Build or query a tree with:

```sh
bin/fm-graphify.sh build /path/to/project
bin/fm-graphify.sh query /path/to/project "where is the spawn admission decision made"
bin/fm-graphify.sh query /path/to/project "who owns PR merge metadata" --budget 2000
```

The helper writes only under the firstmate home.
It never runs `graphify update` against a project, because that command's default output is an in-repo `graphify-out/`.

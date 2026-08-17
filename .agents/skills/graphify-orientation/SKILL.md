---
name: graphify-orientation
description: >-
  Agent-only procedure for Firstmate's fleet-only Graphify orientation index.
  Load before broadly exploring unfamiliar code, discovering relevant files,
  mapping ownership, or tracing cross-file relationships.
user-invocable: false
metadata:
  internal: true
---

# graphify-orientation

Load this before a broad exploration of unfamiliar code, a search for the relevant files, an ownership map, or a cross-file relationship trace.
Do not load it at session start, and do not query the index on every turn.
[`docs/graphify.md`](../../../docs/graphify.md) owns install, the fleet-only boundary, the trigger, and the freshness rule.
`bin/fm-graphify.sh` owns the commands, flags, index path, and stamp format.

## Procedure

1. Ask one orientation question that names the behavior, owner, or relationship you need, not a file you already know.
2. Run `bin/fm-graphify.sh query <repo> "<question>"` from the firstmate code root, with `FM_HOME` set to this home.
   Pass `--budget` only when a different token cap is required; the helper default is the documented query budget.
3. Use the returned nodes as a map of where to read next.
   Then read those files.
   Do not treat the graph as a substitute for the file once you are editing or diagnosing a specific line.
4. If the helper prints `GRAPHIFY_FALLBACK=source` or exits nonzero, stop using the graph and read the source.
   Missing Graphify, an unreadable revision, a failed rebuild, or an in-project write are all fallbacks, not guesses.

The helper validates the target tree's current revision and dirty-tree state at query time and rebuilds before answering when the stamp does not match.
Do not run a scheduled rebuild and then query as if that cache were fresh.
Do not run `graphify update` against a project tree; that writes `graphify-out/` inside the repo.

## Fleet-only boundary

Graphify is an external, disposable, per-project fleet orientation index.
It is not DevVisualization, not a product graph, and not an input to any project.
Do not feed Graphify output into DevVisualization, `devviz`, the `graph_first` MCP tool, or any project tree.
The DevVisualization graph-first line in ship and scout briefs is a separate product-graph accelerator; do not send Graphify results there and do not treat that line as this index.

When briefing a worker that will explore unfamiliar code, point them at `bin/fm-graphify.sh query` rather than leaving the first map of the tree to unguided reads.
Keep that pointer conditional on this trigger.
Do not add an every-session graph query to a brief.

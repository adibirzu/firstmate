#!/usr/bin/env node
/**
 * fm-captain-hold-batcher.mjs
 *
 * Parses hold-kind: captain items from Firstmate backlog.md,
 * groups them by project, and generates captain-hold-digest.html.
 */

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

function parseArgs() {
  const args = process.argv.slice(2);
  const opts = { backlog: "", output: "", json: false };
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--backlog" && args[i + 1]) opts.backlog = args[++i];
    else if (args[i] === "--output" && args[i + 1]) opts.output = args[++i];
    else if (args[i] === "--json") opts.json = true;
  }
  return opts;
}

export function parseBacklog(content) {
  const lines = content.split("\n");
  const projects = {};
  let total = 0;

  for (const line of lines) {
    const m = line.match(/^\s*-\s*\[ \]\s*([a-zA-Z0-9._-]+)\s*-\s*(.*?)\(hold-kind:\s*captain\)/);
    if (!m) continue;

    const id = m[1];
    const rest = m[2];
    let repo = "firstmate";
    const repoMatch = rest.match(/\(repo:\s*([^)]+)\)/);
    if (repoMatch) repo = repoMatch[1].trim();

    let title = rest.replace(/\s*\(.*/, "").trim();
    let hold = "";
    const holdMatch = rest.match(/\(hold:\s*([^)]+)\)/);
    if (holdMatch) hold = holdMatch[1].trim();

    if (!projects[repo]) projects[repo] = [];
    projects[repo].push({ id, title, hold, repo });
    total++;
  }

  return { total, projects };
}

function escapeHtml(str) {
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

export function renderHtml(data, today) {
  const { total, projects } = data;
  const projectKeys = Object.keys(projects).sort();

  let sectionsHtml = "";
  for (const p of projectKeys) {
    const items = projects[p];
    let itemsHtml = "";
    for (const item of items) {
      const escId = escapeHtml(item.id);
      const escTitle = escapeHtml(item.title);
      const escHold = escapeHtml(item.hold);
      itemsHtml += `
  <div class="card" id="card-${escId}">
    <div class="card-header">
      <span class="badge">${escId}</span>
      <h3 class="card-title">${escTitle}</h3>
    </div>
    <div class="card-hold">${escHold}</div>
    <div class="btn-row" data-lavish-question="${escId}" data-lavish-title="${escTitle}">
      <button type="button" class="btn btn-accept" data-choice="Accept" data-close-mode="release">Accept</button>
      <button type="button" class="btn btn-reject" data-choice="Reject" data-close-mode="done">Reject</button>
      <button type="button" class="btn btn-defer" data-choice="Defer" data-close-mode="done">Defer</button>
      <span class="status-msg" id="status-${escId}"></span>
    </div>
  </div>`;
    }

    sectionsHtml += `
<div class="project-sec">
  <div class="project-title"><span>${escapeHtml(p)}</span> <span class="badge">${items.length} items</span></div>
  ${itemsHtml}
</div>`;
  }

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Captain Holds - Daily Batch</title>
<style>
:root {
  --rust-500: #c0452a; --rust-600: #a93a1f; --rust-050: #fbece3;
  --navy-700: #1a2238; --navy-600: #222c49; --navy-100: #d9deea;
  --gold-500: #e0a52e; --gold-600: #b5791c; --gold-100: #f8ecc9;
  --sea-500: #2f6b4f; --sea-050: #e9f2ec;
  --paper-000: #fbf4e2; --paper-100: #f6ecd3; --paper-200: #f0e3c4;
  --cream-line: #ddc89c;
  --ink-900: #241c14; --ink-700: #3f3224; --ink-500: #6f5e46;
  --white: #fffdf7;
  --font-sans: "Jost", -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  --font-mono: "JetBrains Mono", monospace;
  --shadow-hard: 3px 3px 0 var(--ink-900);
}
* { box-sizing: border-box; }
body {
  margin: 0; padding: 24px; font-family: var(--font-sans);
  background: var(--paper-100); color: var(--ink-700); line-height: 1.5;
}
.container { max-width: 900px; margin: 0 auto; }
header { margin-bottom: 28px; border-bottom: 2px solid var(--cream-line); padding-bottom: 16px; }
h1 { font-size: 1.8rem; margin: 0 0 8px 0; color: var(--ink-900); }
.subtitle { font-size: 0.95rem; color: var(--ink-500); }
.project-sec { margin-bottom: 32px; }
.project-title {
  font-size: 1.25rem; font-weight: 700; color: var(--navy-700);
  margin: 0 0 14px 0; display: flex; align-items: center; gap: 8px;
}
.card {
  background: var(--white); border: 1.5px solid var(--ink-900);
  border-radius: 8px; padding: 18px; margin-bottom: 14px;
  box-shadow: var(--shadow-hard); transition: opacity 0.2s;
}
.card.is-answered { opacity: 0.55; background: var(--paper-000); }
.card-header { display: flex; align-items: baseline; gap: 10px; margin-bottom: 8px; }
.badge {
  font-family: var(--font-mono); font-size: 0.75rem; font-weight: 700;
  padding: 3px 7px; background: var(--paper-200); border: 1px solid var(--ink-900);
  border-radius: 4px; color: var(--ink-900);
}
.card-title { font-weight: 600; font-size: 1rem; color: var(--ink-900); margin: 0; }
.card-hold {
  font-size: 0.9rem; color: var(--ink-700); background: var(--paper-000);
  padding: 10px 12px; border-left: 3px solid var(--gold-500);
  border-radius: 0 4px 4px 0; margin-bottom: 14px;
}
.btn-row { display: flex; gap: 10px; align-items: center; }
.btn {
  font-family: var(--font-sans); font-weight: 700; font-size: 0.825rem;
  padding: 6px 14px; border: 1.5px solid var(--ink-900); border-radius: 5px;
  cursor: pointer; box-shadow: 2px 2px 0 var(--ink-900);
  transition: transform 0.1s, box-shadow 0.1s;
}
.btn:active { transform: translate(1px, 1px); box-shadow: 1px 1px 0 var(--ink-900); }
.btn-accept { background: var(--sea-500); color: var(--white); }
.btn-reject { background: var(--rust-500); color: var(--white); }
.btn-defer  { background: var(--gold-500); color: var(--navy-700); }
.status-msg { font-size: 0.8rem; font-weight: 600; margin-left: 8px; color: var(--ink-500); }
</style>
</head>
<body>
<div class="container">
<header>
  <h1>Captain Holds Daily Batch</h1>
  <div class="subtitle">${total} items awaiting captain decision &mdash; generated ${today}</div>
</header>
${sectionsHtml}
</div>
<script>
function submitChoice(id, title, choice, closeMode) {
  var card = document.getElementById("card-" + id);
  var status = document.getElementById("status-" + id);
  if (window.lavish && window.lavish.queuePrompt) {
    window.lavish.queuePrompt("Captain Hold: " + title + " -> " + choice, {
      tag: "choice",
      text: title + " -> " + choice,
      data: { question: id, answer: choice, close: closeMode }
    });
  }
  if (status) status.textContent = "✓ " + choice + " queued";
  if (card) card.classList.add("is-answered");
}

document.querySelectorAll(".btn-row button").forEach(function(button) {
  button.addEventListener("click", function() {
    var row = button.parentElement;
    if (!row) return;
    submitChoice(row.dataset.lavishQuestion, row.dataset.lavishTitle, button.dataset.choice, button.dataset.closeMode);
  });
});
</script>
</body>
</html>`;
}

function main() {
  const opts = parseArgs();
  if (!opts.backlog) {
    console.error("error: missing --backlog path");
    process.exit(1);
  }

  const content = readFileSync(opts.backlog, "utf8");
  const data = parseBacklog(content);

  if (opts.json) {
    console.log(JSON.stringify(data, null, 2));
    return;
  }

  if (!opts.output) {
    console.error("error: missing --output path");
    process.exit(1);
  }

  const today = new Date().toISOString().split("T")[0];
  const html = renderHtml(data, today);

  mkdirSync(dirname(opts.output), { recursive: true });
  writeFileSync(opts.output, html, "utf8");
}

if (process.argv[1] && process.argv[1].endsWith("fm-captain-hold-batcher.mjs")) {
  main();
}

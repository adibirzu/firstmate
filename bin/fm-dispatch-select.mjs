#!/usr/bin/env node
// fm-dispatch-select.mjs - thin compatibility shim over llm-router-axi.
// Usage:
//   fm-dispatch-select.mjs select [--quota-json <file>] [--now <epoch>] [<json>]
//   fm-dispatch-select.mjs record-failure --provider <provider> --task <id> [--now <epoch>]
//   fm-dispatch-select.mjs clear --provider <provider>
//   fm-dispatch-select.mjs classify-evidence (--file <path> | with text on stdin)
//
// Every subcommand forwards to the llm-router-axi tool, which now owns the
// dispatch selection, telemetry, cooldown, and depletion-classification logic
// that used to live here:
//   select            -> llm-router-axi select            (arbitrary-profile choice)
//   record-failure    -> llm-router-axi record --outcome rate_limit
//   clear             -> llm-router-axi record --outcome ok
//   classify-evidence -> llm-router-axi classify-evidence
//
// This file exists only so existing firstmate callers keep their command line.
// The router policy at ~/.config/llm-router-axi/policy.json now owns the
// reserve, cooldown, telemetry-age, and machine-capacity settings, and
// bin/fm-model-fallback.sh reads its step-down chain from `route chain`.
//
// Resolution: FM_LLM_ROUTER_AXI names an executable, else llm-router-axi on
// PATH. A host without the tool is refused with the one-line install hint
// rather than silently dispatching with no router.
import { spawnSync } from 'node:child_process';

const ROUTER = process.env.FM_LLM_ROUTER_AXI || 'llm-router-axi';
const INSTALL =
  'git clone https://github.com/adibirzu/llm-router-axi && cd llm-router-axi && npm ci && npm run build && npm install -g --prefix ~/.local .   # repeat for https://github.com/adibirzu/usage-axi';

const USAGE = `usage: fm-dispatch-select.mjs <select|record-failure|clear|classify-evidence> [flags]
  select             choose one profile through llm-router-axi select
  record-failure     llm-router-axi record --outcome rate_limit
  clear              llm-router-axi record --outcome ok
  classify-evidence  llm-router-axi classify-evidence
Every subcommand forwards to llm-router-axi; run it with --help for its flags.`;

function die(message, code = 2) {
  process.stderr.write(`fm-dispatch-select: ${message}\n`);
  process.exit(code);
}

function run(args) {
  const result = spawnSync(ROUTER, args, { stdio: 'inherit' });
  if (result.error) {
    process.stderr.write(
      `fm-dispatch-select: llm-router-axi is not available (${result.error.code || result.error.message})\n`,
    );
    process.stderr.write(`fm-dispatch-select: install it with: ${INSTALL}\n`);
    process.exit(2);
  }
  process.exit(result.status === null ? 1 : result.status);
}

function flagValue(argv, name) {
  const index = argv.indexOf(name);
  if (index < 0) return undefined;
  const value = argv[index + 1];
  if (value === undefined || value.startsWith('--')) {
    die(`${name} requires a value`);
  }
  return value;
}

const argv = process.argv.slice(2);

if (argv[0] === '--help' || argv[0] === '-h') {
  process.stdout.write(`${USAGE}\n`);
  process.exit(0);
}

const command = argv.length === 0 || argv[0].startsWith('-') ? 'select' : argv.shift();

switch (command) {
  case 'select':
    run(['select', ...argv]);
    break;
  case 'classify-evidence':
    run(['classify-evidence', ...argv]);
    break;
  case 'record-failure': {
    const provider = flagValue(argv, '--provider');
    const task = flagValue(argv, '--task');
    if (!provider || !task) {
      die('record-failure needs --provider <name> and --task <id>');
    }
    const now = flagValue(argv, '--now');
    run([
      'record',
      '--provider',
      provider,
      '--outcome',
      'rate_limit',
      '--task',
      task,
      ...(now ? ['--now', now] : []),
    ]);
    break;
  }
  case 'clear': {
    const provider = flagValue(argv, '--provider');
    if (!provider) {
      die('clear needs --provider <name>');
    }
    run(['record', '--provider', provider, '--outcome', 'ok', '--task', 'clear']);
    break;
  }
  default:
    die(`unknown command ${command}`);
}

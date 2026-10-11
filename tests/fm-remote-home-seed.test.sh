#!/usr/bin/env bash
# Focused bootstrap contracts over a synthetic SSH transport.
# The trace suite starts job workers and endpoints before its seed checks, so
# this executable suite isolates seed/receiver failures without Herdr lifecycle.
# Run with /bin/bash on macOS to exercise stock Bash 3.2 in every child script.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-remote-home-seed)
python3 - "$ROOT" "$TMP_ROOT" "$BASH" <<'PY'
import base64
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT, TMP = map(Path, sys.argv[1:3])
SHELL = os.path.realpath(sys.argv[3])
EMPTY_HASH = __import__("hashlib").sha256(b"").hexdigest()
PAYLOAD = b"min_free_memory_mb=200\n"
HASH = __import__("hashlib").sha256(PAYLOAD).hexdigest()
LEGACY_ITEMS = (
    "crew-dispatch.json dispatch-never-send crew-harness backlog-backend backend "
    "herdr-presentation-spaces herdr-session-prefix startup-memory-budget "
    "trace-context launch-env-allowlist claude-permission-mode lavish-axi-host "
    "keep-ai-trailers supervision-host-off"
)
BASE_ENV = os.environ.copy()
for key in ("FM_INHERITABLE_CONFIG", "FM_CAPACITY_NO_GUARD", "FM_TEST_HARNESS",
            "FM_SECONDMATE_HOME", "FM_LEASE_ACTOR"):
    BASE_ENV.pop(key, None)
FAKEBIN = TMP / "fakebin"
FAKEBIN.mkdir()
(FAKEBIN / "bash").symlink_to(SHELL)
SSH = FAKEBIN / "ssh-fixture"
SSH.write_text("#!" + sys.executable + "\n" + r'''
import base64
import json
import os
from pathlib import Path
import subprocess
import sys

args = sys.argv[1:]
while args and args[0] == "-o":
    args = args[2:]
assert args.pop(0) == "--"
host, entry, protocol, root64, home64, argv64 = args
assert (host, entry, protocol) == ("bootstrap-host", "fm-remote-entrypoint.sh", "1")
root = base64.b64decode(root64).decode()
home = base64.b64decode(home64).decode()
argv = base64.b64decode(argv64).split(b"\0")
assert argv.pop() == b""
argv = [arg.decode() for arg in argv]
case = Path(os.environ["TEST_BOOTSTRAP_CASE"])
assert (root, home) == (str(case / "code-root"), str(case / "remote-home"))
with (case / "transport.jsonl").open("a") as stream:
    stream.write(json.dumps(argv) + "\n")
payload = sys.stdin.buffer.read()
command = argv[0]
if command == "fm-remote-home-provision.sh":
    (case / "manifest").write_bytes(payload)
if command == os.environ.get("TEST_BOOTSTRAP_FAIL_COMMAND"):
    print("synthetic transport failure", file=sys.stderr)
    sys.exit(int(os.environ["TEST_BOOTSTRAP_FAIL_STATUS"]))
if command == "fm-remote-doctor.sh":
    print("ok: synthetic readiness")
elif command == "fm-remote-home-provision.sh":
    print("provisioned: synthetic")
elif command == "fm-remote-secondmate-control.sh":
    if argv[1] == "sync":
        print("current: synthetic baseline")
    else:
        (case / "launch-attempted").write_text("unexpected endpoint action")
        sys.exit(99)
elif command == "fm-remote-inherit.sh":
    env = os.environ.copy()
    env["FM_HOME"] = home
    env.pop("FM_INHERITABLE_CONFIG", None)
    if env.get("TEST_BOOTSTRAP_LEGACY"):
        env["FM_INHERITABLE_CONFIG"] = env["TEST_BOOTSTRAP_LEGACY_ITEMS"]
    proc = subprocess.run(
        [env["TEST_BOOTSTRAP_SHELL"], str(Path(env["TEST_BOOTSTRAP_ROOT"]) / "bin" / command),
         *argv[1:]], input=payload, env=env, timeout=15
    )
    sys.exit(proc.returncode)
else:
    raise AssertionError("unexpected command: " + command)
''')
SSH.chmod(0o755)


def check(value, message):
    if not value:
        raise AssertionError(message)


def run(case, script, args=(), env=None, data=None):
    child = case["env"].copy()
    child.update(env or {})
    return subprocess.run(
        [SHELL, str(ROOT / "bin" / script), *map(str, args)],
        input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env=child, cwd=ROOT, timeout=25,
    )


def expect(proc, status, fragment=b""):
    check(proc.returncode == status,
          f"expected exit {status}, got {proc.returncode}: {proc.stdout!r} {proc.stderr!r}")
    check(fragment in proc.stdout + proc.stderr,
          f"missing diagnostic {fragment!r}, exit={proc.returncode}: {proc.stdout!r} {proc.stderr!r}")


def fixture(name):
    path = TMP / name
    for rel in ("parent/data", "parent/state", "parent/config", "parent/projects",
                "remote-home/config", "remote-home/data", "remote-home/state", "code-root"):
        (path / rel).mkdir(parents=True, exist_ok=True)
    parent = path / "parent"
    registry = parent / "data/secondmates.md"
    registry.write_text("# Synthetic unrelated registry content\n")
    (parent / "config/crew-harness").write_text("codex\n")
    (parent / "config/backend").write_text("tmux\n")
    (parent / "data/backlog.md").write_text("## In flight\n\n## Queued\n\n## Done\n")
    env = BASE_ENV.copy()
    env.update(
        PATH=str(FAKEBIN) + os.pathsep + BASE_ENV["PATH"],
        FM_HOME=str(parent), FM_ROOT_OVERRIDE=str(ROOT),
        FM_SSH_BIN=str(SSH), FM_SPAWN_NO_GUARD="1",
        FM_PROCEVENT_CLAIM_ROOT=str(path / "claims"),
        FM_SECONDMATE_CHARTER="Own synthetic bootstrap validation.",
        FM_SECONDMATE_SCOPE="synthetic bootstrap",
        TEST_BOOTSTRAP_CASE=str(path), TEST_BOOTSTRAP_ROOT=str(ROOT),
        TEST_BOOTSTRAP_SHELL=SHELL, TEST_BOOTSTRAP_LEGACY_ITEMS=LEGACY_ITEMS,
    )
    return dict(path=path, parent=parent, registry=registry, env=env)


def seed(case, args=("--no-projects",), env=None):
    return run(case, "fm-remote-home-seed.sh",
               ("bootstrap", "bootstrap-host", case["path"] / "code-root",
                case["path"] / "remote-home", *args), env)


def calls(case):
    path = case["path"] / "transport.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def no_endpoint(case):
    check(not (case["parent"] / "state/bootstrap.meta").exists(), "started parent endpoint recorded")
    check(not list((case["path"] / "remote-home/state").rglob("*.meta")), "remote endpoint recorded")
    check(not (case["path"] / "launch-attempted").exists(), "remote endpoint action reached")


def manifest(case):
    fields = {}
    for line in (case["path"] / "manifest").read_text().splitlines():
        key, value = line.split("=", 1)
        fields.setdefault(key, []).append(value)
    return fields


def passed(message):
    print("ok - " + message, flush=True)


case = fixture("projectless")
expect(seed(case), 0, b"home=bootstrap-host:")
fields = manifest(case)
check(fields["project_count"] == ["0"] and "project" not in fields, "invalid zero-project manifest")
check([c[0] for c in calls(case)] == ["fm-remote-doctor.sh", "fm-remote-home-provision.sh"],
      "zero-project seed never reached intended transport")
check("bootstrap-host" in case["registry"].read_text(), "successful route absent")
no_endpoint(case)
passed("project-less public seed reaches transport with an exact zero-project manifest")

case = fixture("projects")
projects = {"alpha": "https://example.invalid/alpha.git", "beta": "https://example.invalid/beta.git"}
(case["parent"] / "data/projects.md").write_text(
    "".join(f"- {name} [direct-PR] - synthetic (added 2026-01-01)\n" for name in projects)
)
expect(seed(case, tuple(f"{name}={url}" for name, url in projects.items())), 0)
fields = manifest(case)
records = [[base64.b64decode(value).decode() for value in record.split("|")]
           for record in fields["project"]]
check(fields["project_count"] == ["2"], "wrong project count")
check([(row[0], row[1], row[3]) for row in records] ==
      [(name, url, "direct-PR") for name, url in projects.items()], "project arguments changed")
no_endpoint(case)
passed("project-bearing seed preserves two names, origins and delivery modes")

case = fixture("mixed")
before = case["registry"].read_bytes()
expect(seed(case, ("--no-projects", "alpha=https://example.invalid/alpha.git")), 1,
       b"--no-projects cannot be combined")
check(case["registry"].read_bytes() == before and not calls(case), "mixed seed mutated registry/transport")
passed("mixed project-less/project arguments refuse before transport or registry changes")

for status in (23, 255):
    case = fixture("transport-" + str(status))
    before = case["registry"].read_bytes()
    env = {"TEST_BOOTSTRAP_FAIL_COMMAND": "fm-remote-home-provision.sh",
           "TEST_BOOTSTRAP_FAIL_STATUS": str(status)}
    expect(seed(case, env=env), 1,
           b"completion is unknown" if status == 255 else b"registry restored")
    if status == 255:
        check("bootstrap-host" in case["registry"].read_text(), "unknown completion lost route")
        check((case["parent"] / "data/bootstrap/brief.md").exists(), "unknown completion lost brief")
    else:
        check(case["registry"].read_bytes() == before, "known refusal changed prior registry")
        check(not (case["parent"] / "data/bootstrap/brief.md").exists(), "known refusal retained new brief")
    no_endpoint(case)
    status_case = fixture("fm-on-status-" + str(status))
    expect(seed(status_case), 0)
    registered = status_case["registry"].read_bytes()
    expect(run(status_case, "fm-on.sh", ("bootstrap", "fm-remote-home-provision.sh"), env), status)
    check(status_case["registry"].read_bytes() == registered, "fm-on changed its registered route")
    no_endpoint(status_case)
    passed(f"transport {status} preserves exact fm-on status and seed refusal/reconciliation state")


def receive(case, action="put", rel="config/spawn-capacity", payload=PAYLOAD,
            digest=HASH, generation="1", env=None):
    settings = {"FM_HOME": str(case["path"] / "remote-home")}
    settings.update(env or {})
    return run(case, "fm-remote-inherit.sh",
               (action, rel, len(payload), digest, generation), settings, payload)


case = fixture("receiver")
dest = case["path"] / "remote-home/config/spawn-capacity"
expect(receive(case), 0, b"pushed:")
check(dest.read_bytes() == PAYLOAD, "capacity bytes changed")
expect(receive(case), 0, b"unchanged:")
expect(receive(case, "absent", payload=b"", digest=EMPTY_HASH, generation="2"), 0, b"removed:")
check(not dest.exists(), "absent did not remove capacity")
no_endpoint(case)
passed("declared spawn-capacity put, identical retry and absent preserve receiver contract")

case = fixture("receiver-negative")
expect(receive(case, rel="config/secondmate-harness"), 1, b"path is not inherited material")
expect(receive(case, digest="0" * 64), 1, b"digest does not match")
expect(receive(case, generation="0"), 1, b"generation is outside")
dest = case["path"] / "remote-home/config/spawn-capacity"
check(not dest.exists(), "invalid payload published")
expect(receive(case, generation="3"), 0)
expect(receive(case, "absent", payload=b"", digest=EMPTY_HASH, generation="2"), 1, b"superseded")
expect(receive(case, "absent", payload=b"", digest=EMPTY_HASH, generation="3"), 1, b"conflicts")
check(dest.read_bytes() == PAYLOAD, "generation refusal changed committed capacity")
passed("undeclared config, wrong digest, invalid/stale/conflicting generations refuse safely")

case = fixture("receiver-unsafe")
outside = case["path"] / "outside"
outside.write_bytes(b"preserve synthetic outside content")
dest = case["path"] / "remote-home/config/spawn-capacity"
dest.symlink_to(outside)
expect(receive(case), 1, b"destination is a symlink")
expect(receive(case, "absent", payload=b"", digest=EMPTY_HASH), 1, b"destination is a symlink")
check(dest.is_symlink() and outside.read_bytes() == b"preserve synthetic outside content",
      "unsafe destination touched outside content")
passed("unsafe receiver destination refuses put and absent without touching its target")

for action in ("put", "absent"):
    case = fixture("legacy-" + action)
    env = {"FM_INHERITABLE_CONFIG": LEGACY_ITEMS}
    expect(receive(case, action, payload=PAYLOAD if action == "put" else b"",
                   digest=HASH if action == "put" else EMPTY_HASH, env=env),
           1, b"path is not inherited material: config/spawn-capacity")
    expect(seed(case), 0)
    if action == "put":
        (case["parent"] / "config/spawn-capacity").write_bytes(PAYLOAD)
    expect(run(case, "fm-spawn.sh", ("bootstrap", "--secondmate", "--harness", "codex"),
               {"TEST_BOOTSTRAP_LEGACY": "1"}), 1, b"inheritance failed")
    relevant = [c for c in calls(case) if c[0] == "fm-remote-inherit.sh" and c[2] == "config/spawn-capacity"]
    check(len(relevant) == 1 and relevant[0][1] == action, "parent never attempted legacy capacity transfer")
    no_endpoint(case)
    passed(f"older receiver rejects capacity {action} before public spawn can record/start an endpoint")

for name, evidence in (("capacity-refusal", '{"ok":false,"reasons":["synthetic no headroom"]}'),
                       ("capacity-malformed", 'not-json')):
    case = fixture(name)
    router = case["path"] / "router"
    router.write_text("#!" + SHELL + "\nprintf '%s\\n' '" + evidence + "'\n")
    router.chmod(0o755)
    expect(run(case, "fm-spawn.sh", ("bootstrap", "--secondmate", "--harness", "codex"),
               {"FM_LLM_ROUTER_AXI": str(router)}), 1)
    check(not calls(case), "capacity refusal reached transport")
    no_endpoint(case)
    check(not list((case["parent"] / "state").iterdir()), "capacity refusal mutated task state")
    passed(name + " remains before task state or remote transport mutation")

print("ALL TESTS PASSED")
PY

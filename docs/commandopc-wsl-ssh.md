# commandopc WSL SSH landing

This records the host-specific SSH route into the Ubuntu-24.04 distro on commandopc.
It is operator reference for one machine, not a general pattern.
The general remote-secondmate prerequisites still live in [remote-secondmates.md](remote-secondmates.md).

## Route

`ssh commandopc` lands in Windows PowerShell and can never serve a POSIX bootstrap.
The working POSIX landing is the separate alias `commandopc-wsl`, which reaches sshd inside Ubuntu-24.04 (account `adi`) through a single Windows portproxy rule from the alias port to the distro's port 22.
Ubuntu-24.04 is the target because it has a real user account, while the default `Ubuntu` distro is root-only with no regular user.
Port 2222 stays reserved for the omarchy QEMU forward and is never used here.

## What exists, and where

Inside Ubuntu-24.04: the `openssh-server` package, enabled and active through the distro's systemd unit, with host keys generated at install time.
The Mac's existing `commandopc` public key is also authorized for `adi` there, so no new key material was introduced.
On the Windows side: exactly one added portproxy rule (the alias port to the distro's current NAT address, port 22) and exactly one added inbound firewall allow rule for that alias port, following the host's existing one-rule-per-port pattern.
On the Mac: a `Host commandopc-wsl` entry in the normal OpenSSH config pointing at the same Windows address as `commandopc` but on the alias port.
The pre-existing portproxy rules, the Hermes install and its firewall rule, the Windows sshd, and the omarchy scheduled task were not touched.

## Restart fragility

WSL2 NAT reassigns the distro's private address on (almost) every Windows restart, which strands the portproxy rule at the previous address with no error at rule scope.
After any commandopc restart, or whenever the alias stops answering, re-point the one rule with `bin/fm-commandopc-wsl-portproxy-refresh.sh`; its header owns the exact converge and `--check` contract.
Mirrored WSL networking would remove this drift, but it changes host-wide networking behavior, so it stays an explicit future decision rather than a silent default.
Further bootstrap and any seeding on this route remain separate follow-up work outside this task.
Seeding itself stays owned by secondmate-provisioning.

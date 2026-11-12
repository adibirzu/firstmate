#!/usr/bin/env python3
"""Deterministic reconciliation planner and digest builder for fm-task-sync.sh."""

from __future__ import annotations

import json
import pathlib
import re
import sys

SAFE_REPO_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
READY_STATES = {"todo", "unstarted", "ready"}
ALLOWED_READY_STATE_TYPES = {"", "unstarted"}


def slugify(val: str) -> str:
    return re.sub(r"[^a-z0-9-]+", "-", val.strip().lower()).strip("-")


def load_json(path_str: str) -> dict:
    p = pathlib.Path(path_str)
    if not p.is_file():
        return {}
    try:
        val = json.loads(p.read_text(encoding="utf-8"))
        return val if isinstance(val, dict) else {}
    except Exception:
        return {}


def safe_repo_basename(repo_val: str, fallback_val: str = "") -> str:
    candidate = repo_val.strip()
    if "/" in candidate:
        candidate = candidate.rsplit("/", 1)[-1].strip()
    if not candidate and fallback_val.strip():
        fb = fallback_val.strip()
        candidate = fb.rsplit("/", 1)[-1].strip() if "/" in fb else fb
    if not candidate or candidate in {".", ".."} or not SAFE_REPO_RE.fullmatch(candidate):
        return ""
    return candidate


def sanitize_tsv_field(val: str) -> str:
    return val.replace("\t", " ").replace("\r", " ").replace("\n", " ").strip()


def is_adi0_target(target: str) -> bool:
    norm = target.strip().lower()
    return not norm or norm == "adi0" or norm.startswith("adi0-")


def is_ocd_or_fenced(item: dict) -> tuple[bool, str, str]:
    ident = str(
        item.get("identifier")
        or item.get("linearIdentifier")
        or item.get("cybId")
        or item.get("id")
        or ""
    ).strip()
    upper_id = ident.upper()
    host = str(
        item.get("custodyHost")
        or item.get("fencedBy")
        or item.get("host")
        or ""
    ).strip().lower()
    exec_target = str(item.get("executionTarget") or "").strip().lower()
    status = str(item.get("status") or item.get("state") or "").strip().lower()
    branch = str(item.get("branch") or item.get("branchName") or "").strip().lower()
    labels = " ".join(str(x) for x in (item.get("labels") or [])).lower()

    if item.get("fenced") is True or status.startswith("fenced"):
        return True, host or "adrians-macbook-pro", str(item.get("reason") or "Fenced external custody")
    if not is_adi0_target(exec_target):
        return True, exec_target, f"Fenced execution target ({exec_target})"
    if (
        host == "adrians-macbook-pro"
        or branch.startswith("wip/adrians-macbook-pro/")
        or "adrians-macbook-pro" in labels
    ):
        return True, "adrians-macbook-pro", "Active custody on adrians-macbook-pro"
    if upper_id.startswith("OCD-") or "/OCD-" in upper_id or re.search(r"\bOCD-\d+\b", upper_id):
        return True, "adrians-macbook-pro", "ReviewForge primary custody on adrians-macbook-pro"
    return False, "", ""


def is_ready_state(item: dict) -> bool:
    raw_state = item.get("state") or item.get("status") or "todo"
    if isinstance(raw_state, dict):
        stype = str(raw_state.get("type") or "").strip().lower()
        sname = str(raw_state.get("name") or "todo").strip().lower()
        return stype in ALLOWED_READY_STATE_TYPES and sname in READY_STATES
    stype = str(item.get("stateType") or "").strip().lower()
    if stype not in ALLOWED_READY_STATE_TYPES:
        return False
    sname = str(raw_state).strip().lower()
    return sname in READY_STATES


def strip_id_prefix(ident: str, raw_title: str) -> str:
    cleaned = re.sub(r"^\s*\[(?:CYB|OCD)-\d+\]\s*", "", raw_title.strip(), flags=re.IGNORECASE)
    return sanitize_tsv_field(cleaned or ident.upper())


def cmd_plan(args: list[str]) -> int:
    (
        pc_status,
        pc_path,
        lin_path,
        rf_path,
        data_dir_str,
        projects_dir,
        cyb_map_path,
        project_filter,
        initiative_filter,
        limit_raw,
        plan_out_path,
    ) = args[:11]

    limit = int(limit_raw)
    proj_filter_slug = slugify(project_filter) if project_filter.strip() else ""
    init_filter_norm = initiative_filter.strip().lower()

    repo_meta: dict[str, tuple[str, str]] = {}
    cyb_map = load_json(cyb_map_path)
    for p in cyb_map.get("projects") or []:
        if not isinstance(p, dict):
            continue
        pslug = slugify(str(p.get("slug") or p.get("name") or ""))
        pinit = str(p.get("initiative") or p.get("initiativeId") or "").strip()
        all_repos = list(p.get("repos") or [])
        if p.get("primaryRepo"):
            all_repos.append(str(p["primaryRepo"]))
        for r in all_repos:
            if isinstance(r, str) and r.strip():
                repo_meta[r.strip().lower()] = (pslug, pinit)
                repo_meta[r.strip().rsplit("/", 1)[-1].lower()] = (pslug, pinit)

    def candidate_slugs(item: dict) -> set[str]:
        slugs: set[str] = set()
        for key in ("projectSlug", "project", "projectName", "projectId", "orgSlug"):
            raw = str(item.get(key) or "").strip()
            if raw:
                slugs.add(slugify(raw))
        for rkey in ("repo", "primaryRepo"):
            raw_r = str(item.get(rkey) or "").strip()
            if raw_r:
                slugs.add(slugify(raw_r))
                short = safe_repo_basename(raw_r)
                if short:
                    slugs.add(slugify(short))
                    mapped = repo_meta.get(raw_r.lower()) or repo_meta.get(short.lower())
                    if mapped and mapped[0]:
                        slugs.add(mapped[0])
        return {s for s in slugs if s}

    def resolve_initiative(item: dict) -> str:
        direct = str(item.get("initiative") or item.get("initiativeId") or "").strip()
        if direct:
            return direct
        for rkey in ("repo", "primaryRepo"):
            raw_r = str(item.get(rkey) or "").strip()
            if raw_r:
                mapped = repo_meta.get(raw_r.lower()) or repo_meta.get(raw_r.rsplit("/", 1)[-1].lower())
                if mapped and mapped[1]:
                    return mapped[1]
        return ""

    def matches_filters(item: dict) -> bool:
        if proj_filter_slug and proj_filter_slug not in candidate_slugs(item):
            return False
        if init_filter_norm and resolve_initiative(item).strip().lower() != init_filter_norm:
            return False
        return True

    fenced_map: dict[str, dict] = {}
    ready_items: list[dict] = []
    open_prs: list[dict] = []
    merged_prs: list[dict] = []
    explicit_fleet_repos: list[str] = []
    orgs: list[dict] = []

    if pc_status == "ok":
        pc_raw = load_json(pc_path)
        payload = pc_raw.get("data") if isinstance(pc_raw.get("data"), dict) else pc_raw
        orgs = list(payload.get("orgs") or [])
        for r in payload.get("fleetSyncRepos") or []:
            if isinstance(r, str) and r.strip():
                explicit_fleet_repos.append(r.strip())
        raw_fenced = (
            payload.get("fenced")
            or payload.get("fencedItems")
            or payload.get("custodyFence")
            or []
        )
        for f in raw_fenced:
            if isinstance(f, str):
                fenced_map[f] = {
                    "identifier": f,
                    "host": "adrians-macbook-pro",
                    "reason": "Active custody on adrians-macbook-pro",
                }
            elif isinstance(f, dict):
                fid = str(f.get("identifier") or f.get("linearIdentifier") or f.get("id") or "").strip()
                if fid:
                    fenced_map[fid] = {
                        "identifier": fid,
                        "host": str(f.get("host") or f.get("fencedBy") or f.get("custodyHost") or "adrians-macbook-pro"),
                        "reason": str(f.get("reason") or "Active custody on adrians-macbook-pro"),
                    }

        raw_ready = (
            payload.get("readyTasks")
            or payload.get("readyQueue")
            or payload.get("ready")
            or payload.get("unblocked")
            or payload.get("issues")
            or []
        )
        for item in raw_ready:
            if not isinstance(item, dict):
                continue
            fenced_flag, fence_host, reason = is_ocd_or_fenced(item)
            ident = str(
                item.get("identifier")
                or item.get("linearIdentifier")
                or item.get("cybId")
                or item.get("id")
                or ""
            ).strip()
            if fenced_flag:
                if ident:
                    fenced_map.setdefault(
                        ident,
                        {
                            "identifier": ident,
                            "host": fence_host or "adrians-macbook-pro",
                            "reason": reason,
                        },
                    )
                continue
            if not ident or not re.match(r"^CYB-\d+$", ident.upper()):
                continue
            if not matches_filters(item) or not is_ready_state(item):
                continue
            repo_val = str(item.get("repo") or item.get("primaryRepo") or "")
            proj_val = str(item.get("project") or item.get("projectSlug") or "")
            repo_short = safe_repo_basename(repo_val, proj_val)
            if not repo_short:
                continue
            prio = item.get("priority")
            prio_int = prio if isinstance(prio, int) and 0 <= prio <= 4 else 2
            ready_items.append(
                {
                    "identifier": ident.upper(),
                    "taskId": ident.lower(),
                    "title": strip_id_prefix(ident, str(item.get("title") or ident.upper())),
                    "repo": sanitize_tsv_field(repo_val),
                    "repoShort": repo_short,
                    "project": sanitize_tsv_field(proj_val or repo_short),
                    "initiative": sanitize_tsv_field(resolve_initiative(item)),
                    "priority": prio_int,
                    "executionTarget": "adi0",
                }
            )

        seen_open_urls: set[str] = set()
        for pr in payload.get("openPrs") or payload.get("open_prs") or payload.get("inReview") or []:
            if isinstance(pr, dict) and matches_filters(pr):
                url = str(pr.get("url") or "").strip()
                if url:
                    seen_open_urls.add(url)
                open_prs.append(
                    {
                        "identifier": str(pr.get("identifier") or pr.get("linearIdentifier") or ""),
                        "repo": str(pr.get("repo") or ""),
                        "number": pr.get("number"),
                        "url": url,
                        "ciStatus": str(pr.get("ciStatus") or pr.get("ciState") or pr.get("ci") or "unknown"),
                    }
                )

        for mut in payload.get("mutations") or []:
            if not isinstance(mut, dict):
                continue
            url = str(mut.get("githubPrUrl") or "").strip()
            m_gh = re.match(r"^https?://github\.com/([^/]+/[^/]+)/pull/\d+", url)
            mut_repo = m_gh.group(1) if m_gh else ""
            mut_probe = {
                "orgSlug": mut.get("orgSlug") or "",
                "projectSlug": mut.get("projectSlug") or "",
                "repo": mut_repo,
            }
            if not matches_filters(mut_probe):
                continue
            target_status = str(mut.get("targetStatus") or "").strip().lower()
            if url and target_status in ("in_review", "in review") and url not in seen_open_urls:
                seen_open_urls.add(url)
                open_prs.append(
                    {
                        "identifier": str(mut.get("linearIdentifier") or ""),
                        "repo": mut_repo,
                        "number": None,
                        "url": url,
                        "ciStatus": str(mut.get("ciState") or "unknown").lower(),
                    }
                )

        for pr in payload.get("mergedPrs") or payload.get("merged_prs") or payload.get("merged") or []:
            if isinstance(pr, dict) and matches_filters(pr):
                merged_prs.append(
                    {
                        "identifier": str(pr.get("identifier") or pr.get("linearIdentifier") or ""),
                        "repo": str(pr.get("repo") or ""),
                        "number": pr.get("number"),
                        "url": str(pr.get("url") or ""),
                    }
                )
    else:
        lin_raw = load_json(lin_path)
        lin_data = lin_raw.get("data") if isinstance(lin_raw.get("data"), dict) else {}
        for repo_plan in lin_data.get("repos") or []:
            if not isinstance(repo_plan, dict):
                continue
            repo_slug = str(repo_plan.get("repo") or "")
            proj_name = str(repo_plan.get("projectName") or "")
            repo_init = str(repo_plan.get("initiative") or repo_plan.get("initiativeId") or "")
            for matched in repo_plan.get("matched") or []:
                if not isinstance(matched, dict):
                    continue
                fenced_flag, fence_host, reason = is_ocd_or_fenced(matched)
                raw_ident = str(
                    matched.get("linearIdentifier")
                    or matched.get("identifier")
                    or ""
                ).strip()
                if fenced_flag:
                    if raw_ident:
                        fenced_map.setdefault(
                            raw_ident,
                            {
                                "identifier": raw_ident,
                                "host": fence_host or "adrians-macbook-pro",
                                "reason": reason,
                            },
                        )
                    continue
                ident = raw_ident.upper()
                if not re.match(r"^CYB-\d+$", ident):
                    continue
                candidate = {
                    "identifier": ident,
                    "repo": repo_slug,
                    "project": proj_name,
                    "initiative": matched.get("initiative") or repo_init,
                    "state": matched.get("state", "todo"),
                    "stateType": matched.get("stateType", ""),
                }
                if not matches_filters(candidate) or not is_ready_state(candidate):
                    continue
                repo_short = safe_repo_basename(repo_slug, proj_name)
                if not repo_short:
                    continue
                ready_items.append(
                    {
                        "identifier": ident,
                        "taskId": ident.lower(),
                        "title": strip_id_prefix(ident, str(matched.get("ghTitle") or matched.get("title") or ident)),
                        "repo": sanitize_tsv_field(repo_slug),
                        "repoShort": repo_short,
                        "project": sanitize_tsv_field(proj_name or repo_short),
                        "initiative": sanitize_tsv_field(resolve_initiative(candidate)),
                        "priority": 2,
                        "executionTarget": "adi0",
                    }
                )

    rf_raw = load_json(rf_path)
    for host_entry in rf_raw.get("hosts") or []:
        if not isinstance(host_entry, dict):
            continue
        if str(host_entry.get("host") or "").strip().lower() == "adrians-macbook-pro":
            for active in host_entry.get("active_issues") or []:
                label = str(active).strip()
                if label:
                    fenced_map.setdefault(
                        label,
                        {
                            "identifier": label,
                            "host": "adrians-macbook-pro",
                            "reason": "ReviewForge primary custody on adrians-macbook-pro",
                        },
                    )

    seen_ready: set[str] = set()
    deduped_ready: list[dict] = []
    fenced_keys_upper: set[str] = set()
    for fk in fenced_map:
        fenced_keys_upper.add(fk.upper())
        for tok in re.findall(r"\b(?:CYB|OCD)-\d+\b", fk, flags=re.IGNORECASE):
            fenced_keys_upper.add(tok.upper())
    for item in sorted(ready_items, key=lambda r: (r["priority"], r["identifier"])):
        ident = item["identifier"]
        if ident in seen_ready or ident in fenced_keys_upper:
            continue
        seen_ready.add(ident)
        deduped_ready.append(item)

    data_dir = pathlib.Path(data_dir_str)
    candidate_paths: list[pathlib.Path] = [data_dir / "backlog.md", data_dir / "done-archive.md"]
    for toml_cand in (data_dir / ".tasks.toml", data_dir.parent / ".tasks.toml"):
        if not toml_cand.is_file():
            continue
        raw_toml = toml_cand.read_text(encoding="utf-8", errors="replace")
        parsed_toml: dict = {}
        try:
            import tomllib  # type: ignore[import-not-found]
            parsed_toml = tomllib.loads(raw_toml)
        except Exception:
            parsed_toml = {}
        md_sec = parsed_toml.get("markdown") if isinstance(parsed_toml.get("markdown"), dict) else {}
        for key_val in (
            md_sec.get("path"),
            md_sec.get("archive"),
            parsed_toml.get("archive_file"),
        ):
            if isinstance(key_val, str) and key_val.strip():
                rel = pathlib.Path(key_val.strip())
                candidate_paths.append(toml_cand.parent / rel)
                if rel.name not in {".", "..", ""}:
                    candidate_paths.append(data_dir / rel.name)
        if not md_sec:
            for m_kv in re.finditer(
                r'^\s*(?:path|archive|archive_file)\s*=\s*"([^"]+)"',
                raw_toml,
                flags=re.MULTILINE,
            ):
                rel = pathlib.Path(m_kv.group(1).strip())
                candidate_paths.append(toml_cand.parent / rel)
                if rel.name not in {".", "..", ""}:
                    candidate_paths.append(data_dir / rel.name)
        break

    existing_text = ""
    seen_bpaths: set[pathlib.Path] = set()
    for bp in candidate_paths:
        try:
            resolved_bp = bp.resolve()
        except Exception:
            resolved_bp = bp
        if resolved_bp not in seen_bpaths and bp.is_file():
            seen_bpaths.add(resolved_bp)
            existing_text += "\n" + bp.read_text(encoding="utf-8", errors="replace")

    existing_cyb = {m.upper() for m in re.findall(r"\bCYB-\d+\b", existing_text, flags=re.IGNORECASE)}
    existing_ids = {
        m.lower()
        for m in re.findall(r"^- \[[ xX]\] ([A-Za-z0-9._-]+)\b", existing_text, flags=re.MULTILINE)
    }

    to_queue: list[dict] = []
    for item in deduped_ready:
        if item["identifier"] in existing_cyb or item["taskId"] in existing_ids:
            continue
        to_queue.append(item)
        if limit > 0 and len(to_queue) >= limit:
            break

    cloned_merged_repos: list[str] = []
    seen_repos: set[str] = set()
    projects_root = pathlib.Path(projects_dir).resolve()
    filtered_explicit_repos = [
        r for r in explicit_fleet_repos if matches_filters({"repo": r})
    ]
    for raw_repo in [str(pr.get("repo") or "") for pr in merged_prs] + filtered_explicit_repos:
        short = safe_repo_basename(raw_repo)
        if not short or short in seen_repos:
            continue
        candidate_dir = (projects_root / short).resolve()
        if candidate_dir.parent == projects_root and candidate_dir.is_dir():
            seen_repos.add(short)
            cloned_merged_repos.append(short)

    plan = {
        "orgs": orgs,
        "readyQueue": deduped_ready,
        "toQueue": to_queue,
        "openPrs": open_prs,
        "mergedPrs": merged_prs,
        "fenced": sorted(fenced_map.values(), key=lambda x: x["identifier"]),
        "clonedMergedRepos": cloned_merged_repos,
    }
    pathlib.Path(plan_out_path).write_text(json.dumps(plan, indent=2) + "\n", encoding="utf-8")
    return 0


def cmd_receipt(args: list[str]) -> int:
    (
        mode,
        coding_host,
        pc_status,
        fallback_status,
        project_filter,
        initiative_filter,
        plan_path,
        added_path,
        synced_repos_path,
        warnings_path,
        receipt_out,
        digest_out,
        generated_at,
    ) = args[:13]

    plan = json.loads(pathlib.Path(plan_path).read_text(encoding="utf-8"))
    added = [
        json.loads(line)
        for line in pathlib.Path(added_path).read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    synced_repos = [
        line.strip()
        for line in pathlib.Path(synced_repos_path).read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    warnings = [
        line.strip()
        for line in pathlib.Path(warnings_path).read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]

    ready_queue = plan.get("readyQueue", [])
    open_prs = plan.get("openPrs", [])
    merged_prs = plan.get("mergedPrs", [])
    fenced = plan.get("fenced", [])

    mutation_warnings = [
        w
        for w in warnings
        if w.startswith("BACKLOG_ADD_WARNING:") or w.startswith("FLEET_SYNC_WARNING:")
    ]

    lines: list[str] = []
    scope_label = f" for {project_filter}" if project_filter else ""
    if pc_status != "ok" and fallback_status != "ok":
        lines.append(
            f"Task synchronization{scope_label} degraded because both Paperclip and the Linear fallback were unavailable ({len(fenced)} fenced custody item(s) still tracked)."
        )
    elif mode == "apply" and mutation_warnings:
        lines.append(
            f"Development tasks{scope_label} partially synchronized with {len(mutation_warnings)} local update warning(s) ({len(ready_queue)} ready on adi0, {len(added)} newly queued)."
        )
    elif mode == "apply":
        lines.append(
            f"Development tasks{scope_label} synchronized across Linear, GitHub, and the fleet queue ({len(ready_queue)} ready on adi0, {len(added)} newly queued)."
        )
    else:
        lines.append(
            f"Task synchronization preview{scope_label} ready ({len(ready_queue)} ready for adi0, {len(plan.get('toQueue', []))} new to queue)."
        )

    if pc_status != "ok":
        if fallback_status == "ok":
            lines.append(
                "- Control board note: Paperclip over Tailscale was temporarily unreachable, so Linear and cross-Mac custody records were reconciled directly."
            )
        else:
            lines.append(
                "- Control board warning: Paperclip over Tailscale and the Linear fallback were both unreachable; local backlog state was left unchanged."
            )

    for mw in mutation_warnings:
        clean_mw = mw.split(":", 1)[1].strip() if ":" in mw else mw
        lines.append(f"- Local update issue requiring attention: {clean_mw}.")

    if added:
        queued_labels = ", ".join(f"{x['identifier']} ({x['repo']})" for x in added[:6])
        lines.append(f"- Newly queued for adi0: {queued_labels}.")
    elif ready_queue:
        top_labels = ", ".join(f"{x['identifier']} ({x['repoShort']})" for x in ready_queue[:5])
        lines.append(f"- Ready queue on adi0: {top_labels}.")

    if synced_repos:
        lines.append(f"- Refreshed local project copies after merged PRs: {', '.join(synced_repos)}.")

    if open_prs:
        for pr in open_prs:
            url = pr.get("url") or pr.get("identifier") or pr.get("repo")
            ci = pr.get("ciStatus") or "pending"
            ident = f" ({pr['identifier']})" if pr.get("identifier") else ""
            lines.append(f"- Open PR awaiting explicit merge approval{ident}: {url} (checks: {ci}).")

    if fenced:
        by_host: dict[str, list[str]] = {}
        for x in fenced:
            h = str(x.get("host") or "adrians-macbook-pro")
            by_host.setdefault(h, []).append(str(x["identifier"]))
        for h, ids in sorted(by_host.items()):
            lines.append(
                f"- Fenced on {h} (left untouched, never dispatched on adi0): {', '.join(ids[:8])}."
            )

    digest_text = "\n".join(lines) + "\n"
    pathlib.Path(digest_out).write_text(digest_text, encoding="utf-8")

    receipt = {
        "schema": "fm-task-sync.v1",
        "generatedAt": generated_at,
        "mode": mode,
        "codingHost": coding_host,
        "paperclipStatus": pc_status,
        "fallbackStatus": fallback_status,
        "filters": {
            "project": project_filter or None,
            "initiative": initiative_filter or None,
        },
        "warnings": warnings,
        "counts": {
            "readyQueue": len(ready_queue),
            "plannedBacklogAdds": len(plan.get("toQueue", [])),
            "backlogAdded": len(added),
            "openPrs": len(open_prs),
            "mergedPrs": len(merged_prs),
            "fenced": len(fenced),
            "fleetSyncedRepos": len(synced_repos),
        },
        "readyQueue": ready_queue,
        "backlogAdded": added,
        "openPrs": open_prs,
        "mergedPrs": merged_prs,
        "fenced": fenced,
        "fleetSyncedRepos": synced_repos,
        "captainDigest": digest_text.rstrip("\n"),
    }
    pathlib.Path(receipt_out).write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        return 2
    sub = sys.argv[1]
    if sub == "plan":
        return cmd_plan(sys.argv[2:])
    if sub == "receipt":
        return cmd_receipt(sys.argv[2:])
    return 2


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Resolve the target env, deploy job, and approval gate from a CircleCI
workflow's job list (the JSON body of GET /workflow/{id}/job on stdin).

Default mode — prints a single tab-separated line to stdout:
    <env>\t<deploy_job>\t<approval_job>
(approval_job may be empty if the workflow has no manual gate.)

Cascade mode (env var EMIT_CHAIN=1) — prints the ordered prerequisite chain
that must be deployed to reach the target, derived from the job dependency
graph. One line per stage, earliest first, the target stage last:
    ENV\t<target_env>
    STAGE\t<env>\t<approval_job>\t<deploy_job>
    STAGE\t<env>\t<approval_job>\t<deploy_job>
    ...
(approval_job is empty for a stage with no manual gate.) A single-environment
workflow yields exactly one STAGE line, so cascade mode is a strict superset of
the default single-env behaviour.

Exit codes match the deploy.sh contract:
    0   resolved
    4   no deploy job for the requested env / no deploy job at all
    9   ambiguous match (multiple deploy or approval jobs) — caller must
        re-run with --deploy-job / --approval-job
    10  env omitted and multiple deploy environments exist — caller must ask
        the user which one (env list printed to stderr as DEPLOY_ENVS=a,b,c)

Inputs come from the environment:
    ENV_NAME, DEPLOY_OVERRIDE, APPROVAL_OVERRIDE, EMIT_CHAIN
"""
import json
import os
import re
import sys

KW = re.compile(r"(?:^|[-_])(?:deploy|release|ship|publish)(?:$|[-_])", re.I)
KWSET = {"deploy", "release", "ship", "publish"}


def env_token(name):
    """The environment portion of a deploy job name (keyword tokens removed)."""
    toks = re.split(r"[-_]", name)
    rest = [t for t in toks if t.lower() not in KWSET]
    return "_".join(rest)


def die(code, *msg):
    for m in msg:
        sys.stderr.write(m + "\n")
    sys.exit(code)


def resolve_target(jobs, env, deploy_override, approval_override):
    """Resolve (env, deploy_job, approval_job) for the requested target.

    Exits 4/9/10 on the same conditions as the original single-env resolver."""
    names = [j.get("name", "") for j in jobs]
    approval_names = [j.get("name", "") for j in jobs if j.get("type") == "approval"]
    deploy_jobs = [n for n in names if KW.search(n)]

    # --- deploy job ---
    if deploy_override:
        deploy_job = deploy_override
        if not env:
            env = env_token(deploy_override)
    elif env:
        matches = [
            n for n in deploy_jobs
            if env.lower() == env_token(n).lower()
            or env.lower() in [t.lower() for t in re.split(r"[-_]", n)]
        ]
        if not matches:
            matches = [n for n in deploy_jobs if env.lower() in n.lower()]
        if len(matches) == 0:
            die(4, "No deploy job for env '%s'. Deploy jobs seen: %s"
                % (env, deploy_jobs or "(none)"))
        if len(matches) > 1:
            die(9, "Multiple deploy jobs match env '%s': %s" % (env, matches),
                   "Re-run with --deploy-job <name> (and --approval-job if needed).")
        deploy_job = matches[0]
    else:
        envs = sorted(set(env_token(n) for n in deploy_jobs if env_token(n)))
        if len(envs) == 0:
            die(4, "No deploy job found in this workflow.")
        if len(envs) > 1:
            sys.stderr.write("DEPLOY_ENVS=" + ",".join(envs) + "\n")
            die(10, "Multiple deploy environments available: %s" % envs,
                    "Caller should ask the user which environment to deploy.")
        env = envs[0]
        deploy_job = [n for n in deploy_jobs if env_token(n) == env][0]

    # --- approval gate (single-line/legacy hint only) ---
    # The authoritative gate set per stage is derived from the dependency graph in
    # build_chain(), which handles stages that sit behind SEVERAL sequential gates
    # (e.g. a build-approval then a deploy-approval). So multiple env-matching gates
    # is NOT an ambiguity here — we just leave this legacy single-gate hint empty
    # and let the chain resolve every gate in order. An explicit --approval-job
    # still wins (and overrides the target stage's gate list in main()).
    if approval_override:
        approval_job = approval_override
    else:
        env_appr = [n for n in approval_names if env and env.lower() in n.lower()]
        if len(env_appr) == 1:
            approval_job = env_appr[0]
        elif len(env_appr) > 1:
            approval_job = ""        # multiple gates → defer to build_chain
        elif len(approval_names) == 1:
            approval_job = approval_names[0]
        else:
            approval_job = ""

    return env, deploy_job, approval_job


def build_chain(jobs, target_deploy):
    """Return the ordered list of (env, gates, deploy_job) stages that are
    prerequisites of (and including) target_deploy, derived purely from the job
    dependency graph. Earliest first, target last.

    A stage is every deploy-shaped job among target_deploy's transitive ancestors
    (plus the target itself). `gates` is the ORDERED list of every approval-type
    job that this stage must clear — i.e. the approval jobs among the stage's own
    transitive ancestors, excluding anything already owned by an earlier deploy
    stage — sorted earliest-gate-first by dependency depth.

    This generalises to any workflow shape without per-repo configuration:
      * one gate per deploy (the common `hold_x -> deploy_x`)  -> gates == [hold_x]
      * several SEQUENTIAL gates before a deploy
        (`hold_build_x -> build_x -> hold_x -> deploy_x`)       -> [hold_build_x, hold_x]
      * a deploy with NO gate (auto-deploy)                     -> []
      * cascaded stages (deploy_sat depends on deploy_dev)      -> each stage keeps
        only its own gates; dev's gate is not re-approved under sat.
    """
    by_id = {j.get("id"): j for j in jobs}
    by_name = {j.get("name"): j for j in jobs}
    target = by_name.get(target_deploy)
    if target is None:
        # Target not in the live job list yet — fall back to a single gateless stage.
        return [(env_token(target_deploy), [], target_deploy)]

    def ancestors_of(start_id):
        """Transitive ancestors of start_id, including start_id itself."""
        seen = set()
        stack = [start_id]
        while stack:
            jid = stack.pop()
            if jid in seen:
                continue
            seen.add(jid)
            for dep in (by_id.get(jid, {}).get("dependencies") or []):
                stack.append(dep)
        return seen

    # Memoised depth = longest path from a root, for topological ordering.
    depth_cache = {}

    def depth(jid):
        if jid in depth_cache:
            return depth_cache[jid]
        depth_cache[jid] = 0  # guard against cycles
        deps = by_id.get(jid, {}).get("dependencies") or []
        d = 0 if not deps else 1 + max(depth(x) for x in deps)
        depth_cache[jid] = d
        return d

    target_anc = ancestors_of(target.get("id"))

    # Deploy-shaped jobs on the path to the target (the stages), earliest first.
    deploy_ids = [
        jid for jid in target_anc
        if by_id.get(jid, {}).get("type") != "approval"
        and KW.search(by_id.get(jid, {}).get("name", ""))
    ]
    deploy_ids.sort(key=depth)

    stages = []
    for d_id in deploy_ids:
        d_anc = ancestors_of(d_id)
        # Jobs already owned by an EARLIER deploy stage in this stage's lineage —
        # so a cascaded prerequisite deploy's gates aren't re-approved here.
        claimed = set()
        for e_id in deploy_ids:
            if e_id != d_id and e_id in d_anc:
                claimed |= ancestors_of(e_id)
        local = d_anc - claimed
        gate_ids = [g for g in local if by_id.get(g, {}).get("type") == "approval"]
        gate_ids.sort(key=depth)
        gates = [by_id[g].get("name", "") for g in gate_ids]
        stages.append((env_token(by_id[d_id].get("name", "")), gates, by_id[d_id].get("name", "")))

    return stages


def main():
    data = json.load(sys.stdin)
    jobs = data.get("items", [])

    env = os.environ.get("ENV_NAME", "").strip()
    deploy_override = os.environ.get("DEPLOY_OVERRIDE", "").strip()
    approval_override = os.environ.get("APPROVAL_OVERRIDE", "").strip()

    env, deploy_job, approval_job = resolve_target(
        jobs, env, deploy_override, approval_override)

    if os.environ.get("EMIT_CHAIN", "").strip() in ("1", "true", "yes"):
        chain = build_chain(jobs, deploy_job)
        # An explicit --approval-job pins the TARGET (last) stage to that one gate.
        if approval_override and chain:
            env_last, _gates, dep_last = chain[-1]
            chain[-1] = (env_last, [approval_override], dep_last)
        sys.stdout.write("ENV\t%s\n" % env)
        for stage_env, gates, deploy in chain:
            # gates joined by ',' — CircleCI job names never contain a comma.
            sys.stdout.write("STAGE\t%s\t%s\t%s\n" % (stage_env, ",".join(gates), deploy))
    else:
        sys.stdout.write("%s\t%s\t%s\n" % (env, deploy_job, approval_job))


if __name__ == "__main__":
    main()

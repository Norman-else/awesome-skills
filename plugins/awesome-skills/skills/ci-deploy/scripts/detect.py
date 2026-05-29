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

    # --- approval gate ---
    if approval_override:
        approval_job = approval_override
    else:
        env_appr = [n for n in approval_names if env and env.lower() in n.lower()]
        if len(env_appr) == 1:
            approval_job = env_appr[0]
        elif len(env_appr) > 1:
            die(9, "Multiple approval gates match env '%s': %s" % (env, env_appr),
                   "Re-run with --approval-job <name>.")
        elif len(approval_names) == 1:
            approval_job = approval_names[0]
        else:
            approval_job = ""

    return env, deploy_job, approval_job


def build_chain(jobs, target_deploy):
    """Return the ordered list of (env, approval_job, deploy_job) stages that are
    prerequisites of (and including) target_deploy, derived from the dependency
    graph. Earliest first, target last.

    A stage is every deploy-shaped build job among target_deploy's transitive
    ancestors (plus the target itself); its gate is the approval-type job in its
    direct dependencies (empty if it has none)."""
    by_id = {j.get("id"): j for j in jobs}
    by_name = {j.get("name"): j for j in jobs}
    target = by_name.get(target_deploy)
    if target is None:
        # Target not in the live job list yet — fall back to a single stage.
        return [(env_token(target_deploy), "", target_deploy)]

    # Transitive ancestors of the target (the target itself included).
    ancestors = set()
    stack = [target.get("id")]
    while stack:
        jid = stack.pop()
        if jid in ancestors:
            continue
        ancestors.add(jid)
        for dep in (by_id.get(jid, {}).get("dependencies") or []):
            stack.append(dep)

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

    # Deploy-shaped build jobs on the path to the target.
    stages = []
    for jid in ancestors:
        j = by_id.get(jid, {})
        name = j.get("name", "")
        if j.get("type") == "approval" or not KW.search(name):
            continue
        gate = ""
        for dep in (j.get("dependencies") or []):
            dj = by_id.get(dep, {})
            if dj.get("type") == "approval":
                gate = dj.get("name", "")
                break
        stages.append((depth(jid), env_token(name), gate, name))

    stages.sort(key=lambda s: s[0])
    return [(env, gate, deploy) for _depth, env, gate, deploy in stages]


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
        sys.stdout.write("ENV\t%s\n" % env)
        for stage_env, gate, deploy in chain:
            sys.stdout.write("STAGE\t%s\t%s\t%s\n" % (stage_env, gate, deploy))
    else:
        sys.stdout.write("%s\t%s\t%s\n" % (env, deploy_job, approval_job))


if __name__ == "__main__":
    main()

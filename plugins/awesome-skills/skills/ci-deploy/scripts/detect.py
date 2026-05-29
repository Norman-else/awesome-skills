#!/usr/bin/env python3
"""Resolve the target env, deploy job, and approval gate from a CircleCI
workflow's job list (the JSON body of GET /workflow/{id}/job on stdin).

On success, prints a single tab-separated line to stdout:
    <env>\t<deploy_job>\t<approval_job>
(approval_job may be empty if the workflow has no manual gate.)

Exit codes match the deploy.sh contract:
    0   resolved
    4   no deploy job for the requested env / no deploy job at all
    9   ambiguous match (multiple deploy or approval jobs) — caller must
        re-run with --deploy-job / --approval-job
    10  env omitted and multiple deploy environments exist — caller must ask
        the user which one (env list printed to stderr as DEPLOY_ENVS=a,b,c)

Inputs come from the environment:
    ENV_NAME, DEPLOY_OVERRIDE, APPROVAL_OVERRIDE
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


def main():
    data = json.load(sys.stdin)
    jobs = data.get("items", [])
    names = [j.get("name", "") for j in jobs]
    approval_names = [j.get("name", "") for j in jobs if j.get("type") == "approval"]

    env = os.environ.get("ENV_NAME", "").strip()
    deploy_override = os.environ.get("DEPLOY_OVERRIDE", "").strip()
    approval_override = os.environ.get("APPROVAL_OVERRIDE", "").strip()

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

    sys.stdout.write("%s\t%s\t%s\n" % (env, deploy_job, approval_job))


if __name__ == "__main__":
    main()

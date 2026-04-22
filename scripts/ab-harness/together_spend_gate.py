"""Shared opt-in gate before Together.ai serverless (paid) inference.

Any script that calls Together chat-completions should invoke
``require_together_job_ref()`` once the CLI args are known and a Together
code path is active. CI / emergencies may set CHUMP_TOGETHER_ALLOW_UNTAGGED=1
(see docs/TOGETHER_SPEND.md).
"""

from __future__ import annotations

import os

_ENV_REF = "CHUMP_TOGETHER_JOB_REF"
_ENV_BYPASS = "CHUMP_TOGETHER_ALLOW_UNTAGGED"
_DOC = "docs/TOGETHER_SPEND.md"


def together_job_ref() -> str:
    return os.environ.get(_ENV_REF, "").strip()


def allow_untagged_together() -> bool:
    return os.environ.get(_ENV_BYPASS, "").strip().lower() in (
        "1",
        "true",
        "yes",
    )


def openai_base_looks_like_together() -> bool:
    base = (os.environ.get("OPENAI_API_BASE") or "").lower()
    return "together.xyz" in base or "together.ai" in base


def require_together_job_ref(context: str) -> None:
    """Exit with a clear message unless a budget ticket is wired in env."""
    if allow_untagged_together():
        return
    if together_job_ref():
        return
    raise SystemExit(
        "Together spend blocked: set a budget reference before running this job.\n"
        f"  export CHUMP_TOGETHER_JOB_REF='<Linear / Jira URL or ticket id>'\n"
        f"  Context: {context}\n"
        f"  How to request budget: {_DOC}\n"
        "  Emergency bypass (not for routine use): CHUMP_TOGETHER_ALLOW_UNTAGGED=1"
    )


def uses_together_model_prefix(model: str | None) -> bool:
    return bool(model) and model.startswith("together:")


def judge_list_uses_together(judges: list[str] | None) -> bool:
    if not judges:
        return False
    return any(j.startswith("together:") for j in judges)

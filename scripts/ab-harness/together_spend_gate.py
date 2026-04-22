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


def _lane_a_self_test() -> None:
    """Stdlib-only checks for CI / ``python together_spend_gate.py``."""
    assert not uses_together_model_prefix(None)
    assert not uses_together_model_prefix("claude-3-5-sonnet")
    assert uses_together_model_prefix("together:meta-llama/Llama-3.3-70B")

    assert not judge_list_uses_together(None)
    assert not judge_list_uses_together([])
    assert not judge_list_uses_together(["claude-sonnet-4-5"])
    assert judge_list_uses_together(["claude", "together:meta-llama/foo"])

    old_base = os.environ.pop("OPENAI_API_BASE", None)
    try:
        assert not openai_base_looks_like_together()
        os.environ["OPENAI_API_BASE"] = "https://api.together.xyz/v1"
        assert openai_base_looks_like_together()
    finally:
        if old_base is None:
            os.environ.pop("OPENAI_API_BASE", None)
        else:
            os.environ["OPENAI_API_BASE"] = old_base

    old_ref = os.environ.pop(_ENV_REF, None)
    old_bypass = os.environ.pop(_ENV_BYPASS, None)
    try:
        try:
            require_together_job_ref("lane-a self-test")
        except SystemExit as exc:
            msg = str(exc)
            assert "Together spend blocked" in msg
        else:  # pragma: no cover
            raise AssertionError("expected SystemExit when ref missing")

        os.environ[_ENV_REF] = "https://linear.app/example/issue/SELFTEST-1"
        require_together_job_ref("lane-a self-test with ref")
        del os.environ[_ENV_REF]

        os.environ[_ENV_BYPASS] = "1"
        require_together_job_ref("lane-a self-test bypass")
    finally:
        if old_ref is None:
            os.environ.pop(_ENV_REF, None)
        else:
            os.environ[_ENV_REF] = old_ref
        if old_bypass is None:
            os.environ.pop(_ENV_BYPASS, None)
        else:
            os.environ[_ENV_BYPASS] = old_bypass


if __name__ == "__main__":
    _lane_a_self_test()

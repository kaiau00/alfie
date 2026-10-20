"""The cheapest model the person's own provider serves, for work nobody is
waiting on — one helper for every background reader Moe runs on its own:
per-turn memory learning and its check (claimstore/learn_turn.py), the loop
sweep (moe-screen/sweep.py), the situations sensor (situations.py) and the
Composio planner (composio_items.py).

Why this exists (CLAUDE.md, "Moe is not Claude-specific"): Hermes's
``call_llm(task="classify")`` with nothing pinned is served, on a Claude
plan, by the Claude Code CLI lane at its default small model — and on every
other brain by the auxiliary auto chain, whose first step is the MAIN
provider and the MAIN model (agent/auxiliary_client.py, "Text auto chain:
main provider+model → …"). So on a ChatGPT plan, an OpenAI or OpenRouter key,
every background read ran on the model the person picked for conversation,
billed per call. Pinning the provider's cheapest model is what stops that.

The table is ``moe-home/hermes/model-tiers.json`` — the one
``configure-hermes.py cheapest_model_for`` and ``ModelTiers.swift`` read. A
provider missing from it (a custom endpoint, LM Studio, a local server) has
no list to choose from, so its background work stays on the model the person
chose: nothing is pinned and Hermes routes it to the main model, as before.

Never a vendor name in here: the table names models, per provider.
Stdlib only.
"""

from __future__ import annotations

import json
import logging
import os
import re
from typing import Any, Dict, List, Optional, Tuple

logger = logging.getLogger(__name__)

TIERS_FILE = "model-tiers.json"
#: The Hermes auxiliary task every caller uses. On a Claude brain it is one
#: of the text tasks the Claude Code CLI lane serves (claude_code_vision
#: TEXT_TASKS); elsewhere it is an ordinary auxiliary call.
TASK = "classify"


def tiers_paths() -> List[str]:
    """Where the table may be, first match wins: an explicit override; the
    installed payload ($MOE_HOME/hermes, where install.sh puts it beside
    configure-hermes.py); the away machine's home seed ($MOE_HOME/lib); and
    the repo layout beside this file (tests, a checkout)."""
    home = os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")
    here = os.path.dirname(os.path.abspath(__file__))
    out = []
    if os.environ.get("MOE_MODEL_TIERS"):
        out.append(os.environ["MOE_MODEL_TIERS"])
    out += [os.path.join(home, "hermes", TIERS_FILE), os.path.join(home, "lib", TIERS_FILE),
            os.path.join(here, TIERS_FILE), os.path.join(here, "..", "hermes", TIERS_FILE)]
    return out


def cheapest_models() -> Dict[str, str]:
    """provider id -> its cheapest model; {} when no table can be read."""
    for path in tiers_paths():
        try:
            with open(path, encoding="utf-8") as fh:
                table = json.load(fh).get("cheapest")
        except (OSError, ValueError, AttributeError):
            continue
        if isinstance(table, dict):
            return {k.strip(): v.strip() for k, v in table.items()
                    if isinstance(k, str) and isinstance(v, str) and k.strip() and v.strip()}
    return {}


def current_brain() -> Tuple[str, str]:
    """(provider, model) the person chose, as Hermes reads them; ("", "")
    when there is no Hermes to ask."""
    try:
        from agent import auxiliary_client as aux
        return (str(aux._read_main_provider() or "").strip(),
                str(aux._read_main_model_for_aux() or "").strip())
    except Exception:  # noqa: BLE001
        pass
    try:
        from hermes_cli.config import load_config_readonly
        model = (load_config_readonly() or {}).get("model") or {}
        if isinstance(model, dict):
            return (str(model.get("provider") or "").strip().lower(),
                    str(model.get("default") or "").strip())
    except Exception:  # noqa: BLE001
        pass
    return "", ""


def route(provider: Optional[str] = None, model: Optional[str] = None) -> Dict[str, str]:
    """What to pin for one background call: ``{"provider", "model"}`` with
    the provider's cheapest model, or ``{}`` — pin nothing, the person's own
    model serves — for a provider the table does not know."""
    if provider is None:
        provider, model = current_brain()
    provider = str(provider or "").strip()
    cheap = cheapest_models().get(provider) or cheapest_models().get(provider.lower())
    if not provider or not cheap:
        return {}
    return {"provider": provider, "model": cheap}


def call(messages, max_tokens: int = 500, timeout: float = 60, *, llm=None,
         provider: Optional[str] = None, model: Optional[str] = None) -> Any:
    """One background model call on the cheapest tier. ``llm`` is Hermes's
    ``call_llm`` (a seam for tests). A cheap model the provider says it does
    not serve (the table can go stale) is retried once on the person's own
    model, the fallback model-tiers.json documents, and said so in the log.
    Nothing else is: a rate limit, an outage or a network error on the cheap
    model is NOT a reason to spend the expensive one — under a 429, forty
    background calls a tick moved to the person's chosen model (review §15)."""
    if llm is None:
        from agent.auxiliary_client import call_llm as llm
    pin = route(provider, model)
    if not pin:
        return llm(task=TASK, messages=messages, max_tokens=max_tokens, timeout=timeout)
    try:
        return llm(task=TASK, provider=pin["provider"], model=pin["model"], messages=messages,
                   max_tokens=max_tokens, timeout=timeout)
    except Exception as e:  # noqa: BLE001
        if not _is_model_refusal(e):
            raise
        logger.info("cheap model: %s on %s refused (%s); using the chosen model once",
                    pin["model"], pin["provider"], type(e).__name__)
        return llm(task=TASK, provider=pin["provider"], messages=messages,
                   max_tokens=max_tokens, timeout=timeout)


_MODEL_REFUSAL = re.compile(
    r"(model[^\n]{0,80}?(not found|does not exist|doesn't exist|not supported|unsupported|unknown|"
    r"invalid|not available|unavailable to|no access|not allowed|is not enabled|deprecated|retired))|"
    r"((unknown|invalid|unsupported) model)|model_not_found|invalid_model", re.I)


def _is_model_refusal(e: BaseException) -> bool:
    """The provider refused the MODEL — not a rate limit, not an outage, not
    a timeout. By status where the error carries one (400/403/404 only) and
    by what it says."""
    status = getattr(e, "status_code", None) or getattr(e, "status", None) or getattr(
        getattr(e, "response", None), "status_code", None)
    try:
        status = int(status) if status is not None else None
    except (TypeError, ValueError):
        status = None
    if status is not None and status not in (400, 403, 404, 422):
        return False
    return bool(_MODEL_REFUSAL.search("%s %s" % (type(e).__name__, e)))



def call_chosen(messages, max_tokens: int = 1200, timeout: float = 180, *, llm=None,
                provider: Optional[str] = None, model: Optional[str] = None) -> Any:
    """One background call on the model the person CHOSE, for the rare work
    whose words they may send as their own (the situations preparer's draft,
    docs/PROACTIVE-MEMORY.md §4.7). Everything else background stays on
    `call`. Provider-agnostic the same way: whatever brain is in force."""
    if llm is None:
        from agent.auxiliary_client import call_llm as llm
    if provider is None:
        provider, model = current_brain()
    if provider and model:
        return llm(task=TASK, provider=provider, model=model, messages=messages,
                   max_tokens=max_tokens, timeout=timeout)
    return llm(task=TASK, messages=messages, max_tokens=max_tokens, timeout=timeout)

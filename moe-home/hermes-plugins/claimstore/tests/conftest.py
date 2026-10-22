"""Shared fixtures for the claimstore plugin tests.

The plugin ships as a standalone directory meant to be copied into
``$HERMES_HOME/plugins/``, so it is not importable as ``plugins.memory.*``.
Unit tests import it as a plain package off its parent directory; the
discovery test loads it the way Hermes actually would.

Run it from a hermes-agent checkout, which is where the imports it tests
against live::

    cd <hermes-agent> && ./scripts/run_tests.sh \\
        <moe>/moe-home/hermes-plugins/claimstore/tests
"""

import sys
from pathlib import Path

import pytest

PLUGIN_DIR = Path(__file__).resolve().parents[1]
SIBLING_DIR = PLUGIN_DIR.parent / "moe-ledger"

if str(PLUGIN_DIR.parent) not in sys.path:
    sys.path.insert(0, str(PLUGIN_DIR.parent))
# The sibling plugin's library (``moeledger``), the way the plugin itself
# finds it (``claimstore._sibling``): a top-level package off the moe-ledger
# directory, so a claim sealed here opens in the other suite's classes.
if str(SIBLING_DIR) not in sys.path:
    sys.path.insert(0, str(SIBLING_DIR))


@pytest.fixture(autouse=True)
def never_the_real_moe_home(tmp_path, monkeypatch):
    """A belt for the braces.

    Every fixture below passes an explicit ``ledger_dir``, but this file is
    one typo away from a test appending to a person's actual memory. ``MOE_HOME``
    is what ``resolve_ledger_dir`` falls back to, so it is pointed somewhere
    disposable for the whole suite.
    """
    monkeypatch.setenv("MOE_HOME", str(tmp_path / "not-the-real-moe"))
    # And not the real person's name: `project("user")` seeds it from the Mac
    # account, which on the owner's Mac put his name into every test ledger
    # the moment the seed existed. A test that wants one poses one.
    from claimstore import projection
    if not hasattr(projection, "account_full_name_unpatched"):
        projection.account_full_name_unpatched = projection.account_full_name
    monkeypatch.setattr(projection, "account_full_name", lambda: "")


@pytest.fixture
def hermes_home(tmp_path, monkeypatch):
    """An isolated HERMES_HOME with an empty memories directory."""
    home = tmp_path / "hermes"
    (home / "memories").mkdir(parents=True)
    monkeypatch.setenv("HERMES_HOME", str(home))
    return home


@pytest.fixture
def ledger_dir(tmp_path):
    """A ledger outside HERMES_HOME — which is the normal case, because the
    ledger belongs to Alfie and Hermes is one of several writers to it."""
    return tmp_path / "moe" / "ledger"


@pytest.fixture
def moe_home(tmp_path, monkeypatch):
    """The ``~/.moe`` the ledger above lives in — where ``CLAUDE.md`` and the
    profile files (§13.5 documents) are."""
    home = tmp_path / "moe"
    home.mkdir(parents=True, exist_ok=True)
    monkeypatch.setenv("MOE_HOME", str(home))
    return home


@pytest.fixture
def memory_key(ledger_dir):
    """A ``moe:memory`` key minted into ``<ledger dir>/thread-keys.json`` the
    way the app or the plugin would (§13.2), returned raw."""
    from moeledger.vault import Keyring

    return Keyring(ledger_dir / "thread-keys.json").mint_key("moe:memory")


@pytest.fixture
def provider(hermes_home, ledger_dir, monkeypatch):
    """An initialized provider with config stubbed out (no config.yaml I/O)."""
    import claimstore

    monkeypatch.setattr(
        claimstore, "_config",
        lambda: {"ledger_dir": str(ledger_dir), "targets": ["memory", "user"],
                 "recall_limit": 3},
    )
    p = claimstore.ClaimStoreProvider()
    p.initialize("session-1", hermes_home=str(hermes_home), platform="cli",
                 agent_context="primary")
    return p


@pytest.fixture
def memory_store(hermes_home):
    """A freshly loaded built-in MemoryStore, as the agent would build one."""
    def _build():
        from tools.memory_tool import MemoryStore

        store = MemoryStore()
        store.load_from_disk()
        return store

    return _build


@pytest.fixture(autouse=True)
def no_real_model_for_turn_learning(monkeypatch):
    """Per-turn learning (claimstore/learn_turn.py) calls Hermes's small model
    from ``sync_turn``. Under the Hermes venv that is a real call on the
    person's plan, and it learned a claim into another test's ledger the first
    time this suite ran with it. A test that wants the learner answers for it."""
    try:
        from claimstore import learn_turn
    except Exception:  # noqa: BLE001
        return
    monkeypatch.setattr(learn_turn, "default_call", lambda messages: "[]")

"""cli.py: the Memory page corrects and forgets Hermes's memory lines at
once, with ledger records, and the projection reflects it before it returns.

Falsifiers: make ``correct`` assert without retracting (the old line comes
back on the next projection), skip the projection (the file is stale until
the next session), or write a plaintext claim while the key is held — each
turns a test here red.
"""

from __future__ import annotations

import json
import subprocess
import sys

import pytest

from claimstore import cli, projection
from claimstore.store import ClaimStore, claim_id

from moeledger.records import decode_line


@pytest.fixture
def store(hermes_home, ledger_dir, memory_key, monkeypatch):
    monkeypatch.setattr("claimstore._config", lambda: {"ledger_dir": str(ledger_dir)})
    s = ClaimStore(ledger_dir, device="mac-9f3c1a2b", state_dir=hermes_home, key=memory_key)
    s.assert_claim("user", "Prefers I take action over explaining", source="hermes:assistant_tool")
    s.assert_claim("user", "Name: Alex Doe", source="hermes:assistant_tool")
    s.assert_claim("memory", "Invoices go out on the 1st", source="hermes:assistant_tool")
    projection.project_all(s, ["memory", "user"])
    return s


def user_md(hermes_home):
    return (hermes_home / "memories" / "USER.md").read_text(encoding="utf-8")


def run(store, *argv, capsys=None):
    rc = cli.main(list(argv), store=store)
    out = capsys.readouterr().out if capsys else ""
    return rc, (json.loads(out) if out.strip().startswith(("{", "[")) else out)


def test_list_gives_ids_the_page_can_address(store, capsys):
    rc, rows = run(store, "list", "--json", capsys=capsys)
    assert rc == 0
    assert [r["target"] for r in rows] == ["user", "user", "memory"]
    assert rows[1]["id"] == claim_id("user", "Name: Alex Doe")
    assert all(r["in_file"] for r in rows)


def test_correct_is_a_retract_and_an_assert_and_the_file_follows_at_once(store, hermes_home,
                                                                          ledger_dir, capsys):
    old = claim_id("user", "Name: Alex Doe")
    before = len(store.path.read_text(encoding="utf-8").splitlines())
    rc, obj = run(store, "correct", old, "Name: Alex Q. Doe", "--json", capsys=capsys)
    assert rc == 0 and obj["ok"] and obj["id"] == old
    assert obj["claim"]["id"] == claim_id("user", "Name: Alex Q. Doe")
    assert obj["claim"]["source"] == cli.PAGE_SOURCE

    lines = store.path.read_text(encoding="utf-8").splitlines()[before:]
    bodies = [json.loads(l)["body"] for l in lines]
    assert [b["op"] for b in bodies] == ["retract", "assert"]
    assert bodies[0]["claim"] == old and "text" not in bodies[0]
    assert "text" not in bodies[1] and bodies[1]["enc"] == "aes-gcm-256.v1"   # sealed
    assert all(decode_line(l) is not None for l in lines)

    text = user_md(hermes_home)
    assert "Name: Alex Q. Doe" in text and "Name: Alex Doe" not in text
    # A later projection — the next session — does not bring the old line back.
    projection.project_all(store, ["memory", "user"])
    fresh = ClaimStore(ledger_dir, device="mac-9f3c1a2b", state_dir=hermes_home,
                       key=store.key)
    projection.project_all(fresh, ["memory", "user"])
    assert "Name: Alex Doe\n" not in user_md(hermes_home) and "Name: Alex Doe" not in \
        [e for e in projection.parse_entries(user_md(hermes_home))]
    assert "Name: Alex Q. Doe" in fresh.live("user")


def test_delete_retracts_and_the_line_leaves_the_file(store, hermes_home, capsys):
    cid = claim_id("user", "Name: Alex Doe")
    rc, obj = run(store, "delete", cid, "--json", capsys=capsys)
    assert rc == 0 and obj["claim"]["text"] == "Name: Alex Doe"
    assert "Alex" not in user_md(hermes_home)
    projection.project_all(store, ["memory", "user"])
    assert "Alex" not in user_md(hermes_home)


def test_unknown_id_and_empty_text_are_refused(store, capsys):
    rc, obj = run(store, "delete", "000000000000", "--json", capsys=capsys)
    assert rc == 1 and not obj["ok"]
    rc, obj = run(store, "correct", claim_id("user", "Name: Alex Doe"), "  ", "--json", capsys=capsys)
    assert rc == 2 and obj["error"] == "empty correction"


def test_neutral_names_moe_in_user_lines_only_and_is_a_dry_run_by_default(store, hermes_home,
                                                                          capsys):
    assert cli.neutral("Prefers I take action over explaining: wants me to say what I'm doing") \
        == "Prefers Moe take action over explaining: wants Moe to say what Moe is doing"
    assert cli.neutral('Said "I quit" once') == 'Said "I quit" once'
    rc, obj = run(store, "neutral", "--json", capsys=capsys)
    assert rc == 0 and not obj["applied"] and len(obj["changes"]) == 1
    assert "Prefers I take action" in user_md(hermes_home)
    rc, obj = run(store, "neutral", "--apply", "--json", capsys=capsys)
    assert obj["applied"]
    assert "Prefers Moe take action over explaining" in user_md(hermes_home)
    assert "Prefers I take" not in user_md(hermes_home)


def test_the_prompt_block_asks_for_the_third_person(provider):
    block = provider.system_prompt_block()
    assert 'never "I", "me" or "my"' in block


def test_the_script_runs_standalone(tmp_path):
    """As the app runs it: `python cli.py …` with no package on sys.path."""
    p = subprocess.run([sys.executable, str(cli.HERE / "cli.py"), "--help"],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    assert p.returncode == 0, p.stderr
    assert "correct" in p.stdout

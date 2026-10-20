"""Automation blueprints, as tools.

Hermes ships 16 parameterised automation templates — a morning briefing, an
important-mail watch, a weekly review, a price watch, a habit check-in — each
with typed slots and a schedule template, and a `fill_blueprint` that turns
filled slots into `create_job` kwargs. Its own design note says the point is
that "users never type raw cron".

Moe could not reach any of it. The documented route is the `/blueprint` slash
command, and slash commands are handled in the platform-adapter path that the
OpenAI-compatible api_server never enters — measured on this machine:

    /blueprint morning-brief  ->  Unknown command: /blueprint
    /suggestions              ->  Unknown command: /suggestions
    /help                     ->  /help isn't available in this environment.

So the capability was real, complete, tested, and unreachable from the only
surface Moe speaks. These two tools are the bridge: the model lists the
templates, asks the user for the blanks in ordinary conversation, and creates
the job. Asking in conversation rather than through the `clarify` tool is not
a workaround — on a voice surface the question IS the reply, and clarify now
says so itself rather than erroring.

Registered into the `connectors` toolset, which was not the first choice.
Their own `blueprints` toolset is the tidier answer — setting up a recurring
job is a rare, deliberate act, exactly the shape tool_search exists to defer —
and it does not work. Measured: with `toolset="blueprints"` the gateway's
/v1/toolsets reported the toolset enabled with both tools, and the MCP bridge
that is the model's ENTIRE tool surface never offered them; `tool_search` for
"blueprint automation recurring job" came back with `cronjob` and
`skill_manage` and nothing of ours, and the model answered "NO" when asked
whether blueprint_list existed. Adding the name to `platform_toolsets` did not
change it, because that key does not gate the child on this runtime.

The two toolsets that DO reach the model — `connectors` and `moe_profile` —
are the two pinned undeferrable in Hermes's own `_DIRECT_SURFACE_TOOLSETS`.
The alternative was to add a third name there, which is another patch to
Hermes core with no config equivalent and one more thing to lose on every
`hermes update`. Riding an existing pinned toolset costs two tool schemas on
every turn and no fork surface at all. That is the better trade, and this
comment is here so the next person knows it was a trade and not a preference.
"""

import json


def _catalog():
    from cron.blueprint_catalog import CATALOG, blueprint_catalog_entry
    items = CATALOG.values() if hasattr(CATALOG, "values") else CATALOG
    return [blueprint_catalog_entry(b) for b in items]


# Where a scheduled job may deliver.
#
# `_DELIVER` in Hermes's catalog is an enum with `strict=False`, and
# `fill_blueprint` only checks options when `strict` is true — so it validates
# this slot not at all. Downstream, cron's `DeliveryTarget.parse` happily
# accepts `platform:chat_id[:thread_id]` and the token `all`. Measured before
# this list existed:
#
#   blueprint_create(deliver="telegram:-1001999999999") -> created, delivering there
#   blueprint_create(deliver="all")                     -> created
#
# and `confirm-send.sh` never fires on it, because its send trigger is a
# recipient key AND a body key in the arguments, and these arguments are
# {key, values, name}. So the model could schedule a recurring, unattended
# message to an address the user never saw, past the one dialog that exists to
# stop exactly that.
#
# The allowed set is therefore closed here: the non-messaging targets, plus
# the bare name of a platform the user has actually connected. A bare platform
# name still resolves through that platform's configured home channel — the
# user's own phone — and cannot name a chat.
#
# `moe` is the screen of this Mac plus whatever connectors the user ticked in
# Settings › Background (the moe-screen plugin). It is the default, and it is
# what `origin` becomes: a job made from a Moe conversation records an origin
# of api_server, whose adapter cannot send, so `origin` from here is a job
# that runs and reaches nobody (measured 2026-09-02).
_SAFE_DELIVER = ("moe", "origin", "local")
_DEFAULT_DELIVER = "moe"


def _allowed_deliver():
    """`origin`, `local`, and the platforms this machine has enabled."""
    names = set(_SAFE_DELIVER)
    try:
        from hermes_cli.config import load_config
        for name, entry in (load_config().get("platforms") or {}).items():
            if isinstance(entry, dict) and entry.get("enabled") and name != "api_server":
                names.add(str(name))
    except Exception:
        pass
    return names


def _ask(field):
    """One slot as a question for the model, with no default and no option it
    would be refused for choosing.

    The catalog offers `discord` and `email` as delivery targets on every
    machine, connected or not, and _create rejects anything this machine has
    not enabled — so passing the raw list through invites the model to offer
    the user a choice that then fails."""
    out = {k: v for k, v in (field or {}).items() if k != "default"}
    if out.get("name") == "deliver" and out.get("options"):
        allowed = _allowed_deliver()
        options = [o for o in out["options"] if str(o) in allowed and str(o) != "origin"]
        # The catalog does not know this Mac; `moe` is offered first, and
        # `origin` not at all — from here it is the same thing, resolved
        # to somewhere that can actually be reached.
        out["options"] = [_DEFAULT_DELIVER] + [o for o in options if str(o) != _DEFAULT_DELIVER]
    return out


def _list(params=None, **kwargs):
    """Every blueprint, with the blanks the user has to fill."""
    try:
        entries = _catalog()
    except Exception as e:
        return json.dumps({"success": False, "error": "%s: %s" % (type(e).__name__, e)})
    slim = [{
        "key": e.get("key"),
        "title": e.get("title"),
        "description": e.get("description"),
        # The label and the options; NOT the default.
        #
        # `fields` was passed through whole, and that quietly defeated the
        # guard below: a model shown `"default": "take a break and stretch"`
        # echoes it back as the answer, and the check for a missing value sees
        # a value. The guard's whole point is that the USER chose the words,
        # the time and the destination. One of the catalog's own defaults is
        # not even valid — competitor-watch offers `recurrence: "monday"` for a
        # weekdays slot, which fill_blueprint then rejects — so shipping them
        # was also handing the model a value that cannot work.
        #
        # Options stay: those are real constraints, and a model that invents an
        # enum value gets a worse error than one that picks from the list.
        #
        # `deliver` is not a question. Moe answers it: `moe` is wherever the
        # person gets their reminders — the screen and the chat apps ticked
        # in Settings. Listing it made the model ask "where should this
        # land — here, Telegram only, WhatsApp only, a file?" of a person
        # with no chat app connected (owner's Mac, 2026-09-11), which is a
        # form, not a conversation. They can still say a place; it is
        # honoured. They are never asked for one.
        "asks": [_ask(f) for f in (e.get("fields") or [])
                 if str((f or {}).get("name")) != "deliver"],
    } for e in entries]
    return json.dumps({"success": True, "blueprints": slim})


def _create(params=None, **kwargs):
    """Fill one blueprint and register it as a real Hermes cron job."""
    source = params if isinstance(params, dict) else {}
    key = str(source.get("key") or "").strip()
    values = source.get("values")
    if isinstance(values, str):
        try:
            values = json.loads(values)
        except ValueError:
            return json.dumps({"success": False, "error":
                               "values must be an object of slot name -> answer."})
    if not isinstance(values, dict):
        values = {}
    if not key:
        return json.dumps({"success": False, "error":
                           "key is required — call blueprint_list first."})
    try:
        from cron.blueprint_catalog import get_blueprint, fill_blueprint
        from cron.jobs import create_job, list_jobs, ensure_dirs
    except Exception as e:
        return json.dumps({"success": False, "error": "cron unavailable: %s" % e})

    blueprint = get_blueprint(key)
    if blueprint is None:
        return json.dumps({"success": False, "error":
                           "no blueprint called %r — call blueprint_list first." % key})
    # Every non-optional slot must be ANSWERED, even where the blueprint
    # carries a default. The defaults are form pre-fills, not answers: the
    # `what` slot of custom-reminder defaults to "take a break and stretch",
    # so accepting defaults meant a user who said "remind me every day" got
    # somebody else's reminder, at somebody else's time, delivered somewhere
    # they would never look. Measured while building this — it created exactly
    # that job. The slot labels are already written as questions ("Remind me
    # to…", "What time?"); asking them is the feature.
    # Except `deliver`, which is Moe's to answer (see `_list`): an
    # unanswered destination is `moe`, resolved below.
    missing = [s.name for s in blueprint.slots
               if not getattr(s, "optional", False)
               and s.name != "deliver"
               and not str(values.get(s.name) or "").strip()]
    if missing:
        return json.dumps({"success": False, "error":
                           "ask the user for: %s" % ", ".join(missing)})
    deliver = str(values.get("deliver") or "").strip()
    if deliver:
        allowed = _allowed_deliver()
        if deliver not in allowed:
            return json.dumps({"success": False, "error":
                               "deliver must be one of %s — a job cannot be pointed at a "
                               "particular chat or address from here."
                               % ", ".join(sorted(allowed))})
    else:
        values = dict(values, deliver=_DEFAULT_DELIVER)
    try:
        spec = fill_blueprint(blueprint, values)
    except Exception as e:
        return json.dumps({"success": False, "error": "%s: %s" % (type(e).__name__, e)})
    # The person's own words ride with the template. A blueprint's prompt is
    # a shape — "today's calendar and the 1-3 highest-priority things" — and
    # the model told the owner (2026-09-11) his weekday briefing would cover
    # "anything in your inbox that's waiting on you" while the job it made
    # said nothing about mail. What they asked for is the content; the
    # template is the form.
    ask = str(source.get("ask") or "").strip()
    if ask and isinstance(spec.get("prompt"), str):
        spec["prompt"] = (spec["prompt"].rstrip()
                          + "\n\nThe person asked for this in their own words: “" + ask
                          + "”. Do what they asked; the paragraph above is the shape, "
                            "their words are the content.")
    # The catalog's own default is `origin`, which from a Moe conversation is
    # the api_server: no send path, so the job would run and reach nobody.
    # An unanswered destination, or `origin`, means "wherever I get my
    # reminders" — the screen and the connectors ticked in Settings.
    if str(spec.get("deliver") or "").strip().lower() in ("", "origin"):
        spec["deliver"] = _DEFAULT_DELIVER

    # FORCED, not setdefault. `fill_blueprint` always writes
    # `spec["name"] = blueprint.title`, so a setdefault never fired and the
    # `name` parameter was dead: every morning-brief was "Morning briefing"
    # whatever the caller asked for. Two jobs that differ only by their slot
    # values — an 08:00 briefing and a 06:30 one — then collided on that title,
    # and the second returned "already scheduled" with success:true. The model
    # reports that as done and nothing has changed.
    #
    # NOT `moe-<key>`. That prefix means "one of Moe's own background jobs,
    # installed by configure-hermes" everywhere it is read — `deliver.
    # is_moe_job`, `Conductor.isMoeJob`, `ran.py`, and `cronjobs.is_portable`,
    # which decides what travels to the person's cloud machine. A briefing
    # the person asked for is theirs: named `moe-workday-start` it was never
    # written to the ledger and never reached the machine (owner's Mac,
    # 2026-09-11, the first end-to-end run). The key is the name.
    spec["name"] = str(source.get("name") or "").strip() or key
    try:
        ensure_dirs()
        # Keyed on the name, like every other job Moe registers, so asking
        # twice does not produce two briefings.
        same = [j for j in list_jobs(include_disabled=True) if j.get("name") == spec.get("name")]
        if same:
            # Not success. Nothing was created, and saying "true" here is how
            # the model comes to tell the user their new 06:30 briefing is set
            # when the 08:00 one is what still exists.
            return json.dumps({"success": False, "created": False,
                               "job": spec.get("name"), "id": same[0].get("id"),
                               "error": "a job called %r already exists. Pass a different "
                                        "`name` to schedule a second one, or use the cronjob "
                                        "tool to change or remove the existing one."
                                        % spec.get("name")})
        job = create_job(**spec)
    except Exception as e:
        return json.dumps({"success": False, "error": "%s: %s" % (type(e).__name__, e)})
    return json.dumps({"success": True, "created": True, "job": spec.get("name"),
                       "id": job.get("id"), "schedule": spec.get("schedule"),
                       "deliver": spec.get("deliver")})


LIST_SCHEMA = {
    "name": "blueprint_list",
    "description": ("List Hermes's ready-made automations (morning briefing, important-mail "
                    "watch, weekly review, reminders, habit check-in and more), with the "
                    "blanks each one needs. Use this when the user asks for something "
                    "recurring that needs a model each time — 'every morning', 'remind me "
                    "weekly' — before creating anything. NOT for watching a page, a price, "
                    "a slot or a delivery: that is a `watch` follow-up (moe_followups, "
                    "action open, kind watch, with a check), which costs nothing until the "
                    "page changes and never asks how often or where."),
    "parameters": {"type": "object", "properties": {}, "required": []},
}

CREATE_SCHEMA = {
    "name": "blueprint_create",
    "description": ("Create a recurring job from a blueprint. Fill `values` from what the "
                    "user already said; ask only for a blank you genuinely cannot fill "
                    "from the conversation, in conversation. Never ask where it should "
                    "land: it lands wherever they get their reminders (spoken and shown "
                    "on this Mac, and the chat apps they chose in Settings) unless they "
                    "named a place — then pass that as `deliver`. Put the user's request "
                    "in `ask`, in their words, so the job does what they asked and not "
                    "only what the template says."),
    "parameters": {
        "type": "object",
        "properties": {
            "key": {"type": "string", "description": "Blueprint key from blueprint_list."},
            "values": {"type": "object",
                       "description": "Slot name -> the user's answer."},
            "ask": {"type": "string",
                    "description": "What the user asked for, in their own words. Appended "
                                   "to the job so it covers everything they said."},
            "name": {"type": "string",
                     "description": "Optional job name; defaults to the blueprint key."},
        },
        "required": ["key", "values"],
    },
}


def _available():
    try:
        from cron.blueprint_catalog import CATALOG  # noqa: F401
        return True
    except Exception:
        return False


def register(ctx):
    ctx.register_tool("blueprint_list", "connectors", LIST_SCHEMA, _list,
                      check_fn=_available, description=LIST_SCHEMA["description"],
                      emoji="🗓️")
    ctx.register_tool("blueprint_create", "connectors", CREATE_SCHEMA, _create,
                      check_fn=_available, description=CREATE_SCHEMA["description"],
                      emoji="🗓️")

# Hermes toolsets Alfie should enable

Written 2026-08-30 from a read of the Hermes checkout (`toolsets.py`,
`hermes_cli/tools_config.py`, `cli-config.yaml.example`). This is a spec for
`hermes/configure-hermes.py`, which owns `~/.hermes/config.yaml` and is not
edited by this branch. Everything below is a **TODO for that file**.

> **Stale as of 2026-08-31.** Most of the TODO below has landed, and two of
> the "facts" were wrong. See HERMES-FEATURES.md for the measured picture. The
> two corrections that matter:
>
> 1. **The top-level `toolsets:` key is NOT dead.** `tools/kanban_tools.py`
>    reads it (`_profile_has_kanban_toolset`), and so does `hermes_cli/dump.py`.
>    That is why listing `kanban` in `platform_toolsets` enables nothing: the
>    kanban gate never looks there.
> 2. **`platform_toolsets` is not what decides Alfie's tool surface at all.**
>    On the `claude-code-cli` runtime the child's tools come from the
>    `hermes-tools` MCP server, which calls `get_tool_definitions()` with no
>    toolset argument. The list shapes the parent's system prompt and gates
>    `computer_use`'s check; it does not gate the model. Excluding `tts` here
>    does not remove `text_to_speech` from the surface — measured, it is there.

## What Alfie enables today

Nothing, explicitly. `configure-hermes.py` sets `platforms.api_server.*`,
`platforms.telegram.enabled`, `hooks`, `tools.terminal.security_mode` and
`claude_code.*` (`config-fragment.yaml` adds the confirm hook). It never
writes `platform_toolsets`, so Alfie's brain runs on Hermes's **default bundle
for the api_server platform, `hermes-api-server`**, which is the core set
*minus* `clarify`, `text_to_speech`, `computer_use` and every `kanban_*` tool
(`toolsets.py` ~line 438). MCP servers are on for every platform by default
and need nothing here.

## The facts that decide the config

- The only key that works is `platform_toolsets.<platform>: [names]`.
  The top-level `toolsets:` key is **dead** (in `DEFAULT_CONFIG`, read by no
  code) and `custom_toolsets:` is documented but unimplemented.
- A toolset listed there still needs its runtime `check_fn` to pass:
  `web` needs a search backend (Exa/Firecrawl/Tavily/Brave key, or the
  keyless `ddgs` package), `image_gen` needs `FAL_KEY` or the Nous gateway,
  `homeassistant` needs `HASS_TOKEN`, `spotify` needs `hermes auth spotify`,
  `computer_use` needs the cua-driver binary, `browser` needs
  `agent-browser` on PATH (or `BROWSER_CDP_URL`). Listing a toolset whose
  check fails is harmless — it is skipped — so list them all.
- `kanban` is never enabled by `all`/`*` and needs explicit listing; its
  tools are only exposed to dispatcher-owned workers anyway.
- `tts` is n/a: Alfie owns audio on the Mac.
- There is no `mcp` toolset and no `tool_search` toolset. MCP servers are
  per-server toolsets (`mcp-<name>`), on by default. Tool search is
  `tools.tool_search.enabled`, default `"auto"`; with 50 connectors attached
  it should be `true`.
- `agent.disabled_toolsets` is subtracted **last**; Alfie must not set it.
- Saving a list freezes it: a toolset Hermes ships later stays off unless
  listed. That is the cost of being explicit; `configure-hermes.py` re-runs
  on every Alfie launch, so keep the list in one place and add to it.

## The literal YAML

```yaml
platform_toolsets:
  api_server:
    - web
    - browser
    - vision
    - video
    - image_gen
    - video_gen
    - terminal
    - file
    - code_execution
    - delegation
    - cronjob
    - skills
    - memory
    - session_search
    - todo
    - clarify
    - computer_use
    - homeassistant
    - spotify
    - kanban
    - x_search
  # The chat platforms Alfie turns on get the same set, so "Alfie over Telegram"
  # can do what "Alfie on the Mac" can.
  telegram:
    - hermes-telegram
    - clarify
    - computer_use
    - homeassistant
    - spotify
    - kanban

tools:
  tool_search:
    enabled: true
```

`clarify` matters most: it is the tool the learn-me interview and every
"which contact did you mean?" question runs on, and the default api_server
bundle drops it.

## TODO(configure-hermes.py)

1. Add `MOE_TOOLSETS = [...]` (the api_server list above) and, in
   `build_config`, `force_set(cfg, ["platform_toolsets", "api_server"],
   MOE_TOOLSETS, …)`. Force, not set-if-absent: Hermes's `hermes tools`
   checklist writes the same key, and a user who unticked something there
   would otherwise silently lose Alfie features on the next launch — report
   it as "yours kept" only if a `--keep-toolsets` flag is given.
2. `set_if_absent(cfg, ["tools", "tool_search", "enabled"], True, …)`.
3. For every platform Alfie enables (telegram today; whatever
   `scripts/connect.sh` adds a token for), write
   `platform_toolsets.<platform>` = the platform list above, and
   `platforms.<platform>.enabled: true` so the intent is visible in
   config.yaml — `connect.sh` prints this TODO after writing a platform
   token to `.env`.
4. Validate as today with Hermes's own loader in a scratch copy; then
   `GET /v1/toolsets` on the running api_server is the check that every
   listed toolset reports `enabled: true` (and `configured` tells which
   ones still need a key — doctor.sh could show that).

# The Homebrew cask, kept here so it is version-controlled and reviewable
# before it is a pull request against homebrew/cask.
#
# It cannot be submitted until a Developer ID build is the download:
# "Casks without codesigning and notarization are now deprecated, and will be
# removed from the official Tap by September 2026" — docs.brew.sh/Acceptable-Casks.
# The unsigned dmg on moebot.app today fails Homebrew's Gatekeeper check.
#
# Two fields change every release, `version` and `sha256`, and both are
# already produced by scripts/release.sh (it writes a .sha256 beside the dmg).
# Wiring publish-release.sh to open the bump PR is the obvious next step and
# is deliberately not done yet — the first submission should be by hand.
#
# The livecheck is Sparkle's, pointed at our own appcast, so Homebrew learns
# about a new version from the same feed every installed copy already polls.
# There is no second source of truth to drift.
#
# ---------------------------------------------------------------------------
# THE RENAME IS ONLY HALF TRUE IN THIS FILE. Do not submit it until all of
# these are done in the SAME change (docs/RENAME.md §7):
#
#   1. The tap repository is still `Izzy-Gottz/homebrew-moe`. Rename it to
#      `Izzy-Gottz/homebrew-memoe` and let GitHub keep the redirect, so
#      `brew install --cask izzy-gottz/memoe/memoe` is the documented line.
#   2. This file is still named `moe.rb`. Homebrew requires the filename to
#      match the token, so it becomes `memoe.rb` when the tap is renamed —
#      and the old token needs a `tap_migrations.json` entry
#      (`"moe": "izzy-gottz/memoe/memoe"`) or anyone who typed the old name
#      gets nothing.
#   3. The download artefact below is `Memoe-<version>.dmg`, which is what
#      `build.sh` (Memoe.app) and `scripts/release.sh` produce from now on.
#      THE PUBLISHED RELEASE IS STILL `Moe-0.3.20.dmg`: this url 404s until
#      the next release is cut. Bump `version` and `sha256` from that release
#      and not before.
#   4. `Izzy-Gottz/moe-releases` (the releases repo, and `MOE_RELEASES_REPO`'s
#      default in scripts/publish-release.sh) has NOT been renamed and this
#      url depends on it. If it is ever renamed, `verified:` must move with it.
#   5. `homepage` and `livecheck` still say moebot.app. The appcast URL never
#      moves (it is compiled into every shipped binary); `homepage` follows the
#      site's canonical domain, so it becomes https://memoe.app/ at
#      docs/RENAME.md step 6 and not before.
# ---------------------------------------------------------------------------

cask "memoe" do
  version "0.3.15"
  sha256 "REPLACE_WITH_THE_SHA256_OF_THE_FIRST_NOTARIZED_DMG"

  url "https://github.com/Izzy-Gottz/moe-releases/releases/download/v#{version}/Memoe-#{version}.dmg",
      verified: "github.com/Izzy-Gottz/moe-releases/"
  name "Memoe"
  desc "Assistant that reads your mail, messages, and calendar, and does the work"
  homepage "https://moebot.app/"

  livecheck do
    url "https://moebot.app/appcast.xml"
    strategy :sparkle
  end

  auto_updates true
  depends_on macos: ">= :sequoia"
  depends_on arch: :arm64

  app "Memoe.app"

  # Memoe keeps everything in ~/Library/Application Support/Moe and leaves
  # ~/.moe as a symlink to it (CLAUDE.md). The data paths keep the old name on
  # purpose — renaming them is a migration, not a rename. It also installs
  # Hermes — a Python checkout and venv, about 1.2 GB — into ~/.hermes with a
  # wrapper on PATH, so an uninstall that did not name those would leave the
  # larger half of the install behind.
  #
  # Both bundle identifiers are listed: `com.memoe.app` is what build.sh signs
  # today, `com.moe.assistant` is what a pre-rename copy left behind. Zapping a
  # path that does not exist is a no-op, and leaving one behind is not.
  zap trash: [
        "~/.hermes",
        "~/.local/bin/hermes",
        "~/.moe",
        "~/Library/Application Support/FluidAudio",
        "~/Library/Application Support/Moe",
        "~/Library/Caches/com.memoe.app",
        "~/Library/Caches/com.moe.assistant",
        "~/Library/HTTPStorages/com.memoe.app",
        "~/Library/HTTPStorages/com.moe.assistant",
        "~/Library/Preferences/com.memoe.app.plist",
        "~/Library/Preferences/com.moe.assistant.plist",
      ],
      launchctl: [
        "com.memoe.app",
        "com.moe.assistant",
      ]
end

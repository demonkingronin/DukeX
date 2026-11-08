#!/usr/bin/env python3
"""Run lightweight per-game TOML behavior checks without compiling DukeX."""
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
swift_source = (root / "ios/DukeX/DukeX/Runtime/LaunchPlan/XemuLaunchPlan.swift").read_text()
prefix = "enum GameResolutionScaleConfig {"
if swift_source.count(prefix) != 1:
    raise SystemExit("Cannot locate per-game TOML helpers")
swift = shutil.which("swift")
if swift is None:
    raise SystemExit("Swift is required to test per-game TOML editing")

helpers = swift_source[swift_source.index(prefix):]
regression = r'''
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
let original = """
[general]
show_welcome = false
skip_boot_anim = false # user note
games_dir = "/test/ROMs"

[display]
renderer = "VULKAN"

[display.quality]
surface_scale = 1 # user quality note

[sys.files]
hdd_path = "/test/hdd.qcow2"
dvd_path = "/test/game.iso"
"""
check(GameResolutionScaleConfig.allowedValues == [1, 2], "quality should have two levels")
check(GameResolutionScaleConfig.title(for: 1) == "Low", "1x must be Low")
check(GameResolutionScaleConfig.title(for: 2) == "High", "2x must be High")
let high = GameResolutionScaleConfig.setting(2, in: original)
check(GameResolutionScaleConfig.scale(in: high) == 2, "high must write surface_scale=2")
check(high.contains("surface_scale = 2 # user quality note"), "preserve display comment")
check(high.contains("hdd_path = \"/test/hdd.qcow2\""), "preserve HDD path")
let boot = GameSkipBootConfig.setting(true, in: high)
check(GameSkipBootConfig.isEnabled(in: boot), "skip boot must turn on")
check(boot.contains("skip_boot_anim = true # user note"), "preserve boot comment")
check(GameResolutionScaleConfig.scale(in: boot) == 2, "boot change must preserve display")
check(boot.contains("dvd_path = \"/test/game.iso\""), "preserve game disc")
let bootOff = GameSkipBootConfig.setting(false, in: boot)
check(!GameSkipBootConfig.isEnabled(in: bootOff), "skip boot must turn off")
check(GameResolutionScaleConfig.scale(in: GameResolutionScaleConfig.setting(1, in: bootOff)) == 1, "low must write surface_scale=1")
let noGeneral = "[display]\nrenderer = \"VULKAN\"\n"
let inserted = GameSkipBootConfig.setting(true, in: noGeneral)
check(GameSkipBootConfig.isEnabled(in: inserted), "create missing general table")
check(inserted.contains("renderer = \"VULKAN\""), "preserve imported display table")
let duplicates = "[general]\nskip_boot_anim = false\nskip_boot_anim = false\n"
let cleaned = GameSkipBootConfig.setting(true, in: duplicates)
check(cleaned.components(separatedBy: "skip_boot_anim =").count - 1 == 1, "deduplicate general setting")
print("DukeX per-game TOML regression checks passed")
'''
result = subprocess.run(
    [swift, "-"],
    input="import Foundation\n" + helpers + "\n" + regression,
    text=True,
    capture_output=True,
    timeout=90,
)
if result.returncode != 0:
    sys.stderr.write(result.stdout + result.stderr)
    raise SystemExit(result.returncode)
print(result.stdout.strip())

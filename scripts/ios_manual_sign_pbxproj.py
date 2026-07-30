#!/usr/bin/env python3
"""Force Manual + Apple Distribution + named App Store profiles on iOS targets.

XcodeGen ships CODE_SIGN_STYLE=Automatic so local Macs keep working. CI archives
with an ASC API key under Automatic mint *development* certificates until the
team hits Apple's cap — see docs/releasing.md. After xcodegen, the Release
workflow calls this so the archive signs the same way the export already does.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

# Target name → App Store Connect provisioning profile name (must match
# scripts/build-ios.sh PROFILE_BUNDLES and the Release workflow download list).
PROFILES = {
    "HeadroomMobile": "Headroom App Store",
    "HeadroomWidget": "Headroom Widget App Store",
    "HeadroomWatch": "Headroom Watch App Store",
    "HeadroomWatchComplication": "Headroom Watch Complication App Store",
}

SETTINGS = {
    "CODE_SIGN_STYLE": "Manual",
    "CODE_SIGN_IDENTITY": '"Apple Distribution"',
    "CODE_SIGN_IDENTITY[sdk=iphoneos*]": '"Apple Distribution"',
    "CODE_SIGN_IDENTITY[sdk=watchos*]": '"Apple Distribution"',
}


def _target_config_ids(text: str, target: str) -> list[str]:
    """Return XCConfigurationList id for PBXNativeTarget `target`."""
    pattern = (
        rf'/\* {re.escape(target)} \*/ = \{{.*?buildConfigurationList = '
        rf'([0-9A-F]+) /\* Build configuration list for PBXNativeTarget '
        rf'"{re.escape(target)}" \*/;'
    )
    match = re.search(pattern, text, re.S)
    if not match:
        raise SystemExit(f"error: target {target!r} not found in pbxproj")
    list_id = match.group(1)
    list_pat = (
        rf'{list_id} /\* Build configuration list for PBXNativeTarget '
        rf'"{re.escape(target)}" \*/ = \{{.*?buildConfigurations = \((.*?)\);'
    )
    list_match = re.search(list_pat, text, re.S)
    if not list_match:
        raise SystemExit(f"error: configuration list for {target!r} not found")
    return re.findall(r'([0-9A-F]+) /\* (Debug|Release) \*/', list_match.group(1))


def _patch_config(text: str, config_id: str, config_name: str, profile: str) -> str:
    """Rewrite one XCBuildConfiguration's buildSettings block."""
    pattern = (
        rf'({config_id} /\* {config_name} \*/ = \{{.*?buildSettings = \{{)'
        rf'(.*?)(\n\t\t\t\}};.*?name = {config_name};)'
    )
    match = re.search(pattern, text, re.S)
    if not match:
        raise SystemExit(
            f"error: build settings for {config_id} ({config_name}) not found")
    settings = match.group(2)
    # Drop any existing keys we own so re-runs stay idempotent.
    for key in (
        "CODE_SIGN_STYLE",
        "CODE_SIGN_IDENTITY",
        "CODE_SIGN_IDENTITY\\[sdk=iphoneos\\*\\]",
        "CODE_SIGN_IDENTITY\\[sdk=watchos\\*\\]",
        "PROVISIONING_PROFILE_SPECIFIER",
    ):
        settings = re.sub(
            rf'\n\t\t\t\t{key} = .*?;',
            "",
            settings,
        )
    extras = "".join(
        f"\n\t\t\t\t{key} = {value};"
        for key, value in SETTINGS.items()
    )
    extras += f'\n\t\t\t\tPROVISIONING_PROFILE_SPECIFIER = "{profile}";'
    patched = match.group(1) + settings + extras + match.group(3)
    return text[: match.start()] + patched + text[match.end() :]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "pbxproj",
        type=pathlib.Path,
        help="path to project.pbxproj",
    )
    args = parser.parse_args()
    path = args.pbxproj
    text = path.read_text()
    for target, profile in PROFILES.items():
        for config_id, config_name in _target_config_ids(text, target):
            text = _patch_config(text, config_id, config_name, profile)
            print(f"signed {target} {config_name} → {profile}")
    path.write_text(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())

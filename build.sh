#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint

# Builds MacBar, assembles the .app bundle, signs it and (with --install)
# installs it into /Applications.
#
# The bundle is staged in a temporary directory outside ~/Documents: folders synced
# by File Provider gain xattrs (com.apple.provenance etc.) that invalidate codesign.
set -euo pipefail
cd "$(dirname "$0")"

# The icon catalog and the bundle are staged in temp dirs; sweep both however
# the script ends.
ICON_TMP=""
STAGE_TMP=""

cleanup() {
    [[ -n "$ICON_TMP" ]] && rm -rf "$ICON_TMP"
    [[ -n "$STAGE_TMP" ]] && rm -rf "$STAGE_TMP"
    return 0
}
trap cleanup EXIT
# zsh runs the EXIT trap when the script is hung up, but not when it is
# interrupted or terminated; route those through exit so a Ctrl-C partway
# into the build sweeps like any other ending.
trap 'exit 1' INT TERM HUP

# Flags: --dev builds the local-only "MacBar (Developer)" variant (its own
# bundle id, so it coexists with the official app); --install puts it in /Applications.
DEV=0
INSTALL=0
TEST=0
TEST_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --dev)     DEV=1 ;;
        --install) INSTALL=1 ;;
        --test)    TEST=1 ;;
        --test-suite=*) TEST=1; TEST_ARGS+=("--suite=${arg#*=}") ;;
        --list-tests) TEST=1; TEST_ARGS+=(--list) ;;
    esac
done

if (( DEV )); then
    APP_NAME="MacBar (Developer)"
    EXECUTABLE="MacBarDeveloper"
    APP_BUNDLE_ID="com.erold90.macbar.dev"
    BUILD_VARIANT_FLAGS=(-D MACBAR_DEVELOPMENT)
    APP_OPTIMIZATION_FLAGS=(-Onone)
    BUILD_CONFIGURATION="debug"
else
    APP_NAME="MacBar"
    EXECUTABLE="MacBar"
    APP_BUNDLE_ID="com.erold90.macbar"
    BUILD_VARIANT_FLAGS=()
    APP_OPTIMIZATION_FLAGS=(-O)
    BUILD_CONFIGURATION="release"
fi
FAN_HELPER_ID="$APP_BUNDLE_ID.fan-control"
# Now Playing is read through /usr/bin/perl loading this library; see
# Sources/NowPlayingAdapter. Staged under Contents/Frameworks, signed on its own.
NOW_PLAYING_ADAPTER_ID="$APP_BUNDLE_ID.now-playing"
NOW_PLAYING_ADAPTER="libMacBarNowPlaying.dylib"
# Architecture: this machine's by default; override with ARCH=arm64 or ARCH=x86_64.
ARCH="${ARCH:-$(uname -m)}"
TARGET="$ARCH-apple-macosx14.0"
ENTITLEMENTS="Resources/MacBar.entitlements"
LEGACY_IDENTITY="MacBar Local Signing"

developer_id_identity() {
    security find-identity -v -p codesigning 2>/dev/null \
        | grep 'Developer ID Application' \
        | head -1 \
        | sed -E 's/.*"(.*)".*/\1/' || true
}

# A find-identity listing also names certificates codesign then rejects (an
# expired one fails the build with errSecInternalComponent), and -v excludes
# every self-signed one; ask codesign itself with a throwaway copy of /bin/echo.
legacy_identity_installed() {
    local probe signed=1
    # A locked keychain still lists its identities but cannot sign with them,
    # and this one is locked after every reboot; unlock it before asking.
    security unlock-keychain -p macbar-signing \
        "$HOME/Library/Keychains/macbar-signing.keychain-db" 2>/dev/null || true
    probe="$(mktemp)"
    cp /bin/echo "$probe"
    /usr/bin/codesign --force --strip-disallowed-xattrs --sign "$LEGACY_IDENTITY" "$probe" \
        >/dev/null 2>&1 && signed=0
    rm -f "$probe"
    return $signed
}

# Any build that lands in /Applications needs a stable signature, not just the
# Developer one: macOS ties Accessibility and Screen Recording grants to the
# exact binary hash, so an ad-hoc rebuild orphans them while System Settings
# keeps showing them as granted, and no new prompt ever appears. A plain
# --install strands them under the released bundle id, on the app the user
# actually relies on. When no identity is installed, create the stable local one
# up front instead of falling through to ad-hoc — setup-signing.sh is free,
# offline and idempotent. Gating on the install rather than the variant keeps
# this off CI, where neither ci.yml nor release.yml passes --install.
# Local signing is opt-in: ./Tools/setup-signing.sh creates a self-signed identity in its
# own keychain (it edits your keychain search list, so it is never run implicitly).
# Without it the bundle is signed ad-hoc, and macOS asks again for Accessibility and
# Screen Recording after each rebuild.
if (( DEV || INSTALL )) && [[ -z "$(developer_id_identity)" ]] \
    && ! legacy_identity_installed; then
    echo "▸ No signing identity installed; signing ad-hoc (run Tools/setup-signing.sh to create a stable local one)."
fi

codesign_with_timestamp_retry() {
    local attempt
    for attempt in 1 2 3; do
        if /usr/bin/codesign "$@"; then
            return 0
        fi
        if (( attempt < 3 )); then
            echo "  Developer ID signing failed; retrying ($((attempt + 1))/3)"
            sleep "$attempt"
        fi
    done
    return 1
}

write_swift_output_file_map() {
    local output_file="$1"
    local object_dir="$2"
    shift 2
    local source artifact

    {
        print -r -- "{"
        print -r -- "  \"\": {"
        print -r -- "    \"swift-dependencies\": \"$object_dir/master.swiftdeps\""
        print -r -- "  }"
        for source in "$@"; do
            artifact="${source//\//__}"
            artifact="${artifact%.swift}"
            print -r -- ","
            print -r -- "  \"$source\": {"
            print -r -- "    \"object\": \"$object_dir/$artifact.o\","
            print -r -- "    \"swift-dependencies\": \"$object_dir/$artifact.swiftdeps\""
            print -r -- "  }"
        done
        print -r -- "}"
    } > "$output_file"
}

finalize_installed_bundle_after_child() {
    local bundle="$1"
    local helper="$bundle/Contents/Library/LaunchServices/$FAN_HELPER_ID"
    local adapter="$bundle/Contents/Frameworks/$NOW_PLAYING_ADAPTER"
    local devid
    devid="$(developer_id_identity)"

    echo "▸ Finalizing installed signature…"
    sleep 3
    if [[ -n "$devid" ]]; then
        [[ -f "$helper" ]] && codesign_with_timestamp_retry --force --strip-disallowed-xattrs \
            --options runtime --timestamp --identifier "$FAN_HELPER_ID" --sign "$devid" "$helper"
        [[ -f "$adapter" ]] && codesign_with_timestamp_retry --force --strip-disallowed-xattrs \
            --options runtime --timestamp --identifier "$NOW_PLAYING_ADAPTER_ID" --sign "$devid" "$adapter"
        codesign_with_timestamp_retry --force --strip-disallowed-xattrs --options runtime --timestamp \
            --entitlements "$ENTITLEMENTS" --sign "$devid" "$bundle"
    elif legacy_identity_installed; then
        [[ -f "$helper" ]] && /usr/bin/codesign --force --strip-disallowed-xattrs \
            --identifier "$FAN_HELPER_ID" --sign "$LEGACY_IDENTITY" "$helper"
        [[ -f "$adapter" ]] && /usr/bin/codesign --force --strip-disallowed-xattrs \
            --identifier "$NOW_PLAYING_ADAPTER_ID" --sign "$LEGACY_IDENTITY" "$adapter"
        /usr/bin/codesign --force --strip-disallowed-xattrs --sign "$LEGACY_IDENTITY" "$bundle"
    else
        [[ -f "$helper" ]] && /usr/bin/codesign --force --strip-disallowed-xattrs \
            --identifier "$FAN_HELPER_ID" --sign - "$helper"
        [[ -f "$adapter" ]] && /usr/bin/codesign --force --strip-disallowed-xattrs \
            --identifier "$NOW_PLAYING_ADAPTER_ID" --sign - "$adapter"
        /usr/bin/codesign --force --strip-disallowed-xattrs --sign - "$bundle"
    fi
    [[ -f "$helper" ]] && /usr/bin/codesign --verify --strict "$helper"
    [[ -f "$adapter" ]] && /usr/bin/codesign --verify --strict "$adapter"
    /usr/bin/codesign --verify --deep --strict "$bundle"
    echo "✓ Signature ready: $bundle"
}

if (( INSTALL && ! TEST )) && [[ "${MACBAR_INSTALL_CHILD:-0}" != "1" ]]; then
    MACBAR_INSTALL_CHILD=1 "$0" "$@"
    child_status=$?
    if (( child_status != 0 )); then
        exit "$child_status"
    fi
    finalize_installed_bundle_after_child "/Applications/$APP_NAME.app"
    exit 0
fi

# Prefer the macOS 26 SDK when present: the 27 SDK turns SwiftUI property wrappers
# into macros (SwiftUIMacros plugin) that the Command Line Tools cannot load yet.
PINNED_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    SDK="$(xcrun --show-sdk-path)"
elif [[ -d "$PINNED_SDK" ]]; then
    SDK="$PINNED_SDK"
else
    SDK="$(xcrun --show-sdk-path)"
fi
SDK_COMPAT_FLAGS=()
VM_STATISTICS_COMPAT_FLAGS=(-I Sources/VMStatisticsCompat)
HID_EVENT_SYSTEM_FLAGS=(-I Sources/HIDEventSystem)
if [[ "$SDK" == "$PINNED_SDK" ]]; then
    # Swift 6.4 can read the SDK 26 interfaces when given their compiler version.
    SDK_COMPAT_FLAGS=(-Xfrontend -interface-compiler-version -Xfrontend 6.3.2)
fi

# The defaults migrations under test need a real UserDefaults suite, and every
# suite leaves an empty plist in ~/Library/Preferences. The tests already clear
# the domains, but cfprefsd writes the emptied file back out around the time the
# process that owned it exits, so only a caller that outlives the run can remove
# them. `PreferenceNamespaceTests` scans every compiled Swift test file against
# these namespaces, which keeps this sweep complete without a second list.
discard_test_preferences() {
    local preferences="${1:-$HOME/Library/Preferences}" name attempt
    local survivors=0 quiet_passes=0
    # cfprefsd can recreate an emptied domain after the first removal. Require
    # two quiet checks, but keep a hard limit so persistent failures still fail CI.
    for attempt in {1..10}; do
        for name in "macbar.tests." "com.erold90.macbar.tests."; do
            rm -f "$preferences"/$name*.plist(N)
        done
        rm -f "$preferences/metrics-tests.plist"
        sleep 0.2
        survivors=$(find "$preferences" -maxdepth 1 \
            \( -name "macbar.tests.*.plist" -o -name "com.erold90.macbar.tests.*.plist" \
               -o -name "metrics-tests.plist" \) 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$survivors" == "0" ]]; then
            quiet_passes=$((quiet_passes + 1))
            if (( quiet_passes == 2 )); then return 0; fi
        else
            quiet_passes=0
        fi
    done
    echo "✗ test preferences did not settle in $preferences ($survivors remaining)" >&2
    return 1
}

# Standalone automated tests: pure contracts plus isolated disk, subprocess,
# keyboard-data and media fixtures. No application windows or device capture.
if (( TEST )); then
    python3 Tests/generate_sources.py
    TEST_OBJECT_DIR="build/objects/tests"
    mkdir -p "$TEST_OBJECT_DIR"
    TEST_SOURCES=(
        Sources/MacBar/Services/Media/MediaSupport.swift
        Sources/MacBar/Core/QuitProtectionSupport.swift
        Sources/MacBar/Core/QuitProtectionStrings.swift
        Sources/MacBar/Core/Defaults.swift
        Sources/MacBar/Core/NotchStrings.swift
        Sources/MacBar/Core/NotchTourStrings.swift
        Sources/MacBar/Core/NotchEditorStrings.swift
        Sources/MacBar/UI/Settings/NotchSettingsTabRow.swift
        Sources/MacBar/Core/NotchActivityStrings.swift
        Sources/MacBar/Services/Notch/NotchTimerSupport.swift
        Sources/MacBar/Services/Notch/NotchTimerAlert.swift
        Sources/MacBar/UI/Notch/NotchIslandAlert.swift
        Sources/MacBar/Services/Notch/NotchAccessorySupport.swift
        Sources/MacBar/Services/QuickTools/CameraPreviewSupport.swift
        Sources/MacBar/Core/NotchMusicExtrasStrings.swift
        Sources/MacBar/Core/NotchClipboardSizeStrings.swift
        Sources/MacBar/Services/Notch/NotchLyricsSupport.swift
        Sources/MacBar/Services/Notch/NotchQueueSupport.swift
        Sources/MacBar/Services/Notch/NotchPreferredPlayer.swift
        Sources/MacBar/Core/NotchFilesStrings.swift
        Sources/MacBar/Core/NotchWatchStrings.swift
        Sources/MacBar/Services/Notch/NotchWatchSupport.swift
        Sources/MacBar/Core/NotchMascotStrings.swift
        Sources/MacBar/Services/Notch/NotchMascotSupport.swift
        Sources/MacBar/Services/CommandBar/CommandBarDropletMotion.swift
        Sources/MacBar/Services/Notch/NotchFileToolsSupport.swift
        Sources/MacBar/Services/Notch/NotchDownloadSupport.swift
        Sources/MacBar/Services/Notch/NotchDownloadProgressObserver.swift
        Sources/MacBar/Core/NotchCalendarStrings.swift
        Sources/MacBar/Core/NotchNotificationStrings.swift
        Sources/MacBar/Core/NotchGestureStrings.swift
        Sources/MacBar/Core/NotchAgentStrings.swift
        Sources/MacBar/Core/CodexAccountStrings.swift
        Sources/MacBar/Services/Notch/NotchAgentSupport.swift
        Sources/MacBar/Core/NotchLockScreenStrings.swift
        Sources/MacBar/Services/Notch/NotchLockScreenSupport.swift
        Sources/MacBar/Services/AgentUsage/AgentUsageModels.swift
        Sources/MacBar/Services/AgentUsage/AgentPricing.swift
        Sources/MacBar/Services/AgentUsage/AgentLogObject.swift
        Sources/MacBar/Services/AgentUsage/AgentLogParser.swift
        Sources/MacBar/Services/AgentUsage/Harness/AgentHarnessReader.swift
        Sources/MacBar/Services/AgentUsage/Harness/ClaudeReader.swift
        Sources/MacBar/Services/AgentUsage/Harness/CodexReader.swift
        Sources/MacBar/Services/AgentUsage/Harness/OpenCodeReader.swift
        Sources/MacBar/Services/AgentUsage/Harness/CopilotReader.swift
        Sources/MacBar/Services/AgentUsage/AgentUsageSummary.swift
        Sources/MacBar/Services/AgentUsage/AgentUsageStore.swift
        Sources/MacBar/Services/AgentUsage/AgentUsageArchive.swift
        Sources/MacBar/Services/AgentUsage/AgentClaudeAppUsage.swift
        Sources/MacBar/Services/AgentUsage/AgentCLIConversation.swift
        Sources/MacBar/Services/AgentUsage/AgentClaudeServer.swift
        Sources/MacBar/Services/AgentUsage/AgentCodexServer.swift
        Sources/MacBar/Services/AgentUsage/CodexAccountLimits.swift
        Sources/MacBar/Services/AgentUsage/CodexProfileLimitsService.swift
        Sources/MacBar/Services/AgentUsage/AgentOpenCodeReader.swift
        Sources/MacBar/Services/Notch/NotchGestureSupport.swift
        Sources/MacBar/Services/Notch/NotchSectionPaging.swift
        Sources/MacBar/Services/Notch/NotchSliderEditing.swift
        Sources/MacBar/Services/Notch/NotchNotificationSupport.swift
        Sources/MacBar/Services/Notch/NotchNotificationReaderCore.swift
        Sources/MacBar/Services/Notch/NotchCalendarSupport.swift
        Sources/MacBar/Services/Notch/NotchKeepAwakeSupport.swift
        Sources/MacBar/Services/Notch/NotchSupport.swift
        Sources/MacBar/Services/Notch/NotchAudioLevelSupport.swift
        Sources/MacBar/Services/Notch/NotchVolumeKeyGate.swift
        Sources/MacBar/Services/Notch/NotchMusicSupport.swift
        Sources/MacBar/UI/Notch/NotchDecorativeClock.swift
        Sources/MacBar/Services/Notch/NotchBrowserArtworkSupport.swift
        Sources/MacBar/UI/Notch/NotchEqualizerBars.swift
        Sources/MacBar/UI/Notch/NotchScrollEdgeFade.swift
        Sources/MacBar/UI/Notch/NotchAgentAnimationView.swift
        Sources/MacBar/UI/WindowVisibilityReader.swift
        Sources/MacBar/Services/Notch/NotchMusicAutomationSupport.swift
        Sources/MacBar/Services/Notch/NotchMusicAutomation.swift
        Sources/MacBar/Services/Notch/NotchPlaybackSource.swift
        Sources/MacBar/Services/Notch/NotchPlaybackCommand.swift
        Sources/MacBar/Services/Notch/NotchMusicCommandWriter.swift
        Sources/MacBar/Core/FeatureCatalog.swift
        Sources/MacBar/Core/FeaturePresets.swift
        Sources/MacBar/Core/FeatureHubStrings.swift
        Sources/MacBar/Core/ShortcutSettingsStrings.swift
        Sources/MacBar/Core/SettingsBackupSupport.swift
        Sources/MacBar/Core/BackupStrings.swift
        Sources/MacBar/Core/SnippetStrings.swift
        Sources/MacBar/Core/AlertSoundStrings.swift
        Sources/MacBar/Core/BrightnessStrings.swift
        Sources/MacBar/Core/MediaImageStrings.swift
        Sources/MacBar/Core/QuickToggleStrings.swift
        Sources/MacBar/Core/ScreenshotStrings.swift
        Sources/MacBar/Core/RecentCaptureStrings.swift
        Sources/MacBar/Core/RecorderStrings.swift
        Sources/MacBar/Core/RecorderShareStrings.swift
        Sources/MacBar/Core/CameraPreviewStrings.swift
        Sources/MacBar/Core/WallpaperStrings.swift
        Sources/MacBar/Services/Wallpaper/WallpaperSupport.swift
        Sources/MacBar/Core/ScratchpadStrings.swift
        Sources/MacBar/Core/FinderRenameStrings.swift
        Sources/MacBar/Core/CommandBarStrings.swift
        Sources/MacBar/Core/FeedbackStrings.swift
        Sources/MacBar/Core/RadialMenuStrings.swift
        Sources/MacBar/Core/MenuBarAppearanceStrings.swift
        Sources/MacBar/Core/AppAppearance.swift
        Sources/MacBar/Core/AppearanceStrings.swift
        Sources/MacBar/Core/GeneralSettingsStrings.swift
        Sources/MacBar/Core/SettingsPageStrings.swift
        Sources/MacBar/Core/BatteryTimeStrings.swift
        Sources/MacBar/Core/CPUCoreStrings.swift
        Sources/MacBar/Core/MonitorLayoutStrings.swift
        Sources/MacBar/Core/KeepAwakeStrings.swift
        Sources/MacBar/Core/BluetoothSleepStrings.swift
        Sources/MacBar/Core/PermissionGuideStrings.swift
        Sources/MacBar/Core/FanControlStrings.swift
        Sources/MacBar/Core/ConnectedDevicesStrings.swift
        Sources/MacBar/Services/FanControl/FanControlSupport.swift
        Sources/MacBar/Services/FanControl/FanControlResumeSupport.swift
        Sources/MacBar/Services/Snippets/TextSnippetSupport.swift
        Sources/MacBar/Services/RadialMenu/RadialMenuSupport.swift
        Sources/MacBar/Services/QuickTools/ScratchpadSupport.swift
        Sources/MacBar/Services/QuickTools/ScratchpadStore.swift
        Sources/MacBar/Services/KillProcess/KillProcessSupport.swift
        Sources/MacBar/Services/Recorder/RecorderSupport.swift
        Sources/MacBar/Services/Recorder/RecorderSampleTiming.swift
        Sources/MacBar/Services/Recorder/RecorderWriter.swift
        Sources/MacBar/Services/Recorder/RecorderCaptureEngine.swift
        Sources/MacBar/Core/RecorderExportStrings.swift
        Sources/MacBar/Services/Recorder/RecorderComposer.swift
        Sources/MacBar/Services/Recorder/RecorderComposerPlan.swift
        Sources/MacBar/Services/Recorder/RecorderCursorSprite.swift
        Sources/MacBar/Services/Recorder/RecorderTextRenderer.swift
        Sources/MacBar/Services/Recorder/RecorderImageRenderer.swift
        Sources/MacBar/Services/Recorder/RecorderExporter.swift
        Sources/MacBar/Services/Recorder/RecorderGIFClipboard.swift
        Sources/MacBar/Services/Recorder/RecorderGIFWriter.swift
        Sources/MacBar/Services/Recorder/RecorderGIFWorkspace.swift
        Sources/MacBar/Services/Recorder/RecorderComposition.swift
        Sources/MacBar/Services/Recorder/RecordingSharingSupport.swift
        Sources/MacBar/Services/PrivateFileStore.swift
        Sources/MacBar/Services/Recorder/RecorderTakeStore.swift
        Sources/MacBar/Services/Recorder/RecorderPresetImageStore.swift
        Sources/MacBar/Services/Recorder/RecorderMotion.swift
        Sources/MacBar/Services/Recorder/RecorderPointerTrack.swift
        Sources/MacBar/Services/Recorder/RecorderTypingTrack.swift
        Sources/MacBar/Services/Recorder/RecorderTimeline.swift
        Sources/MacBar/Services/Recorder/RecorderTextOverlay.swift
        Sources/MacBar/Services/Recorder/RecorderImageOverlay.swift
        Sources/MacBar/Services/Recorder/RecorderBlurRegion.swift
        Sources/MacBar/Services/Recorder/RecorderEditDocument.swift
        Sources/MacBar/Core/AppInfo.swift
        Sources/MacBar/Core/GlobalShortcut.swift
        Sources/MacBar/Core/SymbolicHotKeys.swift
        Sources/MacBar/Services/SystemShortcutTakeoverSupport.swift
        Sources/MacBar/Core/Localization.swift
        Sources/MacBar/Core/Localizations/Strings+*.swift
        Sources/MacBar/Core/FeatureStrings.swift
        Sources/MacBar/Core/KillProcessStrings.swift
        Sources/MacBar/Core/PortManagerStrings.swift
        Sources/MacBar/Core/WhatsAppDownloadStrings.swift
        Sources/MacBar/Core/WhatsAppOrganizerStrings.swift
        Sources/MacBar/Core/ReleaseNotes.swift
        Sources/MacBar/Core/ReleaseDigest.swift
        Sources/MacBar/Core/ReleaseChangeAliases.swift
        Sources/MacBar/Core/WhatsNewStrings.swift
        Sources/MacBar/Core/URLCleaning.swift
        Sources/MacBar/Services/GeneralPasteboardAccess.swift
        Sources/MacBar/Services/Clipboard/ClipboardHistoryWrite.swift
        Sources/MacBar/Services/Audio/AirPlayRouteManager.swift
        Sources/MacBar/Services/Audio/MixerRoutingSupport.swift
        Sources/MacBar/Services/Audio/MusicLaunchSupport.swift
        Sources/MacBar/Services/Bluetooth/BluetoothSleepSupport.swift
        Sources/MacBar/UI/MenuPanel/MixerPercentNativeTextField.swift
        Sources/MacBar/UI/MenuPanel/MixerAppDragSource.swift
        Sources/MacBar/Services/Audio/BoostLimiter.swift
        Sources/MacBar/Services/Audio/MixerRender.swift
        Sources/MacBar/Services/Audio/PreciseVolumeRollerSupport.swift
        Sources/MacBar/Services/DockPreview/DockPreviewSupport.swift
        Sources/MacBar/Services/DockPreview/DockAutohideHold.swift
        Sources/MacBar/Services/SpacesOrder/SpacesOrderHold.swift
        Sources/MacBar/Services/Homebrew/HomebrewSupport.swift
        Sources/MacBar/Services/Homebrew/HomebrewEnvironment.swift
        Sources/MacBar/Services/AppUpdates/AppUpdatesSupport.swift
        Sources/MacBar/Services/AppUpdates/AppUpdateFeedSupport.swift
        Sources/MacBar/Core/AppUpdateStrings.swift
        Sources/MacBar/Core/DiskImageInstallerStrings.swift
        Sources/MacBar/Services/DiskImageInstaller/DiskImageInstallerSupport.swift
        Sources/MacBar/UI/NonModalAlert.swift
        Sources/MacBar/Services/Clipboard/ClipboardHistorySupport.swift
        Sources/MacBar/Core/ColorValue.swift
        Sources/MacBar/Services/Clipboard/ClipboardAutoClearSupport.swift
        Sources/MacBar/Services/AutoQuit/AutoQuitSupport.swift
        Sources/MacBar/Services/Shelf/ShelfSupport.swift
        Sources/MacBar/Services/Shelf/ShelfFilePromiseTransfer.swift
        Sources/MacBar/Core/ShelfPromiseDeliveryStrings.swift
        Sources/MacBar/Services/Finder/FinderRenameSupport.swift
        Sources/MacBar/Services/Update/UpdateInstallerSupport.swift
        Sources/MacBar/Services/Update/UpdateServiceSupport.swift
        Sources/MacBar/Services/InstalledApps.swift
        Sources/MacBar/Services/LaunchAtLoginSupport.swift
        Sources/MacBar/UI/Settings/SettingsSearchSupport.swift
        Sources/MacBar/UI/Settings/SettingsSidebarSupport.swift
        Sources/MacBar/UI/Settings/FeatureVisibilitySupport.swift
        Sources/MacBar/UI/Onboarding/WhatsNewSupport.swift
        Sources/MacBar/UI/Settings/SettingsWindow.swift
        Sources/MacBar/Core/SettingsNavigationStrings.swift
        Sources/MacBar/App/MenuBarSpacingSupport.swift
        Sources/MacBar/App/MenuBarAllowanceSupport.swift
        Sources/MacBar/App/ReopenRequestSupport.swift
        Sources/MacBar/App/StatusItemAnchorSupport.swift
        Sources/MacBar/Services/DockClick/DockClickSupport.swift
        Sources/MacBar/Services/Finder/CutPasteProgressSupport.swift
        Sources/MacBar/Services/Finder/CutPastePrivilegeSupport.swift
        Sources/MacBar/Services/Finder/FinderPasteImageSupport.swift
        Sources/MacBar/Services/MiddleClick/MiddleClickSupport.swift
        Sources/MacBar/Services/MouseNavigation/MouseNavigationSupport.swift
        Sources/MacBar/Services/MouseNavigation/MouseNavigationKeys.swift
        Sources/MacBar/Services/MouseButtons/MouseButtonShortcutSupport.swift
        Sources/MacBar/Services/MouseButtons/MouseSpacesGestureSupport.swift
        Sources/MacBar/Services/MouseClickDebounce/MouseClickDebounceSupport.swift
        Sources/MacBar/Services/MouseExceptions/MouseAppExceptionSupport.swift
        Sources/MacBar/Services/MouseExceptions/MouseAppExceptions.swift
        Sources/MacBar/Services/WindowServerSupport.swift
        Sources/MacBar/Services/WindowMaximizerSupport.swift
        Sources/MacBar/Core/MouseButtonStrings.swift
        Sources/MacBar/Core/MouseClickDebounceStrings.swift
        Sources/MacBar/Core/MouseExceptionStrings.swift
        Sources/MacBar/Core/ClipboardIgnoredAppsStrings.swift
        Sources/MacBar/Core/ClipboardRetentionStrings.swift
        Sources/MacBar/Core/WindowLayoutIgnoredAppsStrings.swift
        Sources/MacBar/Services/WindowLayout/WindowLayoutIgnoredApps.swift
        Sources/MacBar/Core/WindowPreviewExclusionStrings.swift
        Sources/MacBar/Core/WindowMaximizerExclusionStrings.swift
        Sources/MacBar/Core/DiskExclusionStrings.swift
        Sources/MacBar/Core/SwitcherAppRulesStrings.swift
        Sources/MacBar/Services/QuickTools/QuickToolsSupport.swift
        Sources/MacBar/Services/CommandBar/CommandBarSupport.swift
        Sources/MacBar/Services/CommandBar/CommandBarPreferences.swift
        Sources/MacBar/Services/CommandBar/CommandBarMath.swift
        Sources/MacBar/Services/CommandBar/CommandBarUnits.swift
        Sources/MacBar/Services/CommandBar/CommandBarColors.swift
        Sources/MacBar/Services/CommandBar/CommandBarEmoji.swift
        Sources/MacBar/Services/CommandBar/CommandBarLinks.swift
        Sources/MacBar/Services/CommandBar/CommandBarDates.swift
        Sources/MacBar/Services/CommandBar/CommandBarRowShortcuts.swift
        Sources/MacBar/Services/CommandBar/CommandBarSystemSettingsSupport.swift
        Sources/MacBar/Services/CommandBar/CommandBarFileSearchSupport.swift
        Sources/MacBar/Services/CommandBar/CommandBarQueryMemory.swift
        Sources/MacBar/Services/SpotlightNamesSupport.swift
        Sources/MacBar/Services/QuickTools/MicMuteSupport.swift
        Sources/MacBar/Services/QuickTools/QuickTogglesSupport.swift
        Sources/MacBar/Services/QuickTools/ScreenshotCapturePolicy.swift
        Sources/MacBar/Services/QuickTools/ScreenshotSupport.swift
        Sources/MacBar/Services/QuickTools/ScreenshotCanvasSupport.swift
        Sources/MacBar/UI/Settings/ScreenCaptureToolPicker.swift
        Sources/MacBar/UI/Settings/MonitorToken.swift
        Sources/MacBar/Services/QuickTools/ScreenshotRenderer.swift
        Sources/MacBar/Services/QuickTools/ScreenshotImageLayerRendering.swift
        Sources/MacBar/Services/QuickTools/RecentCaptureStore.swift
        Sources/MacBar/Services/QuickTools/ScreenshotSharingSupport.swift
        Sources/MacBar/Services/QuickTools/WindowActivationPolicy.swift
        Sources/MacBar/Services/KeyboardDebounce/KeyboardDebounceSupport.swift
        Sources/MacBar/Services/SuperKey/SuperKeySupport.swift
        Sources/MacBar/Services/SuperKey/SuperKeyMappingGuard.swift
        Sources/MacBar/Core/SuperKeyStrings.swift
        Sources/MacBar/Core/InputSourceSelection.swift
        Sources/MacBar/Services/SessionActivity.swift
        Sources/MacBar/Services/SessionActivitySupport.swift
        Sources/MacBar/Services/EventTimestamp.swift
        Sources/MacBar/Services/OwnKeyEvent.swift
        Sources/MacBar/Services/ScrollWheelSupport.swift
        Sources/MacBar/Services/HorizontalWheelScrolling.swift
        Sources/MacBar/Services/SmoothScrollSupport.swift
        Sources/MacBar/Services/MouseAcceleration/MouseAccelerationSupport.swift
        Sources/MacBar/Services/FocusFollowsMouse/FocusFollowsMouseSupport.swift
        Sources/MacBar/Services/AssistiveKeyboard.swift
        Sources/MacBar/Services/Switcher/SwitcherModels.swift
        Sources/MacBar/Services/Switcher/WindowServerCaptureQueue.swift
        Sources/MacBar/Services/Switcher/SwitcherSupport.swift
        Sources/MacBar/Services/Switcher/SpaceHopSupport.swift
        Sources/MacBar/Services/Switcher/WindowUseOrder.swift
        Sources/MacBar/Services/Metrics/MetricFormat.swift
        Sources/MacBar/Services/Metrics/VMStatisticsDecoder.swift
        Sources/MacBar/Services/KeepAwakeAutomationSupport.swift
        Sources/MacBar/Services/SudoersSupport.swift
        Sources/MacBar/Services/Metrics/BatteryTimeSupport.swift
        Sources/MacBar/Services/Metrics/BatteryPowerSupport.swift
        Sources/MacBar/Services/BoundedProcessRunner.swift
        Sources/MacBar/Services/DetachedProcess.swift
        Sources/MacBar/Services/ShellSupport.swift
        Sources/MacBar/Services/PortManager/PortManagerSupport.swift
        Sources/MacBar/Services/Metrics/NetworkProcessSupport.swift
        Sources/MacBar/Services/Metrics/NetworkSampler.swift
        Sources/MacBar/Services/Metrics/NetworkAddressService.swift
        Sources/MacBar/Services/Metrics/SpeedTest.swift
        Sources/MacBar/Services/Metrics/PeripheralBatterySampler.swift
        Sources/MacBar/Services/Metrics/PeripheralBatterySupport.swift
        Sources/MacBar/Services/Metrics/DiskSupport.swift
        Sources/MacBar/Services/Metrics/MonitorSamplingPolicy.swift
        Sources/MacBar/Services/Metrics/USBDeviceSampler.swift
        Sources/MacBar/Services/Metrics/CPUCoreSampler.swift
        Sources/MacBar/Services/Metrics/MaxCapacityProbe.swift
        Sources/MacBar/Services/Metrics/TemperatureSensorSelector.swift
        Sources/MacBar/Services/Metrics/SustainedAlertGate.swift
        Sources/MacBar/Services/WindowLayout/WindowLayoutSupport.swift
        Sources/MacBar/Services/WindowLayout/WindowGestureSupport.swift
        Sources/MacBar/Core/WindowDirectionalStrings.swift
        Sources/MacBar/Core/PointerDisplayStrings.swift
        Sources/MacBar/Core/GraphScaleStrings.swift
        Sources/MacBar/Core/NotchLowBatteryStrings.swift
        Sources/MacBar/Services/CleaningMode/CleaningUnlockCounter.swift
        Sources/MacBar/Services/CleaningMode/CleaningMouseReleaseGate.swift
        Sources/MacBar/Services/Display/ExtraBrightnessSupport.swift
        Sources/MacBar/Services/Display/BrightnessSupport.swift
        Sources/MacBar/Services/Display/LidDimmingSupport.swift
        Sources/MacBar/Services/Cleaner/CleanerSupport.swift
        Sources/MacBar/Services/Cleaner/CleanerPolicy.swift
        Sources/MacBar/Services/Cleaner/CleanerSchedule.swift
        Sources/MacBar/Services/Uninstall/UninstallerSupport.swift
        Sources/MacBar/Services/ManagedDownloads/WhatsAppDownloadSupport.swift
        Sources/MacBar/Core/SecureInputSupport.swift
        Tests/*.swift
        build/generated-tests/*.swift
    )
    TEST_OUTPUT_FILE_MAP="$TEST_OBJECT_DIR/output-file-map.json"
    write_swift_output_file_map "$TEST_OUTPUT_FILE_MAP" "$TEST_OBJECT_DIR" "${TEST_SOURCES[@]}"
    echo "▸ Building & running tests against $(basename "$SDK")…"
    swiftc -Onone -incremental -enable-batch-mode -j "$(sysctl -n hw.logicalcpu)" \
        -module-name MacBarTests -output-file-map "$TEST_OUTPUT_FILE_MAP" \
        -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" \
        "${VM_STATISTICS_COMPAT_FLAGS[@]}" "${TEST_SOURCES[@]}" -o build/metrics-tests
    test_status=0
    ./build/metrics-tests "${TEST_ARGS[@]}" || test_status=$?
    if (( ${#TEST_ARGS} == 0 )); then
        ./Tests/PreferenceCleanupTests.sh || test_status=1
        ./Tests/UninstallSpacesTests.sh || test_status=1
        ./Tests/DeveloperInstallIsolationTests.sh || test_status=1
    fi
    discard_test_preferences || test_status=1
    exit $test_status
fi

echo "▸ Compiling ($BUILD_CONFIGURATION) against $(basename "$SDK")…"
APP_SOURCES=(Sources/MacBar/**/*.swift)
if (( ! DEV )); then
    # A release starts from an empty build directory, so nothing an earlier
    # build left behind (an old icon catalog, a staged bundle) can reach it.
    # Only the compiler's incremental records stay: they rebuild whatever
    # changed since, and a fresh checkout has none.
    find build -mindepth 1 -maxdepth 1 ! -name objects -exec rm -rf {} + 2>/dev/null || true
fi
APP_OBJECT_DIR="build/objects/$EXECUTABLE"
mkdir -p build "$APP_OBJECT_DIR"
APP_OUTPUT_FILE_MAP="$APP_OBJECT_DIR/output-file-map.json"
write_swift_output_file_map "$APP_OUTPUT_FILE_MAP" "$APP_OBJECT_DIR" "${APP_SOURCES[@]}"
# Without -j the driver compiles one file at a time, and without batch mode
# each file's compiler parses the whole module again: a clean release took a
# quarter of an hour. Batches share that work and run on every core, and the
# optimization stays per file, as before.
swiftc "${APP_OPTIMIZATION_FLAGS[@]}" -incremental -enable-batch-mode -j "$(sysctl -n hw.logicalcpu)" \
    -output-file-map "$APP_OUTPUT_FILE_MAP" \
    -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" "${VM_STATISTICS_COMPAT_FLAGS[@]}" "${HID_EVENT_SYSTEM_FLAGS[@]}" \
    "${BUILD_VARIANT_FLAGS[@]}" \
    "${APP_SOURCES[@]}" -o "build/$EXECUTABLE"

echo "▸ Compiling protected fan helper…"
swiftc -O -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" "${BUILD_VARIANT_FLAGS[@]}" \
    Sources/MacBar/Services/FanControl/FanControlSupport.swift \
    Sources/MacBar/Services/FanControl/FanControlXPC.swift \
    Sources/MacBar/Services/SystemMonitor/SMCClient.swift \
    Sources/MacBar/Services/Metrics/TemperatureSensorSelector.swift \
    Sources/MacBar/Services/FanControl/FanControlHardware.swift \
    Sources/FanControlHelper/main.swift \
    -o "build/$FAN_HELPER_ID"
"build/$FAN_HELPER_ID" --selftest

echo "▸ Compiling Now Playing adapter…"
swiftc -O -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" -emit-library \
    -module-name MacBarNowPlaying \
    Sources/NowPlayingAdapter/NowPlayingAdapter.swift \
    Sources/NowPlayingAdapter/NowPlayingQueue.swift \
    Sources/NowPlayingAdapter/NowPlayingSelection.swift \
    Sources/MacBar/Services/Notch/NotchPlaybackSource.swift \
    Sources/MacBar/Services/Notch/NotchPlaybackCommand.swift \
    -o "build/$NOW_PLAYING_ADAPTER"

echo "▸ Generating app icon…"
swift Tools/MakeIcon.swift build/AppIcon.iconset
xattr -c -r build/AppIcon.iconset build/AppIcon.icns build/MenuBarIcon.png build/MenuBarIcon@2x.png build/BrandMark.png 2>/dev/null || true
ACTOOL_BIN="$(xcrun --find actool 2>/dev/null || true)"
ICON_TMP="$(mktemp -d)"
ADAPTIVE_SKIP=""
if [[ -z "$ACTOOL_BIN" ]]; then
    ADAPTIVE_SKIP="actool not found (adaptive icons need Xcode 26+)"
else
    echo "▸ Compiling adaptive icon catalog…"
    # actool crashes on File Provider-synced paths, so compile a local copy.
    ditto "Resources/Brand/AppIcon.icon" "$ICON_TMP/AppIcon.icon"
    # Xcode 27 beta actool requires the --compile target directory to already exist.
    mkdir -p "$ICON_TMP/catalog"
    if "$ACTOOL_BIN" "$ICON_TMP/AppIcon.icon" \
            --compile "$ICON_TMP/catalog" \
            --app-icon AppIcon \
            --platform macosx \
            --target-device mac \
            --minimum-deployment-target 14.0 \
            --enable-on-demand-resources NO \
            --output-partial-info-plist "$ICON_TMP/partial-info.plist" \
            >"$ICON_TMP/actool.log" 2>&1 && [[ -s "$ICON_TMP/catalog/Assets.car" ]]; then
        mv "$ICON_TMP/catalog/Assets.car" build/Assets.car
    else
        ADAPTIVE_SKIP="actool could not compile the catalog"
    fi
fi
if [[ -n "$ADAPTIVE_SKIP" ]]; then
    cp "$ICON_TMP/actool.log" build/actool-failure.log 2>/dev/null || true
    echo "  adaptive icon skipped: $ADAPTIVE_SKIP (Dock falls back to AppIcon.icns)"
fi
echo "▸ Assembling and signing bundle…"
STAGE_TMP="$(mktemp -d)"
STAGE="$STAGE_TMP/$APP_NAME.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" \
    "$STAGE/Contents/Library/LaunchDaemons" "$STAGE/Contents/Library/LaunchServices"
cp "build/$EXECUTABLE" "$STAGE/Contents/MacOS/$EXECUTABLE"
cp "build/$FAN_HELPER_ID" "$STAGE/Contents/Library/LaunchServices/$FAN_HELPER_ID"
mkdir -p "$STAGE/Contents/Frameworks"
cp "build/$NOW_PLAYING_ADAPTER" "$STAGE/Contents/Frameworks/$NOW_PLAYING_ADAPTER"
cp Resources/now-playing.pl "$STAGE/Contents/Resources/now-playing.pl"
cp Resources/agent-prices.json "$STAGE/Contents/Resources/agent-prices.json"
cp Resources/com.erold90.macbar.fan-control.plist \
    "$STAGE/Contents/Library/LaunchDaemons/$FAN_HELPER_ID.plist"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"
cp CHANGELOG.md "$STAGE/Contents/Resources/CHANGELOG.md"
for lproj in Resources/*.lproj(N); do
    cp -R "$lproj" "$STAGE/Contents/Resources/"
done
if (( DEV )); then
    # A distinct identity so the Developer build installs and runs next to the
    # official app, with its own permissions, preferences and login item.
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $APP_BUNDLE_ID" "$STAGE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$STAGE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$STAGE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $EXECUTABLE" "$STAGE/Contents/Info.plist"
    FAN_PLIST="$STAGE/Contents/Library/LaunchDaemons/$FAN_HELPER_ID.plist"
    /usr/libexec/PlistBuddy -c "Set :Label $FAN_HELPER_ID" "$FAN_PLIST"
    /usr/libexec/PlistBuddy -c "Set :BundleProgram Contents/Library/LaunchServices/$FAN_HELPER_ID" "$FAN_PLIST"
    /usr/libexec/PlistBuddy -c "Delete :MachServices:com.erold90.macbar.fan-control" "$FAN_PLIST"
    /usr/libexec/PlistBuddy -c "Add :MachServices:$FAN_HELPER_ID bool true" "$FAN_PLIST"
    # Stamp the source commit + build time so the running dev app shows (in About)
    # exactly which code it was compiled from. Lets you verify it matches HEAD before
    # testing, instead of unknowingly running a stale build. Dev-only; never shipped.
    SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    [[ -n "$(git status --porcelain 2>/dev/null)" ]] && SHA="$SHA-dirty"
    /usr/libexec/PlistBuddy -c "Add :MacBarBuildCommit string '$SHA · $(date '+%Y-%m-%d %H:%M')'" "$STAGE/Contents/Info.plist"
    echo "  stamped dev build: $SHA"
fi
FAN_HELPER_VERSION="$(
    export LC_ALL=C
    /usr/bin/shasum -a 256 \
        "$STAGE/Contents/Library/LaunchServices/$FAN_HELPER_ID" \
        "$STAGE/Contents/Library/LaunchDaemons/$FAN_HELPER_ID.plist" \
        | /usr/bin/awk '{print $1}' | /usr/bin/shasum -a 256 \
        | /usr/bin/awk '{print $1}'
)"
/usr/libexec/PlistBuddy -c "Add :MacBarFanControlHelperVersion string '$FAN_HELPER_VERSION'" \
    "$STAGE/Contents/Info.plist"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"
cp build/AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
cp build/MenuBarIcon.png build/MenuBarIcon@2x.png build/BrandMark.png "$STAGE/Contents/Resources/"
if [[ -f build/Assets.car ]]; then
    cp build/Assets.car "$STAGE/Contents/Resources/Assets.car"
fi
if [[ -d Resources/Gifs ]]; then
    mkdir -p "$STAGE/Contents/Resources/Gifs"
    cp Resources/Gifs/*.gif "$STAGE/Contents/Resources/Gifs/"
fi
if ! cmp -s Resources/Gifs/highlights-notch.gif "$STAGE/Contents/Resources/Gifs/highlights-notch.gif"; then
    echo "Dynamic Island tour GIF is missing or differs from the bundled copy" >&2
    exit 1
fi
if [[ -d Resources/Images ]]; then
    mkdir -p "$STAGE/Contents/Resources/Images"
    cp Resources/Images/* "$STAGE/Contents/Resources/Images/"
fi
xattr -c -r "$STAGE" 2>/dev/null || true

# Signing, in order of preference:
#   1. Developer ID Application — the real, Apple-issued identity used for
#      notarized releases. Signed with the hardened runtime (required for
#      notarization), the app's entitlements and a secure timestamp. Gives a
#      stable, team-based designated requirement, so permissions persist across
#      updates AND Gatekeeper shows no "unverified developer" warning.
#   2. "MacBar Local Signing" — the legacy stable self-signed identity, kept
#      as a fallback so contributors without a Developer ID still get a constant
#      designated requirement across their local builds.
#   3. Ad-hoc — fresh clone with no identity at all.
DEVID="$(developer_id_identity)"
codesign_app() {
    local target="$1"
    if [[ -n "$DEVID" ]]; then
        codesign_with_timestamp_retry --force --strip-disallowed-xattrs --options runtime --timestamp \
            --entitlements "$ENTITLEMENTS" --sign "$DEVID" "$target"
    elif legacy_identity_installed; then
        codesign --force --strip-disallowed-xattrs --sign "$LEGACY_IDENTITY" "$target"
    else
        codesign --force --strip-disallowed-xattrs --sign - "$target"
    fi
}

codesign_fan_helper() {
    local target="$1"
    if [[ -n "$DEVID" ]]; then
        codesign_with_timestamp_retry --force --strip-disallowed-xattrs --options runtime --timestamp \
            --identifier "$FAN_HELPER_ID" --sign "$DEVID" "$target"
    elif legacy_identity_installed; then
        codesign --force --strip-disallowed-xattrs --identifier "$FAN_HELPER_ID" \
            --sign "$LEGACY_IDENTITY" "$target"
    else
        codesign --force --strip-disallowed-xattrs --identifier "$FAN_HELPER_ID" --sign - "$target"
    fi
}

codesign_now_playing_adapter() {
    local target="$1"
    if [[ -n "$DEVID" ]]; then
        codesign_with_timestamp_retry --force --strip-disallowed-xattrs --options runtime --timestamp \
            --identifier "$NOW_PLAYING_ADAPTER_ID" --sign "$DEVID" "$target"
    elif legacy_identity_installed; then
        codesign --force --strip-disallowed-xattrs --identifier "$NOW_PLAYING_ADAPTER_ID" \
            --sign "$LEGACY_IDENTITY" "$target"
    else
        codesign --force --strip-disallowed-xattrs --identifier "$NOW_PLAYING_ADAPTER_ID" --sign - "$target"
    fi
}

sign_bundle() {
    local bundle="$1"
    local executable="$bundle/Contents/MacOS/$EXECUTABLE"
    local helper="$bundle/Contents/Library/LaunchServices/$FAN_HELPER_ID"
    local adapter="$bundle/Contents/Frameworks/$NOW_PLAYING_ADAPTER"

    if [[ -n "$DEVID" ]]; then
        echo "  signing with Developer ID (hardened runtime): $DEVID"
    elif legacy_identity_installed; then
        echo "  signing with legacy self-signed identity: $LEGACY_IDENTITY"
    else
        echo "  signing ad-hoc (no identity installed — run Tools/setup-signing.sh)"
    fi
    [[ -f "$helper" ]] && codesign_fan_helper "$helper"
    [[ -f "$adapter" ]] && codesign_now_playing_adapter "$adapter"
    codesign_app "$bundle"

    # If local filesystem metadata invalidates the first signature, sign once
    # more. The installed Developer bundle is signed again after the final copy.
    if ! codesign --verify --deep --strict "$bundle" >/dev/null 2>&1; then
        echo "  re-signing after filesystem metadata settled"
        xattr -c -r "$bundle" 2>/dev/null || true
        [[ -f "$helper" ]] && codesign_fan_helper "$helper"
        [[ -f "$adapter" ]] && codesign_now_playing_adapter "$adapter"
        codesign_app "$bundle"
    fi
    [[ -f "$executable" ]] && codesign --verify --strict "$executable"
    [[ -f "$helper" ]] && codesign --verify --strict "$helper"
    [[ -f "$adapter" ]] && codesign --verify --strict "$adapter"
    codesign --verify --deep --strict "$bundle"
}

sign_installed_bundle() {
    local bundle="$1"
    wait_for_install_metadata "$bundle"
    sign_bundle "$bundle"
}

sign_bundle "$STAGE"

process_is_running() {
    local proc="$1"
    if (( ${#proc} > 15 )); then
        pgrep -f "/Contents/MacOS/$proc" >/dev/null 2>&1
    else
        pgrep -x "$proc" >/dev/null 2>&1
    fi
}

stop_process() {
    local proc="$1"
    if (( ${#proc} > 15 )); then
        pkill -f "/Contents/MacOS/$proc" 2>/dev/null || true
    else
        pkill -x "$proc" 2>/dev/null || true
    fi
    for _ in {1..50}; do
        if ! process_is_running "$proc"; then
            return 0
        fi
        sleep 0.1
    done
    echo "✗ $proc is still running — quit it and retry" >&2
    return 1
}

wait_for_install_metadata() {
    local bundle="$1"
    local missing
    for _ in {1..50}; do
        missing=0
        while IFS= read -r file; do
            if ! xattr -p com.apple.provenance "$file" >/dev/null 2>&1; then
                missing=1
                break
            fi
        done < <(find "$bundle/Contents" -type f ! -path "*/_CodeSignature/*")
        if (( missing == 0 )); then
            return 0
        fi
        sleep 0.1
    done
}

# Installed development builds only need the copy in /Applications. Retaining
# another app in each checkout pollutes application search with stale builds.
if (( DEV )); then
    for old_bundle in "build/stage/$APP_NAME.app" "build/stage.noindex/$APP_NAME.app"; do
        if [[ -d "$old_bundle" ]]; then
            /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
                -u "$PWD/$old_bundle" >/dev/null 2>&1 || true
            rm -rf "$old_bundle"
        fi
    done
fi

if (( !DEV || !INSTALL )); then
    STAGE_DIRECTORY="build/stage"
    (( DEV )) && STAGE_DIRECTORY="build/stage.noindex"
    mkdir -p "$STAGE_DIRECTORY"
    BUILD_STAGE="$STAGE_DIRECTORY/$APP_NAME.app"
    rm -rf "$BUILD_STAGE"
    ditto --noextattr --noqtn "$STAGE" "$BUILD_STAGE"
    xattr -c -r "$BUILD_STAGE" 2>/dev/null || true
    if ! codesign --verify --deep --strict "$BUILD_STAGE" >/dev/null 2>&1; then
        if xattr -lr "$BUILD_STAGE" 2>/dev/null | grep -Eq 'com\.apple\.(FinderInfo|ResourceFork|provenance|fileprovider)'; then
            echo "  staging copy has local filesystem metadata; temp bundle was verified"
        else
            codesign --verify --deep --strict "$BUILD_STAGE"
        fi
    fi
    echo "✓ Bundle ready: $BUILD_STAGE"
fi

if (( INSTALL )); then
    echo "▸ Installing into /Applications…"
    stop_process "$EXECUTABLE"
    INSTALL_DEST="/Applications/$APP_NAME.app"
    rm -rf "$INSTALL_DEST"
    ditto --noextattr --noqtn "$STAGE" "$INSTALL_DEST"
    sign_installed_bundle "$INSTALL_DEST"
    echo "✓ Installed: $INSTALL_DEST"
fi

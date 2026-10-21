# Troubleshooting

A quick guide to the snags people hit most. If none of it helps, jump to [reporting a useful bug](#reporting-a-useful-bug) at the end.

The permission and uninstall commands below all point at MacBar's bundle identifier, `com.erold90.macbar`.

## The app will not open

Official MacBar builds are signed with an Apple Developer ID and notarized, so they open with no security warning.

If you built the app yourself or grabbed an unofficial copy, macOS Gatekeeper may stop it on the first launch. To open it anyway, do one of these.

1. Right click, or Control click, MacBar in Applications, choose Open, and confirm.
2. Or open System Settings, Privacy and Security, find the note about MacBar being blocked, and click Open Anyway.

MacBar lives in the menu bar, so once it starts, look for its icon up there rather than in the Dock.

## A feature does nothing, or a permission will not stick

Most features lean on a macOS permission, which the [permissions guide](PERMISSIONS.md) lays out. When something does nothing, walk through this.

1. Open System Settings, Privacy and Security.
2. Find the permission the feature needs and make sure MacBar is listed and switched on.
3. If it is listed and still quiet, toggle it off and back on.

MacBar keeps an eye on Accessibility and Screen Recording, so features tend to wake up within a second or two of a grant, with no relaunch needed.

### Accessibility

This one powers the scroll direction inverter, Window Layout, the switcher, Dock Preview, Finder cut and paste and quit on close. If they do nothing, open System Settings, Privacy and Security, Accessibility and confirm MacBar is switched on. If you rebuilt the app yourself, its signature can shift and macOS may treat it as a different app, so remove the old MacBar entry with the minus button and grant it again. For steady local signing while you develop, see the [contributing guide](../CONTRIBUTING.md).

### Screen Recording

This one feeds window titles and thumbnails in the switcher and Dock Preview. If previews fall back to app icons or Dock Preview stays unavailable, switch MacBar on in System Settings, Privacy and Security, Screen Recording. macOS may ask you to quit and reopen the app after you grant it.

### System Audio Recording

This permission is used by the mixer, the optional live equalizer and system audio capture for recordings. If a feature asks for it, open System Settings, Privacy and Security, Screen and System Audio Recording, and switch MacBar on. See the [permissions guide](PERMISSIONS.md#system-audio-recording) for what each feature does with the audio.

### Automation

Finder cut and paste, the uninstaller and Homebrew's Terminal handoff may ask for Automation. If a Finder move or Terminal handoff does nothing after a denial, open System Settings, Privacy and Security, Automation, and allow MacBar for the app it needs to control.

## Clipboard history does not copy or paste

First check whether a fresh copy appears in history. History must be enabled,
and copies from excluded apps or marked as concealed are not saved. Compare
copy-only followed by Command-V with automatic paste. If only automatic paste
fails, check Accessibility and the app that should receive the paste.

A failed history copy sounds the system alert and does not trigger automatic
paste. A request also fails after five seconds, or if another history copy is
still pending. Expired requests that have not started are skipped. A write
already in progress can still change the clipboard; it cannot be rolled back.

If another app stops answering a clipboard read, history waits for that read
to end instead of adding more reads behind it. The deadline does not unblock
macOS. If copying fresh text does not restore history, quit and reopen the
source app and MacBar. Include the source app and macOS version in a report;
do not include private clipboard content.

## Homebrew and your shell startup files

Homebrew inside MacBar uses the proxy and `HOMEBREW_*` settings your shell
exports, so it reaches the same servers as Terminal. To find them, MacBar
starts your login shell once per launch, the way Terminal does, which reads
`~/.zprofile` and `~/.zshrc`. Because MacBar starts it, a startup file that
reads a protected folder asks for access in MacBar's name.

During that run `MACBAR_RESOLVING_ENVIRONMENT` is set to `1`. A startup file
can check it to skip work that only makes sense in a terminal window, such as
starting a multiplexer or a slow prompt:

```sh
[[ -n $MACBAR_RESOLVING_ENVIRONMENT ]] && return
```

## Resetting permissions

To wipe MacBar's granted permissions and let macOS ask again from scratch, pick one of these.

- **From the app.** Settings under Advanced has a reset that clears every permission you granted, the login item and the closed lid rule, while leaving the app installed.
- **From Terminal.** Reset all of MacBar's privacy permissions at once.

  ```sh
  tccutil reset All com.erold90.macbar
  ```

  Or reset a single kind, for example.

  ```sh
  tccutil reset Accessibility com.erold90.macbar
  tccutil reset ScreenCapture com.erold90.macbar
  ```

  A self-built Developer variant has its own grants under
  `com.erold90.macbar.dev`. Resetting is the way out when System Settings
  shows the permission as granted but the app disagrees — that happens when a
  grant was given to an earlier ad-hoc build whose signature no longer matches.

## Clean uninstall

The bundled script takes out everything MacBar added, the app itself, its preferences and saved state, the login item, its privacy grants, and the optional closed lid `sudoers` rule.

```sh
./Tools/uninstall.sh
```

Run it from a clone of the repository, or download the single script from the repo. Would you rather do it by hand? Quit MacBar, drag it from Applications to the Trash, then clear its permissions.

```sh
tccutil reset All com.erold90.macbar
```

## Reporting a useful bug

A clear report gets fixed faster. Try to include the following.

- **What you did**, what you expected, and what actually happened.
- **Your versions**, both the MacBar version from Settings under About and your macOS version.
- **Steps to reproduce**, as specific as you can make them.
- **A screenshot or short screen recording**, when the issue is something you can see.

If you have a build from source, the self test prints a quick health summary that is handy to paste in.

```sh
./build/MacBar --selftest
```

Open a report from the [new issue](https://github.com/erold90/macbar/issues/new/choose) page, and see [support](../SUPPORT.md) for every way to get help.

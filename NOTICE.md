# Notice and attribution

MacBar is a **modified fork** of [Vorssaint](https://github.com/vorssaint/vorssaint-utils)
(`vorssaint-utils`), by the Vorssaint maintainer(s), licensed under the
GNU General Public License v3.0 or later. This fork is not affiliated with, endorsed by,
or an official build of Vorssaint.

- The original copyright notices and SPDX headers are kept in the source files.
- The full license text is in [LICENSE](LICENSE). MacBar is distributed under the same terms.
- The original history is preserved in this repository (`git log`); `CHANGELOG.md` is the
  upstream changelog up to the fork point (v3.4.2-beta.2, commit `afe36628`).

## What was changed

1. **Intel Mac build.** `build.sh` targets `x86_64` by default (set `ARCH=arm64` for Apple Silicon).
2. **New name and identity.** The Vorssaint name, logo, app icon, bundle identifiers
   (`com.erold90.macbar…`), signing identity and update feed are not used. The icon and
   logo in `Resources/Brand` are original artwork drawn by `Tools/MakeBrandAssets.swift`.
3. **No upstream services.** The hosted screenshot/recording share links pointed to the upstream
   maintainer's server; they now point to `share.invalid` (a name that can never resolve), so nothing
   is uploaded anywhere. The feedback form is replaced by this repository's GitHub issue forms.
   Donation, Discord and social links to the upstream maintainer were removed.
4. **Homebrew on Intel.** The Homebrew manager recognises the "Xcode is too outdated" failure that Intel Macs get now that Homebrew builds no bottles for them, hides such updates (they return when a newer version is released) and tags updates as Recommended or Optional.
5. **No implicit keychain changes.** `build.sh` no longer creates a signing keychain by itself;
   run `Tools/setup-signing.sh` if you want a stable local signing identity.
6. Release automation (`.github/workflows`, funding file, code owners, promo video) was removed.

Agent pricing data (`Resources/agent-prices.json`) is still refreshed from the upstream
repository's public raw file; that request carries no user data.

# Third-party notices

The macOS app bundles two open-source libraries as separate, replaceable dynamic libraries
in `OpenLink Tuner.app/Contents/Frameworks`. Their license texts are included in the app at
`Contents/Resources/Licenses/`.

| Library | Version | License | Source |
|---|---|---|---|
| libftdi | 1.5 | LGPL-2.1 | https://www.intra2net.com/en/developer/libftdi/ |
| libusb | 1.0.30 | LGPL-2.1-or-later | https://libusb.info |

You may replace either library with your own build (same file name) — the app loads them
dynamically at runtime.

## Not included

No software, tune files or other files from Link Engine Management Ltd are included in this
repository or in the released apps. `src/Resources/catalog.json` lists parameter names and
categories so the app can show settings by name; ECU layouts come from the user's own tune
files or from Link's installer on the user's own computer.

# Building the DukeX 16:9 iOS test IPA on GitHub

This fork adds an **Aspect Ratio** selector to the iOS Settings → Display
screen: **Auto**, **4:3**, and **16:9**.

## Build with GitHub Actions

1. Open this repository's **Actions** tab.
2. Choose **Build DukeX iOS (unsigned IPA)**.
3. Select **Run workflow** on `master`.
4. Open the completed workflow run and download the
   **DukeX-16x9-unsigned-IPA** artifact.
5. Extract the downloaded artifact ZIP. It contains
   `DukeX-16x9-unsigned.ipa`.

The IPA is **unsigned**. It cannot be installed directly without signing it
using your own supported iOS signing/sideloading process. It is deliberately
not uploaded as a signed release and contains no Apple signing credentials.

The workflow changes only the iOS app. It obtains the three existing runtime
libraries (`libxemu-ios-core.dylib`, `libslirp.0.dylib`, and
`MoltenVK.framework`) from the official **DukeX v1.0.2** IPA and checks
that downloaded IPA's SHA-256 against the published release digest before
extracting anything. This is suitable for this feature because the Xbox
emulation core has not been changed in our fork. If the source or core ABI
changes in a future version, update this approach or build the core from
source instead.

The test application's bundle identifier is
`com.demonkingronin.dukex`, distinct from the official
`com.mafty.dukex` identifier. The fork's Vulkan/Metal-presenter
initialization explicitly recognizes the new identifier.

**Important:** This is a new app container. Xbox system files, game images,
settings, and save data in the original app are not automatically copied.
For iOS 26 or later, set up the appropriate JIT handoff for the new bundle
identifier in your signing/debugging workflow.

## Verify the display feature

1. Launch your fork. Visit **Settings → Display → Aspect Ratio**.
2. Run the same game in **Auto**, **4:3**, then **16:9**, exiting and
   reopening the emulated game after each setting change.
3. Close and reopen the DukeX app to check the choice is retained.
4. If the game is not natively widescreen-capable, 16:9 may horizontally
   stretch the image. It does **not** expand the game's field of view.

## Troubleshooting

If the GitHub Actions job fails, open the failing step's log. A build-log
artifact is uploaded when the compiler step produces a log but the workflow
fails. A successful Actions run only confirms packaging: a separately
signed installation and an actual iPhone test are still necessary.

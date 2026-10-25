# Draft for forum.modular.com, category Licensing (not posted; the owner posts it)

**Title:** Bundling libKGENCompilerRTShared and libAsyncRTMojoBindings in a Mac app: OK under the new MAX License?

Hi all, a question about the new MAX License (last modified October 21, 2026) and shipping a desktop app.

**What we're building.** [omxcode](https://github.com/abhisheksreesaila/omxcode) is an open-source framework for writing an app once in Mojo and running it natively on Linux, the Mac, iPhone, Android and the web. Its showcase app, omxplorer, is a spreadsheet-like data explorer. The app uses no MAX graph, no models and no serving. Its own query engine is written in Mojo, and on a Mac its kernels run on Apple's GPU through Metal, using Mojo's `gpu` APIs and `DeviceContext`.

**What the app carries.** A native `mojo build` on macOS (Mojo 1.1.0 and MAX 26.6.0 from PyPI, through pixi) links your runtime through `@rpath`. Our [Mac download](https://github.com/abhisheksreesaila/omxcode/releases/tag/mac-app) is already published, so this isn't hypothetical. It carries four of your libraries, byte for byte (not modified, not re-signed), in `OmxplorerMojo.app/Contents/Frameworks/`:

- `libKGENCompilerRTShared.dylib`, `libAsyncRTRuntimeGlobals.dylib` and `libMSupportGlobals.dylib`, from the `mojo-compiler` 1.1.0 wheel
- `libAsyncRTMojoBindings.dylib`, from the `max-core` 26.6.0 wheel

The app includes the Modular MAX Community License text and your third-party notices in `Contents/Resources/Licenses/`. It also has a `NOTICE.txt` beside the app with the §1.1.4 attribution, which says the app's own code is MIT and your libraries stay under your terms. The app does a great deal more than these libraries. If any of this isn't OK, we'll change it or pull the GPU build.

**Our questions**

1. We think the sources in modular/modular say these libraries are licensed differently. `libKGENCompilerRTShared` is built from Mojo and AsyncRT sources whose headers (e.g. `AsyncRT/lib/CompilerSupport/Context.cpp`) say Apache 2.0 with LLVM exceptions. `libAsyncRTMojoBindings` comes from `MLRT/lib/Driver/DeviceContext/MojoBindings.cpp`, whose header says MAX License. Did we read that right? And does the §1.2 grant ("redistribute MAX as part of Your Applications, in object code form") cover shipping the second one, unchanged, inside a desktop app?
2. Which licence applies to versions released **before** October 21? The PyPI wheels for mojo-compiler 1.1.0 and max-core 26.6.0 say `License: LicenseRef-MAX-Platform-Software-License` but include no licence text. The conda packages of the same versions ship the Modular MAX Community License (August 18, 2026). Under §9 we read it as: keep the terms we downloaded under, or move to a release made after the 21st. Is that right, and which text should we put in the app?
3. Is "a human-readable copy of these Terms" in the bundle, plus a notice beside the app, enough for the display and notice requirements? Or do you want the notice somewhere specific, such as the About window?
4. Is there a list of "Redistributable Components" (the Community License points to the Documentation for one)? Are these four on it? Is there a supported way to link these runtime pieces statically, or to avoid them, for a standalone app?

Thanks! Happy to share the build script if it helps.

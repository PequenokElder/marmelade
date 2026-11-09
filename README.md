# Marmalade

A small, fast Mac app for giving flat-profile photos a finished look. Drop in JPEGs (or RAW files), dial in a look, and export graded JPEGs to a folder. Your originals are never touched.

Built with SwiftUI and Core Image. No Xcode project, no third-party dependencies.

## What it does

- **Drag and drop** photos or whole folders. Files are read in place.
- **Enhance** with exposure, contrast, saturation, vibrance, warmth and tint, using curves that never clip pure black or white.
- **Safeguards** against blocky or broken color: a color limit, skin-tone protection, color-noise reduction and anti-banding dither.
- **Film look:** rolloff, warm/cool shadows and highlights, bloom, red halation, vignette and film grain with adjustable size.
- **Film stocks:** seven hand-tuned looks (Gold 200, Portra 400, Ektar 100, Fuji 400H, Tungsten 800, Velvia 50, Tri-X 400). These are approximations of each film's character, not measured profiles.
- **LUT library:** add `.cube` 3D LUTs once and keep them. LUTs stack with the enhance steps and have an intensity slider.
- **Slices:** save your whole look (every slider plus the LUT) and reapply it with one click.
- **RAW:** developed with Apple's RAW engine, with white balance, true exposure, tone boost, shadows and sharpness.
- **Per-photo exposure and white balance** on top of the global look.
- **Output color:** match source, sRGB or Display P3.
- **Montage:** turn your graded photos into a vertical 9:16 MP4 (1080×1920). Frames hold 2, 3 or 4 photos, chosen automatically from each photo's shape, with crops that follow faces and the main subject (Apple's on-device Vision framework). Set a **BPM** (type it, tap it, or detect it from a music track) and cuts land on the beat, with cut, fade or push transitions and optional music in the video.

## Requirements

- macOS 13 or later
- The Xcode Command Line Tools (`xcode-select --install`). Full Xcode is not needed.

## Build and install

```bash
git clone https://github.com/PequenokElder/marmelade.git
cd marmelade
./scripts/install.sh
```

That builds the app, ad-hoc signs it, and copies it to `/Applications/Marmalade.app`. To build without installing, run `./scripts/build_app.sh`; the app is written to `build/Marmalade.app`.

## Where things are stored

- LUTs: `~/Library/Application Support/Marmalade/LUTs`
- Slices: `~/Library/Application Support/Marmalade/Slices.json`

## Notes

- Strong grades on 8-bit JPEGs can show banding in smooth gradients; the dither option helps.
- LUTs designed for log footage (S-Log, V-Log and similar) will look wrong on flat JPEGs. Display-referred "look" LUTs work best.
- Only 3D `.cube` LUTs are supported.
- Tempo detection is best-effort: it's accurate on steady, percussive music and can land on half- or double-time, so the Montage window has Tap, ½× and 2× to correct it by ear.

## License

[MIT](LICENSE)

# silverside.app

The website for Silverside: static HTML and CSS, no build step. One small script, `js/site.js`, closes the menu on phones, runs the theme button, and opens a screenshot full size over the page; without it, the page follows the system appearance and a screenshot's link opens the image itself. GitHub Pages serves this folder as https://silverside.app.

## Preview

```sh
make site      # serves this folder at http://localhost:8000
```

Switch macOS between Light and Dark (System Settings › Appearance) to see both themes; the screenshots swap with the appearance.

## Files

- `index.html`: the home page. `screenshots.html`: the screenshots. `privacy.html` and `license.html`: the privacy and license pages.
- `js/site.js`: the phone menu, the theme button, and the full-size screenshots.
- `css/tokens.css`: the design tokens as CSS custom properties, from the Silverside design system. Dark is the base; light follows `prefers-color-scheme` (or `data-theme="light"` on `<html>`).
- `css/site.css`: the design system's components (`ss-` classes) and the page layout. Every color, radius, and font comes from a token.
- `images/`: the app icon and the screenshots, each in dark and light, at two widths for `srcset`.
- `tools/shot.swift`: crops a window screenshot to the window's edge and writes the WebP images the pages use (see below). `tools/og-image.swift`: makes the link preview picture (`og:image`) from the hero screenshot.
- `CNAME`: the custom domain. `.nojekyll`: Pages serves the files as they are.

## Publishing

`.github/workflows/pages.yml` uploads this folder to Pages on every push to `main` that touches it. Setup, once:

1. Settings › Pages › Build and deployment › Source: **GitHub Actions**.
2. Settings › Pages › Custom domain: `silverside.app`, then Enforce HTTPS once the certificate is issued.
3. At the DNS provider: `A` records for the apex at GitHub Pages' addresses (185.199.108.153, 185.199.109.153, 185.199.110.153, 185.199.111.153), and their `AAAA` records; optionally `www` as a `CNAME` to `silvercodestudio.github.io`. GitHub's "Managing a custom domain" page has the current list.

## Screenshots

Capture the window with Shift-Command-4, drawing a box a little larger than the window. The tool finds the window's edge inside the capture, crops to it, and writes a 2400-wide and a 1200-wide WebP (JPEG without `cwebp`):

```sh
swift docs/site/tools/shot.swift ~/Desktop/capture.png docs/site/images/report-dark --radius 36
```

`--radius 36` makes the corners past the window's round ones transparent, so the page's shadow follows the window. For a window in front of another (the welcome, Settings, About), `--rect X,Y,W,H` crops that rectangle, in the capture's pixels, and `--widths 1200,600` writes smaller sizes. Make each capture in both appearances, name them `-dark` and `-light`, and write alt text that says what the screenshot shows. Each screenshot is a link (`a.zoom`) to its largest image, with `data-light` for the light one.

The link preview (`og:image`) is `images/og-image.jpg`, made from the dark hero: run `swift docs/site/tools/og-image.swift docs/site/images/ripping-dark-2400.webp docs/site/images/og-image.jpg` after the hero changes.

# silverside.app

The website for Silverside: static HTML and CSS, no build step, no JavaScript. GitHub Pages serves this folder as https://silverside.app.

## Preview

```sh
make site      # serves this folder at http://localhost:8000
```

Switch macOS between Light and Dark (System Settings › Appearance) to see both themes; the screenshots swap with the appearance.

## Files

- `index.html`: the home page. `privacy.html`: the privacy page.
- `css/tokens.css`: the design tokens as CSS custom properties, from the Silverside design system. Dark is the base; light follows `prefers-color-scheme` (or `data-theme="light"` on `<html>`).
- `css/site.css`: the design system's components (`ss-` classes) and the page layout. Every color, radius, and font comes from a token.
- `images/`: the app icon and the screenshots, each in dark and light, at two widths for `srcset`.
- `tools/shot.swift`: crops a window screenshot to the window's edge and writes the JPEGs the pages use (see below).
- `CNAME`: the custom domain. `.nojekyll`: Pages serves the files as they are.

## Publishing

`.github/workflows/pages.yml` uploads this folder to Pages on every push to `main` that touches it. Setup, once:

1. Settings › Pages › Build and deployment › Source: **GitHub Actions**.
2. Settings › Pages › Custom domain: `silverside.app`, then Enforce HTTPS once the certificate is issued.
3. At the DNS provider: `A` records for the apex at GitHub Pages' addresses (185.199.108.153, 185.199.109.153, 185.199.110.153, 185.199.111.153), and their `AAAA` records; optionally `www` as a `CNAME` to `silverside-app.github.io`. GitHub's "Managing a custom domain" page has the current list.

## Screenshots

Capture the window with Shift-Command-4, then Space, then click the window (hold Option to leave out the shadow). The tool finds the window's edge inside the capture, crops to it, and writes a 2400-wide and a 1200-wide JPEG:

```sh
swift docs/site/tools/shot.swift ~/Desktop/capture.png docs/site/images/rip-report-dark
```

Make each capture in both appearances, name them `-dark` and `-light`, and write alt text that says what the screenshot shows.

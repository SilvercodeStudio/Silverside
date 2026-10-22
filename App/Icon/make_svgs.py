#!/usr/bin/env python3
"""Converts a Claude Design HTML export to SVG, and if you ask, to Icon Composer layers.

An HTML export is nested div and span elements, each with its full computed style inline.
This script does the layout again from those styles (absolute positions, padding, simple
flex rows, transforms) and draws each box as SVG.

    make_svgs.py design.html -o design.svg
    make_svgs.py design.html -o design.svg --icon-layers AppIcon.icon

SVG has no conic gradient, so a conic gradient becomes many thin wedges. No SVG filters
are used (CoreSVG, which Xcode and Icon Composer use, may not draw them): a glow is a
radial gradient, and a drop shadow of a plain dark color is left out. Each property that
cannot be converted gives a warning on stderr; the rest of the design is still drawn.

Supported: background colors and images (linear-, radial-, repeating-radial-, and
conic-gradient, several layers), border-radius, solid borders (sides of different colors
on an ellipse become arcs), box-shadow (rings, offset inset crescents, glows), opacity,
overflow: hidden, clip-path: polygon(), and transform: matrix().

--icon-layers DIR finds the clipped tile (the first element with overflow: hidden and
rounded corners), scales it to 1024 x 1024, and writes each of its children as a layer
SVG, back to front (layer-01-..., layer-02-...). The tile's background becomes the icon's
fill. The frame around the tile, a gloss overlay over the whole tile, and drop shadows are
left out: the system draws those. All layers go into one group; group them in Icon
Composer. A DIR named *.icon gets the layers in DIR/Assets and a DIR/icon.json.
"""

import argparse
import html.parser
import json
import math
import os
import re
import sys

WARNINGS = []
NOTES = []


def warn(msg):
    if msg not in WARNINGS:
        WARNINGS.append(msg)


def f(x):
    return f"{x:.3f}".rstrip("0").rstrip(".") or "0"


# ---------------------------------------------------------------- parsing


class Node:
    def __init__(self, tag, style, parent):
        self.tag, self.style, self.parent = tag, style, parent
        self.children = []
        self.text = ""
        self.box = (0.0, 0.0, 0.0, 0.0)  # x, y, width, height in the parent's coordinates
        self.hole = None  # for a conic gradient: the part an element on top covers

    def get(self, name, default=""):
        return self.style.get(name, default)

    def path(self):
        names, n = [], self
        while n:
            index = n.parent.children.index(n) + 1 if n.parent else 1
            names.append(f"{n.tag}[{index}]")
            n = n.parent
        return "/".join(reversed(names))


class Parser(html.parser.HTMLParser):
    SKIP = {"html", "head", "body", "meta", "title", "style", "script", "link", "br"}
    VOID = {"img", "input", "hr", "svg"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root, self.stack = None, []

    def handle_starttag(self, tag, attrs):
        if tag in self.SKIP:
            return
        if tag in self.VOID:
            warn(f"<{tag}> is not converted")
            return
        style = {}
        for decl in split_top(dict(attrs).get("style") or "", ";"):
            if ":" in decl:
                key, value = decl.split(":", 1)
                style[key.strip().lower()] = value.strip()
        parent = self.stack[-1] if self.stack else None
        node = Node(tag, style, parent)
        if parent:
            parent.children.append(node)
        elif not self.root:
            self.root = node
        else:
            warn("only the first top-level element is converted")
        self.stack.append(node)

    def handle_endtag(self, tag):
        if tag not in self.SKIP and tag not in self.VOID and self.stack:
            self.stack.pop()

    def handle_data(self, data):
        if data.strip() and self.stack:
            self.stack[-1].text += data.strip()


def split_top(s, sep):
    """Splits at `sep` outside parentheses. A space separator splits at any whitespace."""
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if depth == 0 and (ch == sep or (sep == " " and ch.isspace())):
            if cur.strip():
                out.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


def length(tok, ref=0.0):
    """A CSS length in px; a percentage of `ref`. None for 'auto' and the like."""
    m = re.fullmatch(r"(-?[\d.]+(?:e-?\d+)?)(px|%)?", tok.strip())
    if not m:
        return None
    v = float(m.group(1))
    return v * ref / 100 if m.group(2) == "%" else v


def angle(tok):
    m = re.fullmatch(r"(-?[\d.]+)(deg|turn|rad|grad|%)?", tok.strip())
    if not m:
        return None
    v, unit = float(m.group(1)), m.group(2) or "deg"
    return {"deg": v, "turn": v * 360, "rad": math.degrees(v), "grad": v * 0.9, "%": v * 3.6}[unit]


NAMED = {"transparent": (0, 0, 0, 0), "white": (255, 255, 255, 1), "black": (0, 0, 0, 1)}


def color(tok):
    """(r, g, b, a) with r, g, b in 0-255, or None."""
    tok = tok.strip().lower()
    if tok in NAMED:
        return NAMED[tok]
    m = re.fullmatch(r"#([0-9a-f]{3,8})", tok)
    if m:
        h = m.group(1)
        if len(h) in (3, 4):
            h = "".join(c * 2 for c in h)
        a = int(h[6:8], 16) / 255 if len(h) == 8 else 1
        return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), a)
    m = re.fullmatch(r"rgba?\((.*)\)", tok)
    if m:
        parts = [p for p in re.split(r"[\s,/]+", m.group(1).strip()) if p]
        vals = [float(p.rstrip("%")) * (2.55 if p.endswith("%") else 1) for p in parts[:3]]
        a = 1.0
        if len(parts) > 3:
            a = float(parts[3].rstrip("%")) / (100 if parts[3].endswith("%") else 1)
        return (*vals, a)
    return None


def hexcolor(c):
    return "#%02x%02x%02x" % tuple(max(0, min(255, round(v))) for v in c[:3])


def paint(c, kind="fill"):
    """fill="..." (and fill-opacity) for a color."""
    s = f'{kind}="{hexcolor(c)}"'
    return s + (f' {kind}-opacity="{f(c[3])}"' if c[3] < 1 else "")


def function(s):
    m = re.fullmatch(r"([\w-]+)\((.*)\)", s.strip(), re.S)
    return (m.group(1), split_top(m.group(2), ",")) if m else (None, [])


def gradient_args(args):
    """The configuration (or None) and the color stops of a gradient's arguments."""
    if args and not color(split_top(args[0], " ")[0]):
        return args[0], args[1:]
    return None, args


# ---------------------------------------------------------------- gradients


def parse_stops(args, unit):
    """[(color, position)] with positions resolved by `unit` (a function of one token),
    and missing positions filled in as CSS does."""
    stops = []
    for arg in args:
        toks = split_top(arg, " ")
        cols = [t for t in toks if color(t)]
        if not cols:
            warn(f"color stop not understood: {arg}")
            continue
        poss = [unit(t) for t in toks if not color(t)]
        if not poss:
            stops.append([color(cols[0]), None])
        for p in poss:
            stops.append([color(cols[0]), p])
    if not stops:
        return []
    if stops[0][1] is None:
        stops[0][1] = 0.0
    if stops[-1][1] is None:
        stops[-1][1] = unit("100%")
    last = stops[0][1]
    for s in stops:
        if s[1] is not None:
            s[1] = last = max(s[1], last)
    i = 0
    while i < len(stops):
        if stops[i][1] is None:
            j = i
            while stops[j][1] is None:
                j += 1
            a, b = stops[i - 1][1], stops[j][1]
            for k in range(i, j):
                stops[k][1] = a + (b - a) * (k - i + 1) / (j - i + 1)
            i = j
        i += 1
    return [tuple(s) for s in stops]


def svg_stops(stops):
    """<stop> elements. A transparent stop takes its neighbors' color, as CSS mixes
    premultiplied colors and SVG does not."""
    out = []
    for i, (c, p) in enumerate(stops):
        cols = [c]
        if c[3] == 0:
            near = [stops[j][0] for j in (i - 1, i + 1) if 0 <= j < len(stops) and stops[j][0][3] > 0]
            cols = [(*n[:3], 0) for n in near] or [c]
            if len(cols) == 2 and cols[0] == cols[1]:
                cols = cols[:1]
        for col in cols:
            out.append(f'<stop offset="{f(min(1, max(0, p)))}" stop-color="{hexcolor(col)}"'
                       + (f' stop-opacity="{f(col[3])}"' if col[3] < 1 else "") + "/>")
    return "".join(out)


def color_at(stops, p):
    if p <= stops[0][1]:
        return stops[0][0]
    for (c0, p0), (c1, p1) in zip(stops, stops[1:]):
        if p0 <= p <= p1:
            t = (p - p0) / (p1 - p0) if p1 > p0 else 1
            return tuple(a + (b - a) * t for a, b in zip(c0, c1))
    return stops[-1][0]


def position(toks, w, h):
    """'at x y' of a radial or conic gradient."""
    words = {"left": ("x", 0), "right": ("x", 100), "top": ("y", 0), "bottom": ("y", 100)}
    x, y, free = w / 2, h / 2, []
    for t in toks:
        if t in words:
            axis, pct = words[t]
            if axis == "x":
                x = w * pct / 100
            else:
                y = h * pct / 100
        elif t != "center":
            free.append(t)
    if free:
        x = length(free[0], w)
    if len(free) > 1:
        y = length(free[1], h)
    return x, y


class Defs:
    def __init__(self, prefix):
        self.items, self.prefix, self.count = [], prefix, 0

    def add(self, make):
        self.count += 1
        gid = f"{self.prefix}{self.count}"
        self.items.append(make(gid))
        return gid

    def svg(self):
        return f"<defs>{''.join(self.items)}</defs>" if self.items else ""


def linear_gradient(config, args, w, h, defs):
    a = 180.0
    if config:
        toks = split_top(config, " ")
        if toks[0] == "to":
            sides = toks[1:]
            dx = (1 if "right" in sides else -1 if "left" in sides else 0) * h
            dy = (1 if "bottom" in sides else -1 if "top" in sides else 0) * w
            a = math.degrees(math.atan2(dx, -dy))
        else:
            a = angle(toks[0])
    r = math.radians(a)
    half = (abs(w * math.sin(r)) + abs(h * math.cos(r))) / 2
    dx, dy = math.sin(r) * half, -math.cos(r) * half
    stops = parse_stops(args, lambda t: length(t) / (2 * half) if t.endswith("px") else length(t, 1.0))
    return "url(#%s)" % defs.add(lambda gid: (
        f'<linearGradient id="{gid}" gradientUnits="userSpaceOnUse" x1="{f(w / 2 - dx)}" y1="{f(h / 2 - dy)}" '
        f'x2="{f(w / 2 + dx)}" y2="{f(h / 2 + dy)}">{svg_stops(stops)}</linearGradient>'))


def radial_shape(config, w, h):
    """The center and the x and y radii of a radial gradient's ending shape."""
    toks = split_top(config or "", " ")
    at = toks.index("at") if "at" in toks else len(toks)
    cx, cy = position(toks[at + 1:], w, h)
    words = toks[:at]
    sizes = [t for t in words if length(t) is not None]
    circle = "circle" in words or ("ellipse" not in words and len(sizes) == 1)
    if sizes:
        rx = length(sizes[0], w)
        return cx, cy, rx, rx if circle else length(sizes[-1], h)
    size = next((t for t in words if t.endswith(("-side", "-corner"))), "farthest-corner")
    pick = min if size.startswith("closest") else max
    sx, sy = pick(cx, w - cx), pick(cy, h - cy)
    corner = pick([(abs(cx - ex), abs(cy - ey)) for ex in (0, w) for ey in (0, h)], key=lambda d: math.hypot(*d))
    if circle:
        r = math.hypot(*corner) if size.endswith("corner") else pick(sx, sy)
        return cx, cy, r, r
    if size.endswith("side") or not (sx and sy):
        return cx, cy, sx, sy
    k = math.hypot(corner[0] / sx, corner[1] / sy)  # the ellipse that passes through the corner
    return cx, cy, sx * k, sy * k


def radial_gradient(config, args, w, h, defs):
    cx, cy, rx, ry = radial_shape(config, w, h)
    stops = parse_stops(args, lambda t: length(t) / rx if t.endswith("px") else length(t, 1.0))
    scale = max(1.0, stops[-1][1]) if stops else 1.0  # stops past the ending shape
    stops = [(c, p / scale) for c, p in stops]
    squeeze = f' gradientTransform="translate({f(cx)} {f(cy)}) scale(1 {f(ry / rx)}) translate({f(-cx)} {f(-cy)})"' \
        if abs(rx - ry) > 1e-3 else ""
    return "url(#%s)" % defs.add(lambda gid: (
        f'<radialGradient id="{gid}" gradientUnits="userSpaceOnUse" cx="{f(cx)}" cy="{f(cy)}" r="{f(rx * scale)}"'
        f"{squeeze}>{svg_stops(stops)}</radialGradient>"))


def repeating_radial(config, args, w, h):
    """Rings: each band of one color between two stops becomes a stroked circle, squeezed
    to an ellipse when the gradient is one."""
    cx, cy, rx, ry = radial_shape(config, w, h)
    stops = parse_stops(args, lambda t: length(t, rx))
    period = stops[-1][1] - stops[0][1] if stops else 0
    if period <= 0:
        warn("repeating-radial-gradient with no period")
        return ""
    aspect = ry / rx if rx else 1
    reach = max(math.hypot(ex - cx, (ey - cy) / aspect) for ex in (0, w) for ey in (0, h))
    pairs = list(zip(stops, stops[1:]))
    if any(c0 != c1 and max(c0[3], c1[3]) > 0 and p1 > p0 for (c0, p0), (c1, p1) in pairs):
        warn("repeating-radial-gradient with soft edges: drawn as hard rings")
    rings = []
    for (col, p0), (col1, p1) in pairs:
        if col != col1 or p1 <= p0 or col[3] == 0:
            continue
        circles, k = [], 0
        while p0 + k * period < reach:
            circles.append(f'<circle r="{f((p0 + p1) / 2 + k * period)}"/>')
            k += 1
        rings.append(f'<g fill="none" {paint(col, "stroke")} stroke-width="{f(p1 - p0)}">{"".join(circles)}</g>')
    return f'<g transform="translate({f(cx)} {f(cy)}) scale(1 {f(aspect)})">{"".join(rings)}</g>'


def conic_gradient(config, args, w, h, hole, fine=240):
    """Wedges. Fine wedges fill a ring from `hole` (rx, ry) outward; a fan fills the middle.
    Wedge tips that meet at the center give moire in CoreSVG, so the fan is coarse when an
    element on top covers it, and finer when not."""
    toks = split_top(config or "", " ")
    start = angle(toks[toks.index("from") + 1]) if "from" in toks else 0
    cx, cy = position(toks[toks.index("at") + 1:], w, h) if "at" in toks else (w / 2, h / 2)
    stops = parse_stops(args, angle)
    covered = hole is not None
    if not covered:
        hole = (0.3 * w / 2, 0.3 * h / 2)
    reach = max(math.hypot(ex - cx, ey - cy) for ex in (0, w) for ey in (0, h)) + 1

    def point(p, r):
        a = math.radians(p + start)
        return cx + r * math.sin(a), cy - r * math.cos(a)

    def inner(p):
        a = math.radians(p + start)
        return 1 / math.hypot(math.sin(a) / hole[0], math.cos(a) / hole[1])  # where the ray meets the hole

    out = []
    count = 36 if covered else 120
    step = 360 / count
    for i in range(count):
        p = i * step
        (x0, y0), (x1, y1) = point(p, max(hole) + 1), point(p + step * 1.5, max(hole) + 1)
        out.append(f'<path d="M{f(cx)} {f(cy)}L{f(x0)} {f(y0)}L{f(x1)} {f(y1)}Z" '
                   f'fill="{hexcolor(color_at(stops, p + step / 2))}"/>')
    step = 360 / fine
    for i in range(fine):
        p0, p1 = i * step, i * step + step * 1.5  # overlap hides seams
        (a0, b0), (a1, b1) = point(p0, inner(p0)), point(p0, reach)
        (a2, b2), (a3, b3) = point(p1, reach), point(p1, inner(p1))
        out.append(f'<path d="M{f(a0)} {f(b0)}L{f(a1)} {f(b1)}L{f(a2)} {f(b2)}L{f(a3)} {f(b3)}Z" '
                   f'fill="{hexcolor(color_at(stops, p0 + step / 2))}"/>')
    if any(c[3] < 1 for c, _ in stops):
        warn("conic-gradient with transparent stops: drawn opaque")
    return "".join(out)


# ---------------------------------------------------------------- layout


def four(value):
    """A shorthand of one to four values as top, right, bottom, left."""
    v = split_top(value, " ") or ["0"]
    if len(v) < 3:
        return (v * 4)[:4]
    return v[:4] if len(v) > 3 else [v[0], v[1], v[2], v[1]]


SIDES = ("top", "right", "bottom", "left")


def edges(n, prop):
    v = four(n.get(prop, "0"))
    return [length(n.get(f"{prop}-{s}", v[i])) or 0.0 for i, s in enumerate(SIDES)]


def borders(n):
    styles = four(n.get("border-style", "none"))
    styles = [n.get(f"border-{s}-style", styles[i]) for i, s in enumerate(SIDES)]
    widths = four(n.get("border-width", "0"))
    return [0.0 if styles[i] in ("none", "hidden") else length(n.get(f"border-{s}-width", widths[i])) or 0.0
            for i, s in enumerate(SIDES)]


def size(n):
    w, h = length(n.get("width", "0")) or 0.0, length(n.get("height", "0")) or 0.0
    if n.get("box-sizing", "content-box") != "border-box":
        p, b = edges(n, "padding"), borders(n)
        w += p[1] + p[3] + b[1] + b[3]
        h += p[0] + p[2] + b[0] + b[2]
    return w, h


def offsets(n):
    """top, right, bottom, left of a positioned element (None for auto)."""
    v = four(n.get("inset", "auto"))
    return [length(n.get(s, v[i])) for i, s in enumerate(SIDES)]


def hidden(n):
    return n.get("display") == "none" or n.get("visibility") in ("hidden", "collapse")


def layout(n, x, y, cb):
    """Sets n.box, then lays out the children. `cb` is the containing block for absolute
    elements (x, y, width, height) in the coordinates of n's parent."""
    w, h = size(n)
    n.box = (x, y, w, h)
    b, p = borders(n), edges(n, "padding")
    if n.get("position", "static") != "static":
        child_cb = (b[3], b[0], w - b[1] - b[3], h - b[0] - b[2])
    else:
        child_cb = (cb[0] - x, cb[1] - y, cb[2], cb[3])
        if n.get("transform", "none") != "none" and any(c.get("position") == "absolute" for c in n.children):
            warn(f"absolute children of a transformed, static element may be misplaced: {n.path()}")
    content = (b[3] + p[3], b[0] + p[0], w - b[1] - b[3] - p[1] - p[3], h - b[0] - b[2] - p[0] - p[2])
    flow = []
    for c in n.children:
        if hidden(c):
            continue
        if c.get("position") in ("absolute", "fixed"):
            cw, ch = size(c)
            top, right, bottom, left = offsets(c)
            m = edges(c, "margin")
            cx = child_cb[0] + left + m[3] if left is not None else child_cb[0] + child_cb[2] - (right or 0) - m[1] - cw
            cy = child_cb[1] + top + m[0] if top is not None else child_cb[1] + child_cb[3] - (bottom or 0) - m[2] - ch
            layout(c, cx, cy, child_cb)
        else:
            flow.append(c)
    if "flex" in n.get("display", ""):
        flex(n, flow, content, child_cb)
    else:
        cy = content[1]
        for c in flow:
            m = edges(c, "margin")
            if c.tag == "span" and not c.get("display"):
                warn(f"inline element laid out as a block: {c.path()}")
            layout(c, content[0] + m[3], cy + m[0], child_cb)
            cy += m[0] + c.box[3] + m[2]
    for c in flow:
        if c.get("position") == "relative":
            top, _, _, left = offsets(c)
            cx, cy, cw, ch = c.box
            c.box = (cx + (left or 0), cy + (top or 0), cw, ch)


def flex(n, items, content, cb):
    """One line of flex items, at their own sizes (computed styles hold the used sizes)."""
    column = n.get("flex-direction", "row").startswith("column")
    gaps = split_top(n.get("gap", "0"), " ")
    gap = length(n.get("row-gap" if column else "column-gap", gaps[0 if column else -1])) or 0.0
    if n.get("flex-wrap", "nowrap") != "nowrap":
        warn(f"flex-wrap is not supported: {n.path()}")
    cross0, main0, cross_len, main_len = content if column else (content[1], content[0], content[3], content[2])
    sizes = []
    for c in items:
        (cw, ch), m = size(c), edges(c, "margin")
        across, along = (cw + m[1] + m[3], ch + m[0] + m[2]) if column else (ch + m[0] + m[2], cw + m[1] + m[3])
        sizes.append((along, across, m))
    free = main_len - sum(s[0] for s in sizes) - gap * max(0, len(items) - 1)
    justify, count = n.get("justify-content", "normal"), len(items)
    lead, extra = {
        "center": (free / 2, 0), "flex-end": (free, 0), "end": (free, 0), "right": (free, 0),
        "space-between": (0, free / (count - 1) if count > 1 else 0),
        "space-around": (free / count / 2 if count else 0, free / count if count else 0),
        "space-evenly": (free / (count + 1), free / (count + 1)),
    }.get(justify, (0, 0))
    align = n.get("align-items", "normal")
    pos = main0 + lead
    for c, (along, across, m) in zip(items, sizes):
        off = {"center": (cross_len - across) / 2, "flex-end": cross_len - across, "end": cross_len - across}.get(align, 0)
        if column:
            layout(c, cross0 + off + m[3], pos + m[0], cb)
        else:
            layout(c, pos + m[3], cross0 + off + m[0], cb)
        pos += along + gap + extra


# ---------------------------------------------------------------- drawing


def radii(n, w, h):
    """The x and y corner radii, made smaller as CSS does when they do not fit."""
    corners = ("border-top-left-radius", "border-top-right-radius", "border-bottom-right-radius",
               "border-bottom-left-radius")
    values = {n.get(k) for k in corners if k in n.style}
    first = n.get(corners[0]) or split_top(n.get("border-radius", "0").split("/")[0], " ")[0]
    if len(values) > 1 or len(split_top(n.get("border-radius", "0").split("/")[0], " ")) > 1:
        warn(f"corners of different radii: all drawn as the first: {n.path()}")
    parts = split_top(first, " ")
    rx, ry = length(parts[0], w) or 0.0, length(parts[-1], h) or 0.0
    if rx > 0 and ry > 0:
        k = min(1.0, w / (2 * rx), h / (2 * ry))
        rx, ry = rx * k, ry * k
    return rx, ry


def is_ellipse(w, h, rx, ry):
    return w > 0 and h > 0 and abs(rx - w / 2) < 0.01 and abs(ry - h / 2) < 0.01


def shape(x, y, w, h, rx, ry, attrs):
    if is_ellipse(w, h, rx, ry):
        return f'<ellipse cx="{f(x + w / 2)}" cy="{f(y + h / 2)}" rx="{f(rx)}" ry="{f(ry)}" {attrs}/>'
    r = f' rx="{f(rx)}" ry="{f(ry)}"' if rx > 0 and ry > 0 else ""
    return f'<rect x="{f(x)}" y="{f(y)}" width="{f(w)}" height="{f(h)}"{r} {attrs}/>'


def shape_path(x, y, w, h, rx, ry):
    rx, ry = max(0.0, min(rx, w / 2)), max(0.0, min(ry, h / 2))
    if rx == 0 or ry == 0:
        return f"M{f(x)} {f(y)}H{f(x + w)}V{f(y + h)}H{f(x)}Z"
    a = f"A{f(rx)} {f(ry)} 0 0 1 "
    return (f"M{f(x + rx)} {f(y)}H{f(x + w - rx)}{a}{f(x + w)} {f(y + ry)}V{f(y + h - ry)}"
            f"{a}{f(x + w - rx)} {f(y + h)}H{f(x + rx)}{a}{f(x)} {f(y + h - ry)}V{f(y + ry)}{a}{f(x + rx)} {f(y)}Z")


def clip(defs, inner_shape):
    return defs.add(lambda gid: f'<clipPath id="{gid}">{inner_shape}</clipPath>')


def background(n, w, h, rx, ry, defs):
    out = []
    bg = color(n.get("background-color", "transparent"))
    if bg and bg[3] > 0:
        out.append(shape(0, 0, w, h, rx, ry, paint(bg)))
    image = n.get("background-image", "none")
    if image == "none":
        return "".join(out)
    if set(split_top(n.get("background-blend-mode", "normal"), ",")) != {"normal"}:
        warn(f"background-blend-mode is not supported: {n.path()}")
    for prop, ok in (("background-size", ("auto", "auto auto")), ("background-position", ("0% 0%",))):
        if any(v not in ok for v in split_top(n.get(prop, ok[0]), ",")):
            warn(f"{prop} is not supported: {n.path()}")
    b = borders(n)
    pw, ph = w - b[1] - b[3], h - b[0] - b[2]  # gradients fill the padding box
    move = f' transform="translate({f(b[3])} {f(b[0])})"' if b[0] or b[3] else ""
    for layer in reversed(split_top(image, ",")):
        name, args = function(layer)
        config, stops = gradient_args(args)
        if name in ("linear-gradient", "radial-gradient"):
            make = linear_gradient if name == "linear-gradient" else radial_gradient
            fill = make(config, stops, pw, ph, defs)
            out.append(f"<g{move}>" + shape(-b[3], -b[0], w, h, rx, ry, f'fill="{fill}"') + "</g>")
        elif name in ("repeating-radial-gradient", "conic-gradient"):
            cid = clip(defs, shape(0, 0, w, h, rx, ry, ""))
            body = repeating_radial(config, stops, pw, ph) if name.startswith("repeating") \
                else conic_gradient(config, stops, pw, ph, n.hole)
            out.append(f'<g clip-path="url(#{cid})"><g{move}>{body}</g></g>')
        else:
            warn(f"background image not supported: {(name or layer)[:40]}: {n.path()}")
    return "".join(out)


def shadows(n, w, h, rx, ry, defs, inset):
    """The outer or the inset box-shadows; the first one listed is on top."""
    out = []
    for item in reversed(split_top(n.get("box-shadow", "none"), ",")):
        toks = split_top(item, " ")
        if item == "none" or ("inset" in toks) != inset:
            continue
        col = next((color(t) for t in toks if color(t)), (0, 0, 0, 1))
        ox, oy, blur, spread = ([length(t) or 0.0 for t in toks if t != "inset" and not color(t)] + [0.0] * 4)[:4]
        if col[3] == 0:
            continue
        if inset:
            out.append(inset_shadow(n, w, h, rx, ry, defs, col, ox, oy, blur, spread))
        elif blur > 0 and max(col[:3]) < 60 and max(col[:3]) - min(col[:3]) < 40:
            NOTES.append("a dark drop shadow")
        elif blur > 0:
            out.append(glow(w, h, rx, ry, defs, col, ox, oy, blur, spread))
        else:
            e = spread
            out.append(shape(ox - e, oy - e, w + 2 * e, h + 2 * e, rx + e if rx else 0, ry + e if ry else 0, paint(col)))
    return "".join(out)


def glow(w, h, rx, ry, defs, col, ox, oy, blur, spread):
    """A blurred shadow of a light color. An ellipse gets a radial gradient; any other
    shape gets a few larger, faint copies of itself."""
    if is_ellipse(w, h, rx, ry):
        a, b = w / 2 + spread, h / 2 + spread
        outer = a + blur
        stops = [(max(0, (a - blur / 2) / outer), col), (a / outer, (*col[:3], col[3] / 2)), (1, (*col[:3], 0))]
        gid = defs.add(lambda gid: (
            f'<radialGradient id="{gid}" gradientUnits="userSpaceOnUse" cx="0" cy="0" r="1">'
            + "".join(f'<stop offset="{f(o)}" stop-color="{hexcolor(c)}" stop-opacity="{f(c[3])}"/>' for o, c in stops)
            + "</radialGradient>"))
        return (f'<g transform="translate({f(w / 2 + ox)} {f(h / 2 + oy)}) scale({f(outer)} {f(b + blur)})">'
                f'<circle r="1" fill="url(#{gid})"/></g>')
    out = []
    for grow, share in ((0.75, 0.11), (0.5, 0.18), (0.25, 0.25)):
        e = spread + blur * grow
        out.append(shape(ox - e, oy - e, w + 2 * e, h + 2 * e, rx + e, ry + e, paint((*col[:3], col[3] * share))))
    return "".join(out)


def inset_shadow(n, w, h, rx, ry, defs, col, ox, oy, blur, spread):
    """The box less a copy of itself, made smaller by the spread and moved by the offset."""
    if blur > 0:
        warn(f"inset shadow blur drawn as a hard edge: {n.path()}")
        col = (*col[:3], col[3] / 2)
    s = spread
    hole = shape_path(ox + s, oy + s, w - 2 * s, h - 2 * s, max(0, rx - s), max(0, ry - s))
    big = f"M{f(-w)} {f(-h)}H{f(2 * w)}V{f(2 * h)}H{f(-w)}Z"
    cid = clip(defs, shape(0, 0, w, h, rx, ry, ""))
    return f'<g clip-path="url(#{cid})"><path fill-rule="evenodd" d="{big}{hole}" {paint(col)}/></g>'


def border(n, w, h, rx, ry):
    b = borders(n)
    if not any(b):
        return ""
    style = n.get("border-style", "solid")
    if any(s not in ("solid", "none", "hidden") for s in split_top(style, " ")):
        warn(f"border-style {style} drawn as solid: {n.path()}")
    cols = [color(c) or (0, 0, 0, 0) for c in four(n.get("border-color", "transparent"))]
    cols = [color(n.get(f"border-{s}-color", "")) or cols[i] for i, s in enumerate(SIDES)]
    cols = [c if b[i] else (0, 0, 0, 0) for i, c in enumerate(cols)]
    bw = max(b)
    if len(set(x for x in b if x)) > 1:
        warn(f"borders of different widths drawn as the widest: {n.path()}")
    if len(set(cols)) == 1:
        return shape(bw / 2, bw / 2, w - bw, h - bw, max(0, rx - bw / 2), max(0, ry - bw / 2),
                     f'fill="none" {paint(cols[0], "stroke")} stroke-width="{f(bw)}"')
    if is_ellipse(w, h, rx, ry):
        # Each side runs from diagonal to diagonal: the top from 225 to 315 degrees, and so on.
        ax, ay, out = w / 2 - bw / 2, h / 2 - bw / 2, []
        for i, col in enumerate(cols):
            if col[3] == 0:
                continue
            t0, t1 = math.radians(225 + 90 * i), math.radians(315 + 90 * i)
            x0, y0 = w / 2 + ax * math.cos(t0), h / 2 + ay * math.sin(t0)
            x1, y1 = w / 2 + ax * math.cos(t1), h / 2 + ay * math.sin(t1)
            out.append(f'<path d="M{f(x0)} {f(y0)}A{f(ax)} {f(ay)} 0 0 1 {f(x1)} {f(y1)}" fill="none" '
                       f'{paint(col, "stroke")} stroke-width="{f(bw)}"/>')
        return "".join(out)
    if rx or ry:
        warn(f"rounded border with sides of different colors drawn square: {n.path()}")
    quads = [(0, 0, w, 0, w - bw, bw, bw, bw), (w, 0, w, h, w - bw, h - bw, w - bw, bw),
             (w, h, 0, h, bw, h - bw, w - bw, h - bw), (0, h, 0, 0, bw, bw, bw, h - bw)]
    return "".join(f'<path d="M{f(q[0])} {f(q[1])}L{f(q[2])} {f(q[3])}L{f(q[4])} {f(q[5])}L{f(q[6])} {f(q[7])}Z" '
                   f"{paint(c)}/>" for q, c in zip(quads, cols) if c[3] > 0)


def matrix(n):
    t = n.get("transform", "none")
    if t == "none":
        return None
    name, args = function(t)
    vals = [float(a) for a in args]
    if name == "matrix" and len(vals) == 6:
        return vals
    if name == "matrix3d" and len(vals) == 16:
        warn(f"3D transform flattened: {n.path()}")
        return [vals[0], vals[1], vals[4], vals[5], vals[12], vals[13]]
    warn(f"transform not supported: {t}: {n.path()}")
    return None


def check(n):
    for prop, ok in (("filter", "none"), ("backdrop-filter", "none"), ("mask-image", "none"),
                     ("mix-blend-mode", "normal"), ("rotate", "none"), ("scale", "none"),
                     ("translate", "none"), ("border-image-source", "none")):
        if n.get(prop, ok) != ok:
            warn(f"{prop} is not supported: {n.get(prop)[:40]}: {n.path()}")
    if n.text:
        warn(f"text is not converted: {n.text[:30]!r}")


def emit(n, defs):
    """One element and its children, as a <g> in its parent's coordinates."""
    check(n)
    x, y, w, h = n.box
    rx, ry = radii(n, w, h)
    move = f"translate({f(x)} {f(y)})"
    m = matrix(n)
    if m:
        org = split_top(n.get("transform-origin", "50% 50%"), " ")
        ox, oy = length(org[0], w), length(org[1] if len(org) > 1 else "50%", h)
        move += f" translate({f(ox)} {f(oy)}) matrix({' '.join(f(v) for v in m)}) translate({f(-ox)} {f(-oy)})"
    body = (shadows(n, w, h, rx, ry, defs, False) + background(n, w, h, rx, ry, defs) +
            shadows(n, w, h, rx, ry, defs, True) + border(n, w, h, rx, ry))
    kids = children(n, defs)
    if kids and n.get("overflow", "visible") != "visible":
        b = borders(n)
        cid = clip(defs, shape(b[3], b[0], w - b[1] - b[3], h - b[0] - b[2], max(0, rx - b[3]), max(0, ry - b[0]), ""))
        kids = f'<g clip-path="url(#{cid})">{kids}</g>'
    body += kids
    cp = n.get("clip-path", "none")
    if cp != "none":
        name, args = function(cp)
        if name == "polygon":
            pts = [split_top(a, " ") for a in args if a not in ("nonzero", "evenodd")]
            d = "M" + "L".join(f"{f(length(p[0], w))} {f(length(p[1], h))}" for p in pts) + "Z"
            cid = clip(defs, f'<path d="{d}"/>')
            body = f'<g clip-path="url(#{cid})">{body}</g>'
        else:
            warn(f"clip-path not supported: {cp[:40]}: {n.path()}")
    opacity = float(n.get("opacity", "1"))
    op = f' opacity="{f(opacity)}"' if opacity < 1 else ""
    move = f' transform="{move}"' if move != "translate(0 0)" else ""
    return f"<g{move}{op}>{body}</g>"


def z_key(n):
    """CSS paint order: negative z-index, then the flow, then positioned, then positive."""
    z = n.get("z-index", "auto")
    positioned = n.get("position", "static") != "static"
    if positioned and z not in ("auto", "0"):
        return (0, int(z)) if int(z) < 0 else (3, int(z))
    return (2, 0) if positioned else (1, 0)


def children(n, defs):
    kids = [c for c in n.children if not hidden(c)]
    for i, c in enumerate(kids):
        if "conic-gradient" in c.get("background-image", ""):
            c.hole = cover(c, kids[i + 1:])
    return "".join(emit(c, defs) for c in sorted(kids, key=z_key))


def cover(c, later):
    """The largest centered ellipse that a later element paints over a conic gradient,
    made a little smaller: the fine wedges need not go under it. None if there is none."""
    if matrix(c):
        return None
    x, y, w, h = c.box
    best = None
    for s in later:
        sx, sy, sw, sh = s.box
        bg = color(s.get("background-color", "transparent")) or (0, 0, 0, 0)
        filled = bg[3] >= 0.5 or s.get("background-image", "none") != "none"
        centered = abs(sx + sw / 2 - x - w / 2) < 1 and abs(sy + sh / 2 - y - h / 2) < 1
        if filled and centered and is_ellipse(sw, sh, *radii(s, sw, sh)) and sw < w and sh < h and not matrix(s):
            if not best or 0.9 * sw / 2 > best[0]:
                best = (0.9 * sw / 2, 0.9 * sh / 2)
    return best


# ---------------------------------------------------------------- output


def read(path):
    p = Parser()
    with open(path, encoding="utf-8") as fh:
        p.feed(fh.read())
    if not p.root:
        sys.exit(f"{path}: no element found")
    w, h = size(p.root)
    layout(p.root, 0, 0, (0, 0, w, h))
    return p.root


def svg(width, height, content, defs):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{f(width)}" height="{f(height)}" '
            f'viewBox="0 0 {f(width)} {f(height)}">{defs.svg()}{content}</svg>\n')


def tile_of(root):
    todo = [root]
    while todo:
        n = todo.pop(0)
        if n.get("overflow", "visible") == "hidden" and any(radii(n, n.box[2], n.box[3])):
            return n
        todo.extend(n.children)
    return None


def hint(n):
    image = n.get("background-image", "none")
    bg = color(n.get("background-color", "transparent")) or (0, 0, 0, 0)
    if "conic-gradient" in image:
        return "conic"
    if n.children:
        return "group"
    if any(borders(n)) and image == "none" and bg[3] == 0:
        return "border"
    _, _, w, h = n.box
    return "ellipse" if is_ellipse(w, h, *radii(n, w, h)) else "box"


def is_gloss(n, tile):
    """A plain, faint overlay over the whole tile: the system draws its own highlights."""
    _, _, w, h = n.box
    _, _, tw, th = tile.box
    if n.children or w < 0.95 * tw or h < 0.95 * th or "conic" in n.get("background-image", ""):
        return False
    text = n.get("background-image", "") + " " + n.get("background-color", "transparent")
    alphas = [c[3] for c in map(color, re.findall(r"rgba?\([^)]*\)|#[0-9a-fA-F]{3,8}", text)) if c]
    return bool(alphas) and max(alphas) <= 0.3


def ic_color(c):
    return "extended-srgb:%s,%.5f" % (",".join(f"{v / 255:.5f}" for v in c[:3]), c[3])


def fill_of(tile):
    """The tile's background as an Icon Composer fill, top to bottom."""
    layers = split_top(tile.get("background-image", "none"), ",")
    name, args = function(layers[-1]) if layers != ["none"] else (None, [])
    if name in ("linear-gradient", "radial-gradient"):
        config, stops = gradient_args(args)
        stops = parse_stops(stops, lambda t: length(t, 1.0) or 0.0)
        if name == "radial-gradient":
            NOTES.append("the tile's radial gradient, as a linear fill from its center color to its edge color")
        elif config and config.strip() not in ("180deg", "to bottom"):
            warn(f"the fill runs top to bottom, not {config}")
        return {"linear-gradient": [ic_color(stops[0][0]), ic_color(stops[-1][0])]}
    bg = color(tile.get("background-color", "transparent"))
    return {"solid": ic_color(bg)} if bg and bg[3] > 0 else "automatic"


def icon_layers(root, out_dir, force):
    tile = tile_of(root)
    if not tile:
        sys.exit("no tile found: no element with overflow: hidden and rounded corners")
    bundle = out_dir.rstrip("/").endswith(".icon")
    if bundle and os.path.exists(out_dir) and not force:
        sys.exit(f"{out_dir} exists; use --force to replace its layers and icon.json")
    assets = os.path.join(out_dir, "Assets") if bundle else out_dir
    os.makedirs(assets, exist_ok=True)
    for old in os.listdir(assets):
        if re.fullmatch(r"layer-\d\d-.*\.svg", old):
            os.remove(os.path.join(assets, old))
    _, _, tw, th = tile.box
    k = 1024 / max(tw, th)
    move = f"translate({f((1024 - tw * k) / 2)} {f((1024 - th * k) / 2)}) scale({f(k)})"
    names = []
    kids = [c for c in tile.children if not hidden(c)]
    for i, c in enumerate(kids):
        if "conic-gradient" in c.get("background-image", ""):
            c.hole = cover(c, kids[i + 1:])
    for c in sorted(kids, key=z_key):
        if is_gloss(c, tile):
            NOTES.append("a gloss overlay")
            continue
        defs = Defs("d")
        body = emit(c, defs)
        name = f"layer-{len(names) + 1:02d}-{hint(c)}"
        with open(os.path.join(assets, name + ".svg"), "w") as fh:
            fh.write(svg(1024, 1024, f'<g transform="{move}">{body}</g>', defs))
        names.append(name)
    doc = {
        # "fill-specializations", not "fill": a plain fill hides a dark one added later.
        "fill-specializations": [{"value": fill_of(tile)}],
        "groups": [{
            "name": "Layers",
            "layers": [{"glass": False, "image-name": n + ".svg", "name": n} for n in reversed(names)],
            "shadow": {"kind": "neutral", "opacity": 0.5},
            "specular": True,
            "translucency": {"enabled": False, "value": 0.5},
        }],
        "supported-platforms": {"squares": ["macOS"]},
    }
    with open(os.path.join(out_dir, "icon.json"), "w") as fh:
        json.dump(doc, fh, indent=2)
        fh.write("\n")
    print(f"wrote {len(names)} layers and icon.json to {out_dir}", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser(
        description="Convert a Claude Design HTML export to SVG, and optionally to Icon Composer layers.",
        epilog="--icon-layers puts every layer in one group; group them in Icon Composer. "
               "The frame, a gloss overlay, and drop shadows are left out, as the system draws them.")
    ap.add_argument("input", help="the HTML export")
    ap.add_argument("-o", "--output", help="the SVG to write (default: the input's name with .svg)")
    ap.add_argument("--icon-layers", metavar="DIR",
                    help="also write the tile's children as 1024 x 1024 layer SVGs and an icon.json in DIR "
                         "(a DIR named *.icon gets them in DIR/Assets)")
    ap.add_argument("--force", action="store_true", help="replace the layers of an existing .icon")
    opts = ap.parse_args()

    root = read(opts.input)
    out = opts.output or os.path.splitext(opts.input)[0] + ".svg"
    defs = Defs("g")
    body = emit(root, defs)
    with open(out, "w") as fh:
        fh.write(svg(root.box[2], root.box[3], body, defs))
    print(f"wrote {out}", file=sys.stderr)
    if opts.icon_layers:
        icon_layers(root, opts.icon_layers, opts.force)
    for msg in WARNINGS:
        print(f"warning: {msg}", file=sys.stderr)
    for note in sorted(set(NOTES)):
        print(f"left out: {note} ({NOTES.count(note)})", file=sys.stderr)


if __name__ == "__main__":
    main()

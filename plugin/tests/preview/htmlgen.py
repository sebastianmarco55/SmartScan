"""Roblox GUI dump (the JSON written by gui.luau) -> one HTML page that lays the GUI out like Roblox does.

UDim2 -> calc(), AnchorPoint -> translate, UIListLayout -> flexbox, UIGridLayout -> grid, UIPadding -> padding (or an inset
layer for absolutely placed children), AutomaticSize -> auto + min size, UICorner / UIStroke -> border-radius / outline,
ScrollingFrame -> clipped canvas with a scroll bar, RichText -> HTML. page.js does what CSS cannot (auto-sized frames that
only have absolutely placed children, canvas sizes, text scaling, sprites) and measures every element so the next Luau pass
can answer AbsoluteSize / AbsoluteContentSize / AbsolutePosition like Roblox.
"""
import html
import json
import math
import os
import re
from collections import namedtuple

HERE = os.path.dirname(os.path.abspath(__file__))

C3 = namedtuple("C3", "r g b")
UD2 = namedtuple("UD2", "xs xo ys yo")
UD = namedtuple("UD", "s o")
V2 = namedtuple("V2", "x y")
RectV = namedtuple("RectV", "x0 y0 x1 y1")
En = namedtuple("En", "enum name")
Fnt = namedtuple("Fnt", "family weight style")
CSeq = namedtuple("CSeq", "pts")
NSeq = namedtuple("NSeq", "pts")


def decode(v):
    if isinstance(v, dict) and "$" in v:
        t = v["$"]
        if t == "C3":
            return C3(*v["v"])
        if t == "UD2":
            return UD2(*v["v"])
        if t == "UD":
            return UD(*v["v"])
        if t == "V2":  # math.huge is dumped as null
            return V2(*[math.inf if x is None else x for x in v["v"]])
        if t == "R":
            return RectV(*v["v"])
        if t == "E":
            return En(v["e"], v["n"])
        if t == "F":
            return Fnt(v["f"], v["w"], v["s"])
        if t == "CS":
            return CSeq(v["v"])
        if t == "NS":
            return NSeq(v["v"])
        if t == "NR":
            return tuple(v["v"])
    return v


GUI_OBJECTS = {"Frame", "TextLabel", "TextButton", "TextBox", "ImageLabel", "ImageButton", "ScrollingFrame", "CanvasGroup",
               "ViewportFrame", "VideoFrame"}
TEXT_CLASSES = {"TextLabel", "TextButton", "TextBox"}
IMAGE_CLASSES = {"ImageLabel", "ImageButton"}

# Roblox defaults of the properties the renderer reads (the Luau mock only dumps what the plugin set)
BASE_DEFAULTS = {
    "Position": UD2(0, 0, 0, 0), "Size": UD2(0, 0, 0, 0), "AnchorPoint": V2(0, 0), "Visible": True, "ZIndex": 1,
    "LayoutOrder": 0, "Rotation": 0, "BackgroundColor3": C3(163 / 255, 162 / 255, 165 / 255), "BackgroundTransparency": 0,
    "BorderColor3": C3(27 / 255, 42 / 255, 53 / 255), "BorderSizePixel": 1, "BorderMode": En("BorderMode", "Outline"),
    "ClipsDescendants": False, "AutomaticSize": En("AutomaticSize", "None"),
}
TEXT_DEFAULTS = {
    "Text": "", "TextSize": 14, "TextColor3": C3(27 / 255, 27 / 255, 27 / 255), "TextTransparency": 0,
    "Font": En("Font", "SourceSans"), "TextXAlignment": En("TextXAlignment", "Center"),
    "TextYAlignment": En("TextYAlignment", "Center"), "TextWrapped": False, "RichText": False, "TextScaled": False,
    "LineHeight": 1, "TextTruncate": En("TextTruncate", "None"), "TextStrokeTransparency": 1,
    "TextStrokeColor3": C3(0, 0, 0), "PlaceholderText": "", "PlaceholderColor3": C3(178 / 255, 178 / 255, 178 / 255),
    "MultiLine": False,
}
IMAGE_DEFAULTS = {
    "Image": "", "ImageColor3": C3(1, 1, 1), "ImageTransparency": 0, "ScaleType": En("ScaleType", "Stretch"),
    "ImageRectOffset": V2(0, 0), "ImageRectSize": V2(0, 0),
}
SCROLL_DEFAULTS = {
    "CanvasSize": UD2(0, 0, 2, 0), "CanvasPosition": V2(0, 0), "ScrollBarThickness": 12,
    "AutomaticCanvasSize": En("AutomaticSize", "None"), "ScrollingDirection": En("ScrollingDirection", "XY"),
    "ScrollBarImageColor3": C3(0, 0, 0), "ScrollBarImageTransparency": 0,
    "VerticalScrollBarInset": En("ScrollBarInset", "None"), "HorizontalScrollBarInset": En("ScrollBarInset", "None"),
}


class Node:
    __slots__ = ("id", "cls", "name", "p", "kids", "parent", "mods")

    def __init__(self, raw, parent=None):
        self.id = raw["id"]
        self.cls = raw["c"]
        self.name = raw["n"]
        self.p = {k: decode(v) for k, v in raw["p"].items()}
        self.parent = parent
        self.kids = [Node(k, self) for k in raw["k"]]
        self.mods = {}
        for k in self.kids:
            if k.cls.startswith("UI"):
                self.mods.setdefault(k.cls, []).append(k)

    def get(self, key):
        if key in self.p:
            return self.p[key]
        if key in BASE_DEFAULTS and self.cls in GUI_OBJECTS:
            return BASE_DEFAULTS[key]
        if self.cls in TEXT_CLASSES and key in TEXT_DEFAULTS:
            if key == "Text" and self.cls == "TextLabel":
                return "Label"
            if key == "Text" and self.cls == "TextButton":
                return "Button"
            return TEXT_DEFAULTS[key]
        if self.cls in IMAGE_CLASSES and key in IMAGE_DEFAULTS:
            return IMAGE_DEFAULTS[key]
        if self.cls == "ScrollingFrame" and key in SCROLL_DEFAULTS:
            return SCROLL_DEFAULTS[key]
        return UIDEFAULTS.get(self.cls, {}).get(key)

    def en(self, key):
        v = self.get(key)
        return v.name if isinstance(v, En) else None

    def mod(self, cls):
        lst = self.mods.get(cls)
        return lst[0] if lst else None


UIDEFAULTS = {
    "UICorner": {"CornerRadius": UD(0, 8)},
    "UIStroke": {"Color": C3(0, 0, 0), "Thickness": 1, "Transparency": 0, "Enabled": True,
                 "ApplyStrokeMode": En("ApplyStrokeMode", "Contextual")},
    "UIPadding": {"PaddingTop": UD(0, 0), "PaddingRight": UD(0, 0), "PaddingBottom": UD(0, 0), "PaddingLeft": UD(0, 0)},
    "UIListLayout": {"FillDirection": En("FillDirection", "Vertical"), "Padding": UD(0, 0),
                     "HorizontalAlignment": En("HorizontalAlignment", "Left"),
                     "VerticalAlignment": En("VerticalAlignment", "Top"), "SortOrder": En("SortOrder", "LayoutOrder"),
                     "HorizontalFlex": En("UIFlexAlignment", "None"), "VerticalFlex": En("UIFlexAlignment", "None"),
                     "Wraps": False},
    "UIGridLayout": {"FillDirection": En("FillDirection", "Horizontal"), "CellSize": UD2(0, 100, 0, 100),
                     "CellPadding": UD2(0, 5, 0, 5), "HorizontalAlignment": En("HorizontalAlignment", "Left"),
                     "VerticalAlignment": En("VerticalAlignment", "Top"), "SortOrder": En("SortOrder", "LayoutOrder")},
    "UIFlexItem": {"FlexMode": En("UIFlexMode", "None"), "GrowRatio": 0, "ShrinkRatio": 0},
    "UIGradient": {"Rotation": 0, "Enabled": True},
    "UISizeConstraint": {},
    "UIAspectRatioConstraint": {"AspectRatio": 1, "DominantAxis": En("DominantAxis", "Width")},
}


# ---------------------------------------------------------------------------------------------------------------------
# small CSS helpers
# ---------------------------------------------------------------------------------------------------------------------
def fnum(x):
    if x is None:
        return "0"
    s = ("%.4f" % x).rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def length(scale, offset):
    """UDim -> CSS length: scale is a share of the containing block (the parent's content area)."""
    if scale == 0:
        return fnum(offset) + "px"
    pct = fnum(scale * 100) + "%"
    if offset == 0:
        return pct
    if offset < 0:
        return "calc(%s - %spx)" % (pct, fnum(-offset))
    return "calc(%s + %spx)" % (pct, fnum(offset))


def rgba(c, transparency=0.0):
    a = max(0.0, min(1.0, 1.0 - (transparency or 0.0)))

    def b(x):
        return max(0, min(255, int(round(x * 255))))
    if a >= 0.999:
        return "rgb(%d,%d,%d)" % (b(c.r), b(c.g), b(c.b))
    return "rgba(%d,%d,%d,%s)" % (b(c.r), b(c.g), b(c.b), fnum(a))


def is_white(c):
    return c.r > 0.995 and c.g > 0.995 and c.b > 0.995


def esc(text):
    return html.escape(text, quote=True)


# ---------------------------------------------------------------------------------------------------------------------
# fonts
# ---------------------------------------------------------------------------------------------------------------------
# legacy Enum.Font -> (family key, weight)
LEGACY_FONTS = {
    "BuilderSans": ("BuilderSans", 400), "BuilderSansMedium": ("BuilderSans", 500), "BuilderSansBold": ("BuilderSans", 700),
    "BuilderSansExtraBold": ("BuilderSans", 800), "SourceSans": ("SourceSansPro", 400), "SourceSansBold": ("SourceSansPro", 700),
    "SourceSansLight": ("SourceSansPro", 300), "SourceSansSemibold": ("SourceSansPro", 600),
    "SourceSansItalic": ("SourceSansPro", 400), "Gotham": ("GothamSSm", 400), "GothamMedium": ("GothamSSm", 500),
    "GothamBold": ("GothamSSm", 700), "GothamBlack": ("GothamSSm", 900), "Arial": ("Arimo", 400), "ArialBold": ("Arimo", 700),
    "Arimo": ("Arimo", 400), "ArimoBold": ("Arimo", 700), "Code": ("RobotoMono", 400), "RobotoMono": ("RobotoMono", 400),
    "Roboto": ("Roboto", 400), "Legacy": ("SourceSansPro", 400), "Unknown": ("BuilderSans", 400),
}
# natural line height of the family / em: Roblox draws a line of text TextSize px tall, so the em is TextSize / this
NATURAL = {"BuilderSans": 1.26, "BuilderExtended": 1.26, "BuilderMono": 1.3, "SourceSansPro": 1.257, "GothamSSm": 1.25,
           "Arimo": 1.15, "RobotoMono": 1.32, "Roboto": 1.17}
CSS_FAMILY = {
    "BuilderSans": "'LC Sans'", "BuilderExtended": "'LC Sans'", "SourceSansPro": "'LC Sans'", "GothamSSm": "'LC Sans'",
    "BuilderMono": "'LC Mono'", "RobotoMono": "'LC Mono'", "Arimo": "'LC Sans'", "Roboto": "'LC Sans'",
}


FONT_DIVISOR = None  # --font-scale: the em of a font is TextSize / this (None: NATURAL of the family)


def natural_of(key):
    return FONT_DIVISOR or NATURAL.get(key, 1.26)


def font_of(n):
    """(css family, weight, italic, natural line-height ratio)"""
    ff = n.p.get("FontFace")
    if isinstance(ff, Fnt):
        m = re.search(r"families/([A-Za-z0-9_]+)\.json", ff.family)
        key = m.group(1) if m else "BuilderSans"
        if key == "SourceSansPro":
            key = "SourceSansPro"
        return CSS_FAMILY.get(key, "'LC Sans'"), ff.weight, ff.style == "Italic", natural_of(key)
    e = n.en("Font") or "SourceSans"
    key, weight = LEGACY_FONTS.get(e, ("BuilderSans", 400))
    return CSS_FAMILY.get(key, "'LC Sans'"), weight, e == "SourceSansItalic", natural_of(key)


# ---------------------------------------------------------------------------------------------------------------------
# Roblox rich text -> HTML
# ---------------------------------------------------------------------------------------------------------------------
TAG_RE = re.compile(r"<(/?)([A-Za-z]+)((?:\s+[A-Za-z]+\s*=\s*(?:\"[^\"]*\"|'[^']*'))*)\s*(/?)>")
ATTR_RE = re.compile(r"([A-Za-z]+)\s*=\s*(?:\"([^\"]*)\"|'([^']*)')")
ENTITY = {"&lt;": "<", "&gt;": ">", "&quot;": '"', "&apos;": "'", "&amp;": "&"}


def rich_to_html(text, size_px, base_family=None):
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)  # comments
    out = []
    stack = []  # open tags
    pos = 0
    known = {"b", "i", "u", "s", "font", "stroke", "uppercase", "uc", "smallcaps", "sc", "mark", "br"}

    def literal(chunk):
        # &lt; &gt; &quot; &apos; &amp; are the only entities Roblox knows
        parts = re.split(r"(&lt;|&gt;|&quot;|&apos;|&amp;)", chunk)
        return "".join(esc(ENTITY.get(p, p)) for p in parts)

    for m in TAG_RE.finditer(text):
        tag = m.group(2).lower()
        if tag not in known:
            continue
        out.append(literal(text[pos:m.start()]))
        pos = m.end()
        closing, attrs, selfclose = m.group(1), m.group(3), m.group(4)
        if tag == "br":
            out.append("\n")
            continue
        if closing:
            for i in range(len(stack) - 1, -1, -1):
                if stack[i] == tag:
                    out.append("</span>" * (len(stack) - i))
                    del stack[i:]
                    break
            continue
        style = []
        a = {k.lower(): (v1 or v2) for k, v1, v2 in ATTR_RE.findall(attrs)}
        if tag == "b":
            style.append("font-weight:700")
        elif tag == "i":
            style.append("font-style:italic")
        elif tag == "u":
            style.append("text-decoration:underline")
        elif tag == "s":
            style.append("text-decoration:line-through")
        elif tag in ("uppercase", "uc"):
            style.append("text-transform:uppercase")
        elif tag in ("smallcaps", "sc"):
            style.append("font-variant:small-caps")
        elif tag == "mark":
            col = a.get("color", "#ffff00")
            style.append("background:%s" % css_color_attr(col, a.get("transparency")))
        elif tag == "stroke":
            style.append("-webkit-text-stroke:%spx %s" % (a.get("thickness", "1"), css_color_attr(a.get("color", "#000"), a.get("transparency"))))
        elif tag == "font":
            if "color" in a:
                style.append("color:%s" % css_color_attr(a["color"], a.get("transparency")))
            if "size" in a:
                try:
                    style.append("font-size:%spx" % fnum(float(a["size"]) / natural_of("BuilderSans")))
                except ValueError:
                    pass
            if "weight" in a:
                w = {"thin": 100, "extralight": 200, "light": 300, "regular": 400, "medium": 500, "semibold": 600, "bold": 700,
                     "extrabold": 800, "heavy": 900}.get(a["weight"].lower())
                if w:
                    style.append("font-weight:%d" % w)
            if "face" in a or "family" in a:
                face = (a.get("face") or a.get("family") or "").lower()
                if "mono" in face or "code" in face:
                    style.append("font-family:'LC Mono'")
        out.append('<span style="%s">' % ";".join(style))
        stack.append(tag)
        if selfclose:
            out.append("</span>")
            stack.pop()
    out.append(literal(text[pos:]))
    out.append("</span>" * len(stack))
    return "".join(out)


def css_color_attr(value, transparency=None):
    value = value.strip()
    t = 0.0
    try:
        t = float(transparency) if transparency is not None else 0.0
    except ValueError:
        pass
    m = re.match(r"^#([0-9a-fA-F]{6})$", value)
    if m:
        h = m.group(1)
        c = C3(int(h[0:2], 16) / 255, int(h[2:4], 16) / 255, int(h[4:6], 16) / 255)
        return rgba(c, t)
    m = re.match(r"^#([0-9a-fA-F]{3})$", value)
    if m:
        h = m.group(1)
        c = C3(int(h[0] * 2, 16) / 255, int(h[1] * 2, 16) / 255, int(h[2] * 2, 16) / 255)
        return rgba(c, t)
    m = re.match(r"^rgb\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)$", value)
    if m:
        return rgba(C3(int(m.group(1)) / 255, int(m.group(2)) / 255, int(m.group(3)) / 255), t)
    return "currentColor"


# ---------------------------------------------------------------------------------------------------------------------
# the generator
# ---------------------------------------------------------------------------------------------------------------------
class Generator:
    def __init__(self, dump, width, height, theme_bg, images=None):
        self.root = Node(dump["root"])
        self.width, self.height = width, height
        self.theme_bg = theme_bg
        self.images = images  # object with .resolve(url) -> dict(kind="file"/"placeholder", ...)
        self.count = 0
        self.notes = list(dump.get("notes", []))

    # --- colour / gradient / stroke --------------------------------------------------------------------------------
    def background(self, n):
        bt = n.get("BackgroundTransparency") or 0
        grad = n.mod("UIGradient")
        bg = n.get("BackgroundColor3")
        if grad is not None and grad.get("Enabled") is not False:
            css = self.gradient(grad, bg, bt)
            if css:
                return css
        if bt >= 0.999:
            return None
        return "background-color:" + rgba(bg, bt)

    def gradient(self, grad, base, base_t):
        cs = grad.get("Color")
        ns = grad.get("Transparency")
        times = set()
        if isinstance(cs, CSeq):
            times |= {p[0] for p in cs.pts}
        if isinstance(ns, NSeq):
            times |= {p[0] for p in ns.pts}
        if not times:
            return None

        def sample_c(t):
            if not isinstance(cs, CSeq):
                return C3(1, 1, 1)
            pts = cs.pts
            for i in range(len(pts) - 1):
                if pts[i][0] <= t <= pts[i + 1][0]:
                    span = pts[i + 1][0] - pts[i][0] or 1
                    f = (t - pts[i][0]) / span
                    return C3(*[pts[i][k] + (pts[i + 1][k] - pts[i][k]) * f for k in (1, 2, 3)])
            return C3(*pts[-1][1:4])

        def sample_n(t):
            if not isinstance(ns, NSeq):
                return 0.0
            pts = ns.pts
            for i in range(len(pts) - 1):
                if pts[i][0] <= t <= pts[i + 1][0]:
                    span = pts[i + 1][0] - pts[i][0] or 1
                    return pts[i][1] + (pts[i + 1][1] - pts[i][1]) * ((t - pts[i][0]) / span)
            return pts[-1][1]

        stops = []
        for t in sorted(times):
            c = sample_c(t)
            col = C3(base.r * c.r, base.g * c.g, base.b * c.b)
            alpha_t = 1 - (1 - base_t) * (1 - sample_n(t))
            stops.append("%s %s%%" % (rgba(col, alpha_t), fnum(t * 100)))
        angle = 90 + (grad.get("Rotation") or 0)
        return "background-image:linear-gradient(%sdeg,%s)" % (fnum(angle), ",".join(stops))

    def strokes(self, n):
        """(outline css list, text-stroke css list, box-shadow list) from the UIStroke children"""
        outline, text, shadows = [], [], []
        for s in n.mods.get("UIStroke", []):
            if s.get("Enabled") is False:
                continue
            thick = s.get("Thickness") or 0
            if thick <= 0:
                continue
            col = rgba(s.get("Color"), s.get("Transparency") or 0)
            mode = s.en("ApplyStrokeMode")
            if mode == "Contextual" and n.cls in TEXT_CLASSES:
                text.append("-webkit-text-stroke:%spx %s" % (fnum(thick), col))
            else:
                where = s.en("BorderStrokePosition") or "Outer"  # Roblox default: the stroke grows outwards
                if where == "Outer":
                    outline.append("outline:%spx solid %s;outline-offset:0" % (fnum(thick), col))
                elif where == "Inner":
                    shadows.append("inset 0 0 0 %spx %s" % (fnum(thick), col))
                else:
                    outline.append("outline:%spx solid %s;outline-offset:0" % (fnum(thick / 2), col))
                    shadows.append("inset 0 0 0 %spx %s" % (fnum(thick / 2), col))
        return outline, text, shadows

    # --- placement ---------------------------------------------------------------------------------------------------
    def size_css(self, n, in_flow):
        """width / height (+ min size for AutomaticSize) of a node"""
        size = n.get("Size")
        auto = n.en("AutomaticSize") or "None"
        out = []
        for axis, (sc, off), is_auto in (("width", (size.xs, size.xo), auto in ("X", "XY")),
                                         ("height", (size.ys, size.yo), auto in ("Y", "XY"))):
            if is_auto:
                out.append("%s:auto" % axis)
                if sc or off:
                    out.append("min-%s:%s" % (axis, length(sc, off)))
            else:
                out.append("%s:%s" % (axis, length(sc, off)))
        sc = n.mod("UISizeConstraint")
        if sc is not None:
            mn, mx = sc.get("MinSize"), sc.get("MaxSize")
            if isinstance(mn, V2):
                if mn.x > 0:
                    out.append("min-width:%spx" % fnum(mn.x))
                if mn.y > 0:
                    out.append("min-height:%spx" % fnum(mn.y))
            if isinstance(mx, V2):
                if mx.x < 1e8:
                    out.append("max-width:%spx" % fnum(mx.x))
                if mx.y < 1e8:
                    out.append("max-height:%spx" % fnum(mx.y))
        ar = n.mod("UIAspectRatioConstraint")
        if ar is not None and (ar.get("AspectRatio") or 0) > 0:
            dom = ar.en("DominantAxis") or "Width"
            out.append("aspect-ratio:%s" % fnum(ar.get("AspectRatio")))
            out.append("height:auto" if dom == "Width" else "width:auto")
        return out

    def padding_of(self, n):
        pad = n.mod("UIPadding")
        if pad is None:
            return None
        return tuple(pad.get(k) for k in ("PaddingTop", "PaddingRight", "PaddingBottom", "PaddingLeft"))

    # --- node ------------------------------------------------------------------------------------------------------------
    def emit(self, n, parent_kind, parent_layout):
        """one node; a node the generator cannot handle becomes a red dashed box (and a note) instead of stopping the page"""
        try:
            return self._emit(n, parent_kind, parent_layout)
        except Exception as e:  # noqa: BLE001 - robust to GUI kits that use properties / values this generator has not seen
            self.notes.append("htmlgen: %s %r (id %s): %s: %s" % (n.cls, n.name, n.id, type(e).__name__, e))
            return ('<div class="n" data-id="%s" data-c="%s" style="position:%s;width:40px;height:16px;outline:1px dashed #f55;'
                    'color:#f55;font:9px sans-serif">%s</div>' % (n.id, n.cls, "relative" if parent_kind != "abs" else "absolute",
                                                                 esc(n.cls)))

    def _emit(self, n, parent_kind, parent_layout):
        if n.cls.startswith("UI") or n.cls not in GUI_OBJECTS:
            return ""
        if n.get("Visible") is False:
            return ""
        self.count += 1
        style = []
        cls = ["n", "c-" + n.cls]
        attrs = {"data-id": n.id, "data-c": n.cls}
        lay = n.mod("UIListLayout") or n.mod("UIPageLayout") or n.mod("UITableLayout")
        grid = n.mod("UIGridLayout")
        pad = self.padding_of(n)
        z = n.get("ZIndex") or 1
        style.append("z-index:%d" % z)

        # placement in the parent
        flex_item = None
        if parent_kind == "list":
            flex_item = self.flex_of(n, parent_layout)
            style += ["position:relative", "flex:%s %s auto" % (fnum(flex_item[0]), fnum(flex_item[1]))]
            if flex_item[1] > 0:
                style.append("min-width:0;min-height:0")
            if flex_item[2]:
                style.append("align-self:" + flex_item[2])
            style += self.size_css(n, True)
        elif parent_kind == "grid":
            style.append("position:relative")
            cell = parent_layout.get("CellSize")
            style += ["width:%s" % length(cell.xs, cell.xo), "height:%s" % length(cell.ys, cell.yo)]
        else:
            pos, anchor = n.get("Position"), n.get("AnchorPoint")
            style += ["position:absolute", "left:%s" % length(pos.xs, pos.xo), "top:%s" % length(pos.ys, pos.yo)]
            style += self.size_css(n, False)
        tf = []
        if parent_kind == "abs":
            anchor = n.get("AnchorPoint")
            if anchor.x or anchor.y:
                tf.append("translate(%s%%,%s%%)" % (fnum(-anchor.x * 100), fnum(-anchor.y * 100)))
        rot = n.get("Rotation")
        if rot:
            tf.append("rotate(%sdeg)" % fnum(rot))
        if tf:
            style.append("transform:" + " ".join(tf))

        # look
        bg = self.background(n)
        if bg:
            style.append(bg)
        if n.get("ClipsDescendants") or n.cls == "ScrollingFrame":
            style.append("overflow:hidden")
        corner = n.mod("UICorner")
        if corner is not None:
            cr = corner.get("CornerRadius")
            if cr.s >= 0.5 and cr.o == 0:
                style.append("border-radius:9999px")
            elif cr.s:
                style.append("border-radius:calc(%s%% + %spx)" % (fnum(cr.s * 100), fnum(cr.o)))
            else:
                style.append("border-radius:%spx" % fnum(cr.o))
        outline, text_stroke, shadows = self.strokes(n)
        style += outline
        bsp = n.get("BorderSizePixel") or 0
        if bsp > 0 and n.cls in GUI_OBJECTS:
            mode = n.en("BorderMode")
            col = rgba(n.get("BorderColor3"))
            shadows.append("%s0 0 0 %spx %s" % ("inset " if mode == "Inset" else "", fnum(bsp), col))
        if shadows:
            style.append("box-shadow:" + ",".join(shadows))
        if n.cls == "CanvasGroup":
            gt = n.p.get("GroupTransparency") or 0
            if gt:
                style.append("opacity:%s" % fnum(1 - gt))

        inner = []
        # content host: flex / grid container props go to the node itself (or the canvas of a ScrollingFrame)
        host_style = []
        if lay is not None:
            host_style += self.list_css(lay)
            attrs["data-layout"] = "list"
        elif grid is not None:
            host_style += self.grid_css(grid)
            attrs["data-layout"] = "grid"
        elif n.cls in TEXT_CLASSES:
            host_style += ["display:flex", "flex-direction:column"]
        if pad is not None:
            host_style += self.padding_css(pad, in_flow=True)

        # text
        if n.cls in TEXT_CLASSES:
            tx, tx_style, tx_attrs = self.text_html(n, text_stroke, auto=n.en("AutomaticSize") or "None")
            if tx is not None:
                if lay is None and grid is None:
                    host_style.append("justify-content:" + {"Top": "flex-start", "Center": "center", "Bottom": "flex-end"}.get(
                        n.en("TextYAlignment") or "Center", "center"))
                inner.append(tx)
                attrs.update(tx_attrs)
                style += tx_style

        # image
        if n.cls in IMAGE_CLASSES:
            im = self.image_html(n)
            if im:
                inner.append(im)

        # children
        kids = [k for k in n.kids if not k.cls.startswith("UI") and k.cls in GUI_OBJECTS]
        child_html = ""
        has_abs = False
        if lay is not None or grid is not None:
            ordered = self.sorted_kids(kids, lay or grid)
            kind = "list" if lay is not None else "grid"
            child_html = "".join(self.emit(k, kind, lay or grid) for k in ordered)
        else:
            parts = [self.emit(k, "abs", None) for k in kids]
            child_html = "".join(parts)
            has_abs = any(parts)

        if n.cls == "ScrollingFrame":
            return self.scrolling(n, style, cls, attrs, inner, child_html, host_style, pad, lay, grid, has_abs)

        if pad is not None and has_abs and lay is None and grid is None:
            child_html = '<div class="ac" style="%s">%s</div>' % (self.inset_css(pad), child_html)
            attrs["data-ac"] = "1"
        # AutomaticSize frames that only hold absolutely placed children are sized by page.js
        auto = n.en("AutomaticSize") or "None"
        if auto != "None" and has_abs and lay is None and grid is None and n.cls not in TEXT_CLASSES:
            attrs["data-fit"] = auto.lower()
        style += host_style
        return self.tag("div", cls, attrs, style, "".join(inner) + child_html)

    def tag(self, name, cls, attrs, style, content):
        a = " ".join('%s="%s"' % (k, esc(str(v))) for k, v in attrs.items())
        return '<%s class="%s" %s style="%s">%s</%s>' % (name, " ".join(cls), a, ";".join(s for s in style if s), content, name)

    # --- layouts ---------------------------------------------------------------------------------------------------------
    def sorted_kids(self, kids, layout):
        order = layout.en("SortOrder") or "LayoutOrder"
        indexed = list(enumerate(kids))
        if order == "Name":
            indexed.sort(key=lambda t: (t[1].name, t[0]))
        elif order == "LayoutOrder":
            indexed.sort(key=lambda t: (t[1].get("LayoutOrder") or 0, t[0]))
        return [k for _, k in indexed]

    def list_css(self, lay):
        horizontal = lay.en("FillDirection") == "Horizontal"
        ha, va = lay.en("HorizontalAlignment") or "Left", lay.en("VerticalAlignment") or "Top"
        main_flex = lay.en("HorizontalFlex" if horizontal else "VerticalFlex") or "None"
        out = ["display:flex", "flex-direction:" + ("row" if horizontal else "column")]
        gap = lay.get("Padding")
        if gap.s or gap.o:
            out.append("gap:" + length(gap.s, gap.o))
        h_map = {"Left": "flex-start", "Center": "center", "Right": "flex-end"}
        v_map = {"Top": "flex-start", "Center": "center", "Bottom": "flex-end"}
        if horizontal:
            main, cross = h_map.get(ha, "flex-start"), v_map.get(va, "flex-start")
        else:
            main, cross = v_map.get(va, "flex-start"), h_map.get(ha, "flex-start")
        spread = {"SpaceBetween": "space-between", "SpaceAround": "space-around", "SpaceEvenly": "space-evenly"}
        if main_flex in spread:
            main = spread[main_flex]
        out.append("justify-content:" + main)
        out.append("align-items:" + cross)
        if lay.get("Wraps"):
            out.append("flex-wrap:wrap")
        return out

    def grid_css(self, grid):
        cell, cp = grid.get("CellSize"), grid.get("CellPadding")
        horizontal = grid.en("FillDirection") != "Vertical"
        out = ["display:grid", "gap:%s %s" % (length(cp.ys, cp.yo), length(cp.xs, cp.xo))]
        cw, ch = length(cell.xs, cell.xo), length(cell.ys, cell.yo)
        if horizontal:
            out += ["grid-template-columns:repeat(auto-fill,%s)" % cw, "grid-auto-rows:%s" % ch]
        else:
            out += ["grid-template-rows:repeat(auto-fill,%s)" % ch, "grid-auto-columns:%s" % cw, "grid-auto-flow:column"]
        out.append("justify-content:" + {"Left": "start", "Center": "center", "Right": "end"}.get(grid.en("HorizontalAlignment") or "Left", "start"))
        out.append("align-content:" + {"Top": "start", "Center": "center", "Bottom": "end"}.get(grid.en("VerticalAlignment") or "Top", "start"))
        return out

    def flex_of(self, n, layout):
        """(grow, shrink, align-self) of a list item"""
        grow, shrink, align = 0, 0, None
        horizontal = layout.en("FillDirection") == "Horizontal" if layout.cls == "UIListLayout" else True
        main_flex = layout.en("HorizontalFlex" if horizontal else "VerticalFlex") if layout.cls == "UIListLayout" else "None"
        if main_flex == "Fill":
            grow, shrink = 1, 1
        item = n.mod("UIFlexItem")
        if item is not None:
            mode = item.en("FlexMode") or "None"
            if mode == "Fill":
                grow, shrink = 1, 1
            elif mode == "Grow":
                grow, shrink = 1, 0
            elif mode == "Shrink":
                grow, shrink = 0, 1
            elif mode == "Custom":
                grow, shrink = item.get("GrowRatio") or 0, item.get("ShrinkRatio") or 0
            ila = item.en("ItemLineAlignment")
            align = {"Start": "flex-start", "Center": "center", "End": "flex-end", "Stretch": "stretch"}.get(ila)
        return grow, shrink, align

    def padding_css(self, pad, in_flow):
        t, r, b, l = pad
        return ["padding:%s %s %s %s" % (length(t.s, t.o), length(r.s, r.o), length(b.s, b.o), length(l.s, l.o))]

    def inset_css(self, pad):
        t, r, b, l = pad
        return "position:absolute;top:%s;right:%s;bottom:%s;left:%s" % (length(t.s, t.o), length(r.s, r.o), length(b.s, b.o), length(l.s, l.o))

    # --- text --------------------------------------------------------------------------------------------------------------
    def text_html(self, n, text_stroke, auto):
        text = n.get("Text")
        placeholder = False
        if n.cls == "TextBox" and (text is None or text == "") and n.get("PlaceholderText"):
            text, placeholder = n.get("PlaceholderText"), True
        if text is None or text == "":
            return None, [], {}
        family, weight, italic, natural = font_of(n)
        size = n.get("TextSize") or 14
        lh = n.get("LineHeight") or 1
        wrapped = bool(n.get("TextWrapped")) or (n.cls == "TextBox" and bool(n.get("MultiLine")))
        trunc = n.en("TextTruncate") or "None"
        em = size / natural
        color = n.get("PlaceholderColor3") if placeholder else n.get("TextColor3")
        tt = n.get("TextTransparency") or 0
        css = ["font-family:%s,sans-serif" % family, "font-size:%spx" % fnum(em), "font-weight:%d" % weight,
               "line-height:%spx" % fnum(size * lh), "color:" + rgba(color, tt)]
        if italic:
            css.append("font-style:italic")
        xa = n.en("TextXAlignment") or "Center"
        css.append("text-align:" + {"Left": "left", "Center": "center", "Right": "right"}.get(xa, "center"))
        if wrapped:
            css += ["white-space:pre-wrap", "overflow-wrap:anywhere"]
        else:
            css.append("white-space:pre")
            if trunc != "None":
                css += ["overflow:hidden", "text-overflow:ellipsis", "white-space:nowrap"]
        if (n.get("TextStrokeTransparency") or 1) < 1:
            sc = rgba(n.get("TextStrokeColor3"), n.get("TextStrokeTransparency"))
            css.append("text-shadow:%s" % ",".join("%s %s 0 %s" % (dx, dy, sc) for dx, dy in (("1px", "0"), ("-1px", "0"), ("0", "1px"), ("0", "-1px"))))
        css += text_stroke
        if n.get("RichText") and not placeholder:
            content = rich_to_html(text, size)
        else:
            content = esc(text)
        attrs = {}
        if n.get("TextScaled"):
            attrs["data-scaled"] = "1"
            attrs["data-nat"] = fnum(natural)
            tsc = n.mod("UITextSizeConstraint")
            if tsc is not None:
                attrs["data-tsmin"] = fnum(tsc.get("MinTextSize") or 1)
                attrs["data-tsmax"] = fnum(tsc.get("MaxTextSize") or 100)
        # wrapped text in a node with a fixed width: the text block takes the node's width
        return '<div class="tx" style="%s">%s</div>' % (";".join(css), content), [], attrs

    # --- images ------------------------------------------------------------------------------------------------------------
    def image_html(self, n):
        url = n.get("Image") or ""
        if not url:
            return ""
        info = self.images.resolve(url) if self.images else {"kind": "placeholder", "label": url}
        trans = n.get("ImageTransparency") or 0
        tint = n.get("ImageColor3")
        style = ["position:absolute", "inset:0", "pointer-events:none"]
        if trans:
            style.append("opacity:%s" % fnum(1 - trans))
        if info["kind"] != "file":
            return '<div class="ph" style="%s"><span>%s</span></div>' % (";".join(style), esc(info.get("label", "")))
        rect_off, rect_size = n.get("ImageRectOffset"), n.get("ImageRectSize")
        scale = n.en("ScaleType") or "Stretch"
        src = "url('%s')" % info["src"]
        attrs = ""
        if rect_size.x > 0 and rect_size.y > 0:
            attrs = ' data-sprite="%s,%s,%s,%s,%s,%s"' % (fnum(rect_off.x), fnum(rect_off.y), fnum(rect_size.x), fnum(rect_size.y),
                                                          info["w"], info["h"])
            style += ["background-repeat:no-repeat", "image-rendering:auto"]
        else:
            size_css = {"Stretch": "100% 100%", "Fit": "contain", "Crop": "cover", "Slice": "100% 100%", "Tile": "auto"}.get(scale, "100% 100%")
            style += ["background-size:" + size_css, "background-position:center",
                      "background-repeat:%s" % ("repeat" if scale == "Tile" else "no-repeat")]
            if scale == "Tile":
                ts = n.p.get("TileSize")
                if isinstance(ts, UD2):
                    style[-3] = "background-size:%s %s" % (length(ts.xs, ts.xo), length(ts.ys, ts.yo))
        if not is_white(tint):
            style += ["background-color:" + rgba(tint), "-webkit-mask-image:" + src, "mask-image:" + src,
                      "-webkit-mask-size:100% 100%", "mask-size:100% 100%", "-webkit-mask-repeat:no-repeat", "mask-repeat:no-repeat"]
            if attrs:
                attrs += ' data-masked="1"'
        else:
            style.append("background-image:" + src)
        return '<div class="im"%s style="%s"></div>' % (attrs, ";".join(style))

    # --- scrolling frame -----------------------------------------------------------------------------------------------------
    def scrolling(self, n, style, cls, attrs, inner, child_html, host_style, pad, lay, grid, has_abs):
        thick = n.get("ScrollBarThickness") or 0
        info = {
            "t": thick, "d": n.en("ScrollingDirection") or "XY", "a": n.en("AutomaticCanvasSize") or "None",
            "vi": n.en("VerticalScrollBarInset") or "None", "hi": n.en("HorizontalScrollBarInset") or "None",
            "cs": list(n.get("CanvasSize")), "cp": list(n.get("CanvasPosition")), "list": lay is not None or grid is not None,
            "sbc": rgba(n.get("ScrollBarImageColor3"), n.get("ScrollBarImageTransparency") or 0),
            "left": n.en("VerticalScrollBarPosition") == "Left",
        }
        attrs["data-sf"] = json.dumps(info, separators=(",", ":"))
        cv_style = ["position:absolute", "left:0", "top:0", "width:100%", "min-height:100%"] + host_style
        if pad is not None and has_abs and lay is None and grid is None:
            child_html = '<div class="ac" style="%s">%s</div>' % (self.inset_css(pad), child_html)
        content = '<div class="cv host" style="%s">%s</div><div class="sbar"></div>' % (";".join(cv_style), child_html)
        cls.append("sf")
        return self.tag("div", cls, attrs, style, "".join(inner) + content)

    # --- page ----------------------------------------------------------------------------------------------------------------
    def body(self):
        root = self.root
        kids = [k for k in root.kids if k.cls in GUI_OBJECTS]
        inner = "".join(self.emit(k, "abs", None) for k in kids)
        return ('<div id="root" data-id="%d" data-c="%s" style="position:relative;width:%dpx;height:%dpx;overflow:hidden;'
                'background:%s">%s</div>' % (root.id, root.cls, self.width, self.height, self.theme_bg, inner))


def page(gen, fonts_css, theme_bg):
    css = open(os.path.join(HERE, "page.css"), encoding="utf-8").read()
    js = open(os.path.join(HERE, "page.js"), encoding="utf-8").read()
    return ('<!doctype html><html><head><meta charset="utf-8"><title>LostCube preview</title><style>%s\n%s</style></head>'
            '<body style="background:%s">%s<script>%s</script></body></html>' % (fonts_css, css, theme_bg, gen.body(), js))

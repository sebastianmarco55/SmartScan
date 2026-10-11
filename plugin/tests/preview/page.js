// Runs in the browser after the page loaded: the layout steps CSS cannot do + the measurements for the next Luau pass.
(function () {
  const R = document.getElementById('root');
  const q = (sel, root) => Array.from((root || document).querySelectorAll(sel));
  const rect = (el) => el.getBoundingClientRect();

  function childNodes(host) {
    return Array.from(host.children).filter((c) => c.classList.contains('n') || c.classList.contains('ac'));
  }

  // children extents of a frame without a layout, relative to the origin of its content area
  function extents(el) {
    const host = Array.from(el.children).find((c) => c.classList.contains('ac')) || el;
    const hr = rect(host);
    let r = 0, b = 0;
    for (const c of host.children) {
      if (!c.classList.contains('n')) continue;
      const cr = rect(c);
      r = Math.max(r, cr.right - hr.left);
      b = Math.max(b, cr.bottom - hr.top);
    }
    return { r, b, host, hr };
  }

  function scaleText() {
    for (const el of q('[data-scaled]')) {
      const tx = Array.from(el.children).find((c) => c.classList.contains('tx'));
      if (!tx) continue;
      const cs = getComputedStyle(el), er = rect(el);
      const w = er.width - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight);
      const h = er.height - parseFloat(cs.paddingTop) - parseFloat(cs.paddingBottom);
      const nat = parseFloat(el.dataset.nat) || 1.26;
      let lo = parseFloat(el.dataset.tsmin) || 1, hi = parseFloat(el.dataset.tsmax) || 100;
      const fits = (s) => {
        tx.style.fontSize = s / nat + 'px';
        tx.style.lineHeight = s + 'px';
        return tx.scrollWidth <= w + 0.5 && rect(tx).height <= h + 0.5;
      };
      if (fits(hi)) { fits(hi); continue; }
      for (let i = 0; i < 14; i++) {
        const mid = (lo + hi) / 2;
        if (fits(mid)) lo = mid; else hi = mid;
      }
      fits(lo);
    }
  }

  function sprites() {
    for (const im of q('.im[data-sprite]')) {
      const [ox, oy, rw, rh, iw, ih] = im.dataset.sprite.split(',').map(Number);
      const r = rect(im.parentElement);
      const sx = r.width / rw, sy = r.height / rh;
      const size = iw * sx + 'px ' + ih * sy + 'px', pos = -ox * sx + 'px ' + -oy * sy + 'px';
      im.style.backgroundSize = size;
      im.style.backgroundPosition = pos;
      if (im.dataset.masked) {
        im.style.webkitMaskSize = size; im.style.maskSize = size;
        im.style.webkitMaskPosition = pos; im.style.maskPosition = pos;
      }
    }
  }

  function fit(el) {
    const mode = el.dataset.fit;
    const e = extents(el);
    const er = rect(el);
    const extraX = er.width - e.hr.width, extraY = er.height - e.hr.height;
    if (mode.indexOf('x') >= 0) el.style.width = Math.ceil(e.r + extraX) + 'px';
    if (mode.indexOf('y') >= 0) el.style.height = Math.ceil(e.b + extraY) + 'px';
  }

  function scrolling(el) {
    const info = JSON.parse(el.dataset.sf);
    const cv = Array.from(el.children).find((c) => c.classList.contains('cv'));
    const bar = Array.from(el.children).find((c) => c.classList.contains('sbar'));
    const vr = rect(el), vw = vr.width, vh = vr.height;
    const th = info.t;
    const autoY = info.a === 'Y' || info.a === 'XY', autoX = info.a === 'X' || info.a === 'XY';
    const dirY = info.d.indexOf('Y') >= 0, dirX = info.d.indexOf('X') >= 0;
    let width = vw;
    const natural = () => {
      cv.style.width = width + 'px';
      cv.style.minHeight = '0';
      cv.style.height = '';
      if (info.list) {
        const r = rect(cv);
        return { w: cv.scrollWidth, h: r.height };
      }
      const e = extents(cv);
      const cr = rect(cv);
      return { w: e.r + (cr.width - e.hr.width), h: e.b + (cr.height - e.hr.height) };
    };
    let nat = natural();
    const canvasH = () => (autoY ? nat.h : info.cs[2] * vh + info.cs[3]);
    if (dirY && th > 0 && (info.vi === 'Always' || (info.vi === 'ScrollBar' && canvasH() > vh + 0.5))) {
      width = vw - th;
      nat = natural();
    }
    const ch = Math.max(vh, canvasH());
    const cw = Math.max(width, dirX ? (autoX ? nat.w : info.cs[0] * vw + info.cs[1]) : 0);
    cv.style.width = cw + 'px';
    cv.style.height = ch + 'px';
    cv.style.minHeight = '0';
    const maxY = Math.max(0, ch - vh), maxX = Math.max(0, cw - vw);
    const py = Math.min(Math.max(info.cp[1], 0), maxY), px = Math.min(Math.max(info.cp[0], 0), maxX);
    cv.style.top = -py + 'px';
    cv.style.left = -px + 'px';
    el.dataset.cvw = cw;
    el.dataset.cvh = ch;
    if (bar) {
      if (dirY && th > 0 && ch > vh + 0.5) {
        const thumb = Math.max(Math.min(24, vh), (vh * vh) / ch);
        bar.style.display = 'block';
        bar.style.width = th + 'px';
        bar.style.height = thumb + 'px';
        bar.style.top = (maxY ? (py / maxY) * (vh - thumb) : 0) + 'px';
        bar.style[info.left ? 'left' : 'right'] = '0';
        bar.style.background = info.sbc;
      } else {
        bar.style.display = 'none';
      }
    }
  }

  function layout() {
    scaleText();
    // deepest first: a frame is measured after everything inside it
    const all = q('[data-fit],[data-sf]').reverse();
    for (const el of all) {
      if (el.dataset.sf) scrolling(el); else fit(el);
    }
    sprites();
  }

  window.__layout = function () {
    layout();
    // fitting a frame can change the lines of a text below it: one more round settles it
    layout();
    return true;
  };

  window.__measure = function () {
    const out = {};
    const rr = rect(R);
    for (const el of q('[data-id]')) {
      const r = rect(el);
      const e = { c: el.dataset.c, x: r.left - rr.left, y: r.top - rr.top, w: r.width, h: r.height };
      if (el.dataset.layout) {
        const host = el.classList.contains('sf') ? Array.from(el.children).find((c) => c.classList.contains('cv')) : el;
        let x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9, any = false;
        for (const c of host.children) {
          if (!c.classList.contains('n')) continue;
          const cr = rect(c);
          any = true;
          x0 = Math.min(x0, cr.left); y0 = Math.min(y0, cr.top); x1 = Math.max(x1, cr.right); y1 = Math.max(y1, cr.bottom);
        }
        e.cw = any ? x1 - x0 : 0;
        e.ch = any ? y1 - y0 : 0;
      }
      if (el.dataset.cvw) { e.cvw = parseFloat(el.dataset.cvw); e.cvh = parseFloat(el.dataset.cvh); }
      const tx = Array.from(el.children).find((c) => c.classList.contains('tx'));
      if (tx) {
        const range = document.createRange();
        range.selectNodeContents(tx);
        const tr = range.getBoundingClientRect();
        e.tw = tr.width; e.th = tr.height;
      }
      for (const k of ['x', 'y', 'w', 'h', 'cw', 'ch', 'cvw', 'cvh', 'tw', 'th']) {
        if (typeof e[k] === 'number') e[k] = Math.round(e[k] * 100) / 100;
      }
      out[el.dataset.id] = e;
    }
    return out;
  };
})();

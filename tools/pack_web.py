#!/usr/bin/env python3
"""Pack Godot's Web export (build/web/) into ONE self-contained HTML file.

The engine (.wasm) and game data (.pck) are gzip-compressed, base64-embedded in the page, and
decompressed in the browser with DecompressionStream. A small shim intercepts the loader's
fetch() for those two files and its AudioWorklet.addModule() calls, so Godot's own loader runs
unchanged. The result opens from disk (double-click), from any static server, or as a hosted page.
No threads build, so no cross-origin-isolation headers are needed.

    python3 tools/pack_web.py [build/web] [build/shardfall.html]
"""
import base64
import gzip
import json
import pathlib
import re
import sys

args = [a for a in sys.argv[1:] if not a.startswith("--")]
ARTIFACT = "--artifact" in sys.argv     # body-only page for hosts that add their own document skeleton
SPLIT = "--split" in sys.argv           # game data (.pck) in a sibling <out>_data.js, for hosts with a per-file size limit
src = pathlib.Path(args[0] if len(args) > 0 else "build/web")
out = pathlib.Path(args[1] if len(args) > 1 else "build/shardfall.html")
shell = (src / "index.html").read_text()
cfg = json.loads(re.search(r"const GODOT_CONFIG = (\{.*?\});", shell).group(1))
cfg["ensureCrossOriginIsolationHeaders"] = False
exe = cfg["executable"]


def b64gz(path: pathlib.Path) -> str:
    return base64.b64encode(gzip.compress(path.read_bytes(), 9, mtime=0)).decode("ascii")


wasm = b64gz(src / f"{exe}.wasm")
pck = b64gz(src / f"{exe}.pck")
# Worklets as data: URLs: blob: URLs created on a file:// page have an opaque origin and Chromium
# refuses them as worklet modules; data: URLs load from disk and from any server.
worklets = {p.name: "data:text/javascript;base64," + base64.b64encode(p.read_bytes()).decode("ascii") for p in src.glob(f"{exe}.audio*.js")}
loader = (src / f"{exe}.js").read_text()
# Loading screen art: the game's own logo and type, so the page matches the title screen.
ROOT = pathlib.Path(__file__).resolve().parent.parent / "godot"
def data_url(path: pathlib.Path, mime: str) -> str:
    return f"data:{mime};base64," + base64.b64encode(path.read_bytes()).decode("ascii")
WEB_LOGO = pathlib.Path(__file__).resolve().parent / "web_logo.png"     # 1120px copy of godot/ui/logo.png (tools/make_art.py)
logo_url = data_url(WEB_LOGO, "image/png") if WEB_LOGO.exists() else ""
cinzel = data_url(ROOT / "fonts" / "cinzel-latin-700-normal.woff2", "font/woff2")
garamond = data_url(ROOT / "fonts" / "eb-garamond-latin-400-italic.woff2", "font/woff2")
assert "</script" not in loader.lower(), "loader contains a closing script tag"

head = f"""<title>Shardfall Rift Survivors</title>
<style>
  @font-face {{ font-family: "Cinzel"; font-weight: 700; src: url({cinzel}) format("woff2"); }}
  @font-face {{ font-family: "EB Garamond"; font-style: italic; src: url({garamond}) format("woff2"); }}
  /* One dark look on purpose: a dungeon-lit loading screen in front of a full-bleed game canvas. */
  :root {{ color-scheme: dark; --bg: #07080c; --fg: #ece8dd; --dim: #9aa0b4; --gold: #f4c04e; --track: #1d2130; --glow: #1a1420; --ember: #b8762a; --err: #ff8a8a; }}
  html, body {{ margin: 0; height: 100%; background: var(--bg); color: var(--fg); overflow: hidden; touch-action: none; }}
  #canvas {{ display: block; width: 100%; height: 100%; outline: none; background: var(--bg); }}
  #canvas:focus-visible {{ outline: 2px solid var(--gold); outline-offset: -2px; }}
  #status {{ position: fixed; inset: 0; display: flex; flex-direction: column; align-items: center; justify-content: center;
            gap: 18px; background: radial-gradient(ellipse at 50% 40%, var(--glow) 0%, var(--bg) 70%); color: var(--fg);
            font: 16px/1.4 system-ui, -apple-system, Segoe UI, Roboto, sans-serif; text-align: center; padding: 16px; }}
  #status h1 {{ margin: 0; font: 700 clamp(28px, 6vw, 54px) "Cinzel", Georgia, serif; letter-spacing: .06em; color: var(--gold); }}
  #status h1 img {{ display: block; width: min(560px, 86vw); height: auto; }}
  #status p {{ margin: 0; color: var(--dim); max-width: 36em; font: italic 18px/1.45 "EB Garamond", Georgia, serif; }}
  #bar {{ width: min(420px, 80vw); height: 8px; border-radius: 4px; background: var(--track); overflow: hidden; }}
  #bar i {{ display: block; height: 100%; width: 0; background: linear-gradient(90deg, var(--ember), var(--gold)); transition: width .15s; }}
  @media (prefers-reduced-motion: reduce) {{ #bar i {{ transition: none; }} }}
  #msg {{ color: var(--dim); font: 700 13px "Cinzel", Georgia, serif; letter-spacing: .12em; text-transform: uppercase; min-height: 1.4em; }}
  #err {{ color: var(--err); white-space: pre-wrap; max-width: 40em; }}
</style>
"""
body = f"""<canvas id="canvas" tabindex="-1">Your browser does not support the canvas element.</canvas>
<div id="status">
  <h1>{('<img src="' + logo_url + '" alt="Shardfall: Rift Survivors">') if logo_url else 'SHARDFALL'}</h1>
  <p>Rift Survivors. Move with WASD or a thumb drag, roll with Space or double tap, ultimate with R, flasks with 1 and 2, pause with Esc.</p>
  <div id="bar"><i></i></div>
  <div id="msg">Unpacking the engine…</div>
  <div id="err"></div>
</div>
<script type="text/plain" id="g-wasm">{wasm}</script>
{'<script src="' + out.stem + '_data.js"></script>' if SPLIT else '<script type="text/plain" id="g-pck">' + pck + '</script>'}
<script>
// ---- embedded assets -> in-memory responses for Godot's loader -------------------------------
const WORKLETS = {json.dumps(worklets)};
const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const LUT = new Uint8Array(128); for (let i = 0; i < 64; i++) LUT[B64.charCodeAt(i)] = i;
function b64bytes(s) {{
  s = s.replace(/\\s+/g, "");
  let pad = s.endsWith("==") ? 2 : s.endsWith("=") ? 1 : 0;
  const n = s.length / 4 * 3 - pad, out = new Uint8Array(n);
  let o = 0;
  for (let i = 0; i < s.length; i += 4) {{
    const v = (LUT[s.charCodeAt(i)] << 18) | (LUT[s.charCodeAt(i + 1)] << 12) | (LUT[s.charCodeAt(i + 2)] << 6) | LUT[s.charCodeAt(i + 3)];
    if (o < n) out[o++] = v >> 16;
    if (o < n) out[o++] = (v >> 8) & 255;
    if (o < n) out[o++] = v & 255;
  }}
  return out;
}}
async function gunzip(id) {{
  const bytes = b64bytes(id === "g-pck" && window.G_PCK ? window.G_PCK : document.getElementById(id).textContent);
  const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("gzip"));
  return await new Response(stream).arrayBuffer();
}}
const FILES = {{}};
// The loader probes for a service worker; hosts and file:// pages do not allow one, so answer "none".
try {{ if (window.ServiceWorkerContainer) ServiceWorkerContainer.prototype.getRegistration = () => Promise.resolve(undefined); }} catch (e) {{}}
const realFetch = window.fetch.bind(window);
window.fetch = function (input, init) {{
  const url = typeof input === "string" ? input : (input && input.url) || "";
  for (const name in FILES) {{
    if (url.split("?")[0].endsWith(name)) {{
      const buf = FILES[name];
      const type = name.endsWith(".wasm") ? "application/wasm" : "application/octet-stream";
      return Promise.resolve(new Response(buf, {{ status: 200, headers: {{ "Content-Type": type, "Content-Length": String(buf.byteLength) }} }}));
    }}
  }}
  return realFetch(input, init);
}};
if (window.AudioWorklet) {{
  const realAdd = AudioWorklet.prototype.addModule;
  AudioWorklet.prototype.addModule = function (url, opts) {{
    const name = String(url).split("/").pop().split("?")[0];
    if (!WORKLETS[name]) return realAdd.call(this, url, opts);
    // blob: works on hosted pages (a data: worklet is refused by stricter content policies);
    // data: works from file://, where a blob: URL has an opaque origin. Try one, then the other.
    const dataUrl = WORKLETS[name];
    const blobUrl = URL.createObjectURL(new Blob([atob(dataUrl.slice(dataUrl.indexOf(",") + 1))], {{ type: "text/javascript" }}));
    return realAdd.call(this, blobUrl, opts).catch(() => realAdd.call(this, dataUrl, opts));
  }};
}}
</script>
<script>
{loader}
</script>
<script>
(async function () {{
  const GODOT_CONFIG = {json.dumps(cfg)};
  const bar = document.querySelector("#bar i"), msg = document.getElementById("msg"), err = document.getElementById("err");
  const fail = (e) => {{ console.error(e); err.textContent = (e && e.message) || String(e); msg.textContent = ""; }};
  try {{
    const missing = Engine.getMissingFeatures({{ threads: false }});
    if (missing.length) {{ fail("This browser is missing: " + missing.join(", ")); return; }}
    if (!("DecompressionStream" in window)) {{ fail("This browser is too old (no DecompressionStream). Use a current Chrome, Edge, Firefox or Safari."); return; }}
    bar.style.width = "8%";
    FILES["{exe}.wasm"] = await gunzip("g-wasm");
    bar.style.width = "30%";
    FILES["{exe}.pck"] = await gunzip("g-pck");
    msg.textContent = "Starting…";
    const engine = new Engine(GODOT_CONFIG);
    await engine.startGame({{
      onProgress: (cur, total) => {{ if (total > 0) bar.style.width = (30 + 70 * cur / total).toFixed(1) + "%"; }},
    }});
    document.getElementById("status").remove();
  }} catch (e) {{ fail(e); }}
}})();
</script>
"""
if ARTIFACT:
    page = head + body
else:
    page = ('<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
            '<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">\n'
            + head + "</head>\n<body>\n" + body + "</body>\n</html>\n")
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(page)
if SPLIT:
    data = out.with_name(out.stem + "_data.js")
    data.write_text('window.G_PCK = "' + pck + '";\n')
    print(f"{data}  {data.stat().st_size / 1e6:.2f} MB")
print(f"{out}  {out.stat().st_size / 1e6:.2f} MB  (wasm {len(wasm) / 1e6:.1f} MB b64, pck {len(pck) / 1e6:.2f} MB b64)")

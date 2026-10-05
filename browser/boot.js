// Ruby Playground をブラウザの中で動かす。
//
// サーバー版 (ruby web/server.rb) は、TCPServer で受けたリクエストから env を組み立てて
// PLAYGROUND.call(env) を呼んでいる。ブラウザ版は、その「受ける部分」だけを置き換える。
//   1. このリポジトリのファイルを取ってきて、仮のフォルダ (/app) に並べる
//   2. Ruby 本体 (ruby.wasm) を起動して browser/bridge.rb を読み込む
//   3. 画面のリンクとフォームを横取りして、Ruby の PLAYGROUND.call(env) を呼ぶ
// アプリ側の Ruby コードは一切変えていない。

import { RubyVM } from "https://cdn.jsdelivr.net/npm/@ruby/wasm-wasi@2.10.1/+esm";
import { WASI, File, Directory, OpenFile, PreopenDirectory, ConsoleStdout }
  from "https://cdn.jsdelivr.net/npm/@bjorn3/browser_wasi_shim@0.4.2/+esm";

const RUBY_WASM = "https://cdn.jsdelivr.net/npm/@ruby/3.4-wasm-wasi@2.10.1/dist/ruby+stdlib.wasm";

const $ = (id) => document.getElementById(id);
const frame = $("app");
const progress = (ratio, message) => {
  $("prog").style.width = `${Math.round(ratio * 100)}%`;
  if (message) $("msg").textContent = message;
};

// ------------------------------------------------------------ ファイル
// files.json に並んだファイルを取ってくる。バイト列のまま持つ (Shift_JIS の CSV もあるため)。
async function fetchFiles() {
  const list = await (await fetch("browser/files.json")).json();
  const files = {};
  let done = 0;
  await Promise.all(list.map(async (path) => {
    const res = await fetch(path);
    if (!res.ok) throw new Error(`${path} を読み込めません (${res.status})`);
    files[path] = new Uint8Array(await res.arrayBuffer());
    progress(0.05 + 0.25 * (++done / list.length));
  }));
  return files;
}

// { "a/b.rb": バイト列 } から、仮のフォルダの木を作る。
// VM ごとに別のコピーを作る (片方の書き込みが、もう片方に混ざらないように)。
function buildTree(files) {
  const root = new Map();
  for (const [path, bytes] of Object.entries(files)) {
    const parts = path.split("/");
    let dir = root;
    for (const name of parts.slice(0, -1)) {
      if (!dir.has(name)) dir.set(name, new Map());
      dir = dir.get(name);
    }
    dir.set(parts.at(-1), bytes.slice());
  }
  const toDirectory = (map) =>
    new Directory(new Map([...map].map(([name, v]) => [name, v instanceof Map ? toDirectory(v) : new File(v)])));
  return toDirectory(root);
}

// ------------------------------------------------------------ Ruby VM
let rubyModule;
let sourceFiles;

async function startVM({ quiet = false } = {}) {
  const fds = [
    new OpenFile(new File([])),
    ConsoleStdout.lineBuffered((line) => quiet || console.log(line)),
    ConsoleStdout.lineBuffered((line) => quiet || console.warn(line)),
    new PreopenDirectory("/", new Map([
      ["app", buildTree(sourceFiles)],
      ["tmp", new Directory(new Map())],
    ])),
  ];
  const wasi = new WASI([], ["TMPDIR=/tmp"], fds, { debug: false });
  const { vm } = await RubyVM.instantiateModule({ module: rubyModule, wasip1: wasi });
  return vm;
}

// ------------------------------------------------------------ クッキー
// アプリのセッションはクッキーで持つので、ブラウザ版でも覚えておいて毎回渡す。
const jar = new Map(JSON.parse(sessionStorage.getItem("ruby-playground-cookies") || "[]"));
const cookieHeader = () => [...jar].map(([k, v]) => `${k}=${v}`).join("; ");
function keepCookies(headers) {
  const value = headers["set-cookie"];
  if (!value) return;
  for (const line of [].concat(value)) {
    const pair = line.split(";")[0];
    const i = pair.indexOf("=");
    jar.set(pair.slice(0, i).trim(), pair.slice(i + 1));
  }
  sessionStorage.setItem("ruby-playground-cookies", JSON.stringify([...jar]));
}

// ------------------------------------------------------------ リクエスト
let vm;
let bridge;

function request(method, path, query, contentType, body) {
  const req = { method, path, query, contentType, body, cookie: cookieHeader() };
  const res = JSON.parse(bridge.call("handle", vm.wrap(req)).toString());
  keepCookies(res.headers);
  return res;
}

// テストのページ (/spec?run) だけは、先に別の Ruby VM でテストを走らせておく。
async function runSpecs(filter) {
  const result = { json: "", error: "", wall: "0" };
  const started = performance.now();
  try {
    const specVM = await startVM({ quiet: true });
    specVM.eval('require "/app/browser/spec_runner.rb"');
    result.json = specVM.eval("SpecRunner").call("run", specVM.wrap(filter)).toString();
  } catch (e) {
    result.error = String(e?.message ?? e);
  }
  result.wall = String((performance.now() - started) / 1000);
  window.rubyPlayground.specResult = result;
}

const isSpecRun = (u) => u.pathname.replace(/\/+$/, "") === "/spec" && u.searchParams.has("run");

async function go(method, url, { contentType = "", body = "", push = true } = {}) {
  for (let hop = 0; hop < 5; hop++) {
    const u = new URL(url, "http://playground");
    if (method === "GET" && isSpecRun(u)) {
      showBusy("テストを実行しています（別の Ruby の中で）…");
      await runSpecs((u.searchParams.get("e") || "").trim());
    }
    const res = request(method, u.pathname, u.search.slice(1), contentType, body);
    const location = res.headers.location;
    if (res.status >= 300 && res.status < 400 && location) {
      url = location; method = "GET"; contentType = ""; body = ""; push = true;
      continue;
    }
    render(res);
    const here = u.pathname + u.search;
    if (method === "GET" && push) {
      // 同じ画面に戻ってきただけ (コマンド送信 → 同じ画面 など) なら、履歴を積まずに置き換える
      if (here === current) history.replaceState(null, "", `#${here}`);
      else history.pushState(null, "", `#${here}`);
    }
    current = here;
    return;
  }
}

// ------------------------------------------------------------ 画面
let current = "/";

// アプリが返した HTML を iframe に出す。リンクとフォームを横取りする小さなスクリプトを先頭に足す。
const HELPER = `<script>
(() => {
  const P = parent.rubyPlayground;
  document.addEventListener("click", (e) => {
    const a = e.target.closest("a[href]");
    if (!a || e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || a.target) return;
    const href = a.getAttribute("href");
    if (!href.startsWith("/") || href.startsWith("//")) return;
    e.preventDefault();
    P.go("GET", href);
  });
  // ページ自身が submit を止めた (ファイルを読んでから送る等) ときは、ページに任せる
  document.addEventListener("submit", (e) => {
    if (e.defaultPrevented) return;
    e.preventDefault();
    P.submit(e.target, e.submitter);
  });
  HTMLFormElement.prototype.submit = function () { P.submit(this, null); };
})();
<\/script>`;

// CSS や画像も、サーバー版と同じくアプリ (Ruby) に頼んで受け取る。
// どのアプリが何を配っていても (例: /assets/… や /todo/style.css)、同じやり方で扱える。
const assetCache = new Map();
function assetUrl(path) {
  if (assetCache.has(path)) return assetCache.get(path);
  const u = new URL(path, "http://playground");
  const res = request("GET", u.pathname, u.search.slice(1), "", "");
  if (res.status !== 200) return path;
  const type = res.headers["content-type"] || "application/octet-stream";
  const data = res.base64 ? Uint8Array.from(atob(res.body), (c) => c.charCodeAt(0)) : res.body;
  const url = URL.createObjectURL(new Blob([data], { type }));
  assetCache.set(path, url);
  return url;
}

function render(res) {
  const type = res.headers["content-type"] || "";
  const html = type.includes("html") ? res.body
    : `<pre style="white-space:pre-wrap;font:13px/1.5 monospace;padding:16px">${escapeHtml(res.body)}</pre>`;
  const doc = new DOMParser().parseFromString(html, "text/html");
  for (const el of doc.querySelectorAll("link[href], img[src], script[src], source[src]")) {
    const attr = el.hasAttribute("src") ? "src" : "href";
    const value = el.getAttribute(attr);
    if (value.startsWith("/") && !value.startsWith("//")) el.setAttribute(attr, assetUrl(value));
  }
  doc.head.insertAdjacentHTML("afterbegin", HELPER);
  frame.srcdoc = `<!doctype html>\n${doc.documentElement.outerHTML}`;
  hideBusy();
}

function submit(form, submitter) {
  const method = (form.getAttribute("method") || "GET").toUpperCase();
  const action = form.getAttribute("action") || current;
  const params = new URLSearchParams();
  for (const [k, v] of new FormData(form, submitter || undefined)) if (typeof v === "string") params.append(k, v);
  if (method === "GET") {
    const u = new URL(action, "http://playground");
    u.search = params.toString();
    return go("GET", u.pathname + u.search);
  }
  return go("POST", action, { contentType: "application/x-www-form-urlencoded", body: params.toString(), push: false });
}

const escapeHtml = (s) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

function showBusy(message) {
  $("boot").hidden = false;
  $("boot").classList.add("busy");
  $("msg").textContent = message;
}
function hideBusy() {
  $("boot").hidden = true;
  frame.hidden = false;
}

frame.addEventListener("load", () => {
  const title = frame.contentDocument?.title;
  if (title) document.title = title;
});

window.addEventListener("popstate", () => go("GET", location.hash.slice(1) || "/", { push: false }));

// ------------------------------------------------------------ 起動
window.rubyPlayground = { go, submit, specResult: null };

try {
  progress(0.02, "アプリのファイルを読み込んでいます…");
  sourceFiles = await fetchFiles();
  progress(0.35, "Ruby 本体を読み込んでいます…");
  rubyModule = await WebAssembly.compileStreaming(fetch(RUBY_WASM));
  progress(0.85, "Ruby を起動しています…");
  vm = await startVM();
  vm.eval('require "/app/browser/bridge.rb"');
  bridge = vm.eval("BrowserBridge");
  progress(1);
  await go("GET", location.hash.slice(1) || "/", { push: false });
} catch (e) {
  console.error(e);
  $("boot").classList.add("err");
  $("msg").textContent = `起動できませんでした: ${e?.message ?? e}`;
}

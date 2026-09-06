#!/usr/bin/env node
// Static half of the gate: compare the shipped SwiftUI implementation against
// the design it ports, and report what the design has that the app does not.
//
//   node tools/uidiff/uidiff.js            # every screen
//   node tools/uidiff/uidiff.js Browse     # one screen
//
// Three report sections, all of which count:
//   MISSING     — a user-facing string the design draws and the app never emits
//   CHROME TEXT — navigation, section and status strings
//   PROPERTIES  — a design token whose value drifted
//
// A screen is not done until its own run reports zero missing. This exists
// because reading two SwiftUI files side by side has repeatedly missed a whole
// region — a card that never renders, a control drawn but never labelled.
//
// It compares source, not behaviour: a control that renders and does nothing
// still passes here. tools/verify/run.sh is the half that catches that.

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const DESIGN = path.join(ROOT, 'Wallpaper downloader app design', 'Walder');
const IMPL = path.join(ROOT, 'apps', 'Lumen', 'Sources');
const CANVAS = path.join(ROOT, 'Wallpaper downloader app design', 'Walder.dc.html');

// Screens, and the files that own them on each side.
const SCREENS = [
  { name: 'Browse',      design: ['Views/BrowseView.swift'],      impl: ['Views/BrowseView.swift'] },
  { name: 'Filters',     design: ['Views/FiltersPopover.swift'],  impl: ['Views/FiltersPopover.swift'] },
  { name: 'Detail',      design: ['Views/DetailSheet.swift'],     impl: ['Views/DetailSheet.swift'] },
  { name: 'Library',     design: ['Views/LibraryViews.swift'],    impl: ['Views/LibraryViews.swift'] },
  { name: 'Preferences', design: ['Views/PreferenceViews.swift'], impl: ['Views/PreferenceViews.swift'] },
  { name: 'QuickSet',    design: ['Views/QuickSetView.swift'],    impl: ['Views/QuickSetView.swift'] },
  { name: 'Shell',       design: ['Views/RootView.swift', 'WalderApp.swift'],
                         impl:   ['Views/RootView.swift', 'LumenApp.swift'] },
];

// Strings the rename deliberately changed, and the drop-ins that replace them.
const RENAMES = new Map([
  ['Walder', 'Lumen'],
  ['Open Walder', 'Open Lumen'],
  ['~/Pictures/Walder', '~/Pictures/Lumen'],
]);

// Design strings the port intentionally drops, each with the reason. Anything
// not listed here and not present in the implementation is a miss.
const WAIVED = new Map([
  // The canvas placeholder reads "#tag" and the reference Swift reads "tag".
  // The canvas wins: Wallhaven only does a tag search when the query is
  // prefixed with "#", so the hint has to show it.
  ['Search wallpapers or tag', 'canvas draws "#tag"; that is the form the API needs'],
]);

const read = (p) => (fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : '');

/** User-facing string literals, in the order SwiftUI would emit them. */
function strings(source) {
  const found = new Set();
  const patterns = [
    /\bText\(\s*"((?:[^"\\]|\\.)*)"/g,
    /\bButton\(\s*"((?:[^"\\]|\\.)*)"/g,
    /\bLabel\(\s*"((?:[^"\\]|\\.)*)"/g,
    /\bToggle\(\s*"((?:[^"\\]|\\.)*)"/g,
    /\bPicker\(\s*"((?:[^"\\]|\\.)*)"/g,
    /\bStepper\(\s*"((?:[^"\\]|\\.)*)"/g,
    /\bSecureField\(\s*"((?:[^"\\]|\\.)*)"/g,
    /\bTextField\(\s*"((?:[^"\\]|\\.)*)"/g,
    /\bLabeledContent\(\s*"((?:[^"\\]|\\.)*)"/g,
    /\bContentUnavailableView\(\s*"((?:[^"\\]|\\.)*)"/g,
    /\bSwiftUI\.Section\(\s*"((?:[^"\\]|\\.)*)"/g,
    /\bCommandMenu\(\s*"((?:[^"\\]|\\.)*)"/g,
    /\bLink\(\s*"((?:[^"\\]|\\.)*)"/g,
    /\.help\(\s*"((?:[^"\\]|\\.)*)"/g,
    /prompt:\s*"((?:[^"\\]|\\.)*)"/g,
    /placeholder:\s*"((?:[^"\\]|\\.)*)"/g,
    /\bChip\(text:\s*"((?:[^"\\]|\\.)*)"/g,
  ];
  for (const pattern of patterns) {
    for (const match of source.matchAll(pattern)) {
      const value = match[1].trim();
      // Interpolated or empty labels carry no fixed text to compare.
      if (!value || value.includes('\\(')) continue;
      found.add(value);
    }
  }
  return found;
}

/** Chrome: navigation titles, sidebar sections, status strings. */
function chrome(source) {
  const found = new Set();
  const patterns = [
    /\.navigationTitle\(\s*"((?:[^"\\]|\\.)*)"/g,
    /case\s+\.\w+:\s*"((?:[^"\\]|\\.)*)"/g,
    /systemImage:\s*"((?:[^"\\]|\\.)*)"/g,
    /\bImage\(systemName:\s*"((?:[^"\\]|\\.)*)"/g,
    /case\s+\w+\s*=\s*"((?:[^"\\]|\\.)*)"/g,
  ];
  for (const pattern of patterns) {
    for (const match of source.matchAll(pattern)) {
      const value = match[1].trim();
      if (!value || value.includes('\\(')) continue;
      found.add(value);
    }
  }
  return found;
}

/** Design tokens, as name -> literal value. */
function tokens(source) {
  const map = new Map();
  const pattern = /static\s+let\s+(\w+)\s*(?::\s*[\w<>.]+)?\s*=\s*([^\n]+)/g;
  for (const match of source.matchAll(pattern)) {
    map.set(match[1], match[2].replace(/\/\/.*$/, '').trim().replace(/,$/, ''));
  }
  return map;
}

function gather(dir, files, fn) {
  const out = new Set();
  for (const file of files) {
    for (const value of fn(read(path.join(dir, file)))) out.add(value);
  }
  return out;
}

/** Applies the rename map so a deliberate change is not reported as a loss. */
function normalise(value) {
  if (RENAMES.has(value)) return RENAMES.get(value);
  let out = value;
  for (const [from, to] of RENAMES) out = out.split(from).join(to);
  return out;
}

function diffScreen(screen) {
  const designText = gather(DESIGN, screen.design, strings);
  const implText = gather(IMPL, screen.impl, strings);
  const designChrome = gather(DESIGN, screen.design, chrome);
  const implChrome = gather(IMPL, screen.impl, chrome);

  const missing = [];
  const waived = [];
  for (const value of designText) {
    const expected = normalise(value);
    if (implText.has(expected)) continue;
    if (WAIVED.has(value)) { waived.push(value); continue; }
    missing.push({ value, expected });
  }

  const missingChrome = [];
  for (const value of designChrome) {
    const expected = normalise(value);
    if (implChrome.has(expected)) continue;
    if (WAIVED.has(value)) continue;
    missingChrome.push({ value, expected });
  }

  return { screen: screen.name, missing, missingChrome, waived, designCount: designText.size };
}

function diffTokens() {
  const designTokens = tokens(read(path.join(DESIGN, 'Design/Theme.swift')));
  const implTokens = tokens(read(path.join(IMPL, 'Design/Theme.swift')));
  // wallhavenBlue was renamed to brand; the value is what must not drift.
  const alias = new Map([['wallhavenBlue', 'brand']]);
  const drift = [];
  for (const [name, value] of designTokens) {
    const target = alias.get(name) ?? name;
    if (!implTokens.has(target)) {
      drift.push({ name, expected: value, actual: '(absent)' });
      continue;
    }
    const actual = implTokens.get(target);
    if (actual !== value) drift.push({ name: target, expected: value, actual });
  }
  return drift;
}

/** Chrome strings the canvas draws that the app must emit somewhere. */
function canvasChrome() {
  const html = read(CANVAS);
  if (!html) return [];
  const literals = new Set();
  // Text between tags, minus template bindings.
  for (const match of html.matchAll(/>([^<>{}]{3,40})</g)) {
    const value = match[1].trim();
    if (!value || /^[\s\d.,·—–|]*$/.test(value)) continue;
    if (!/[A-Za-z]/.test(value)) continue;
    literals.add(value);
  }
  for (const match of html.matchAll(/placeholder="([^"]+)"/g)) {
    const value = match[1].trim();
    if (value.includes('{{')) continue;   // a binding, not drawn text
    literals.add(value);
  }

  const implAll = fs.readdirSync(IMPL, { recursive: true })
    .filter((f) => String(f).endsWith('.swift'))
    .map((f) => read(path.join(IMPL, String(f))))
    .join('\n');

  const missing = [];
  for (const value of literals) {
    const expected = normalise(value);
    if (implAll.includes(expected)) continue;
    missing.push(expected);
  }
  return missing;
}

// ── report ────────────────────────────────────────────────────────────────

const only = process.argv[2];
const screens = only
  ? SCREENS.filter((s) => s.name.toLowerCase() === only.toLowerCase())
  : SCREENS;

if (!screens.length) {
  console.error(`No screen named "${only}". Known: ${SCREENS.map((s) => s.name).join(', ')}`);
  process.exit(2);
}

let missingTotal = 0;
console.log('uidiff — design → apps/Lumen\n');

for (const screen of screens) {
  const result = diffScreen(screen);
  const count = result.missing.length + result.missingChrome.length;
  missingTotal += count;
  const mark = count === 0 ? 'ok  ' : 'MISS';
  console.log(`${mark} ${result.screen.padEnd(12)} ${result.designCount} design strings · ${count} missing`);
  for (const item of result.missing) {
    console.log(`       MISSING     "${item.value}"${item.expected !== item.value ? ` (expected "${item.expected}")` : ''}`);
  }
  for (const item of result.missingChrome) {
    console.log(`       CHROME TEXT "${item.value}"${item.expected !== item.value ? ` (expected "${item.expected}")` : ''}`);
  }
  for (const value of result.waived) {
    console.log(`       waived      "${value}" — ${WAIVED.get(value)}`);
  }
}

if (!only) {
  const drift = diffTokens();
  console.log('');
  if (drift.length === 0) {
    console.log('ok   tokens       no drift from the design palette');
  } else {
    missingTotal += drift.length;
    console.log(`MISS tokens       ${drift.length} drifted`);
    for (const item of drift) {
      console.log(`       PROPERTIES  ${item.name}: design ${item.expected} · app ${item.actual}`);
    }
  }

  const canvas = canvasChrome();
  if (canvas.length === 0) {
    console.log('ok   canvas       every literal the mockup draws appears in the app');
  } else {
    missingTotal += canvas.length;
    console.log(`MISS canvas       ${canvas.length} literals absent from the app`);
    for (const value of canvas) console.log(`       CHROME TEXT "${value}"`);
  }
}

console.log('');
console.log(missingTotal === 0 ? 'missing: 0 — gate passed' : `missing: ${missingTotal} — GATE FAILED`);
process.exit(missingTotal === 0 ? 0 : 1);

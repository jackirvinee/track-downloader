import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import test from 'node:test';
import '../content-logic.js';

const source = await readFile(new URL('../content-script.js', import.meta.url), 'utf8');

// Real content-script behavior with its DOM/Chrome boundaries substituted.
// Live Chrome interaction is a separate acceptance gate.
function page({ url = 'https://soundcloud.com/kevin-9-1/despair-and-triumph',
  frame = 'https://soundcloud.com/n/kevin-9-1/despair-and-triumph?embedded=crossfade',
  heading = false, response = 'queued' } = {}) {
  const location = new URL(url);
  const buttons = new Map();
  const calls = [];
  const windowListeners = new Map();
  let siteKeyboardEvents = 0;
  let mutate;
  const anchor = { insertAdjacentElement(_position, element) { buttons.set(element.id, element); } };
  const frameElement = { ...anchor, getAttribute() { return frame; } };
  const context = vm.createContext({
    URL, location,
    TrackDownloaderContentLogic: globalThis.TrackDownloaderContentLogic,
    MutationObserver: class {
      constructor(callback) { mutate = callback; }
      observe() {}
    },
    document: {
      activeElement: null,
      title: 'Despair And Triumph by KevinMacLeod | SoundCloud',
      documentElement: {},
      querySelector(selector) {
        if (selector === 'iframe[title="SoundCloud"]') return frame ? frameElement : null;
        if (selector === 'h1.soundTitle__title' && heading) return { ...anchor, textContent: 'Despair And Triumph' };
        return null;
      },
      getElementById(id) { return buttons.get(id); },
      createElement() {
        return {
          classes: [],
          get classList() { return { add: name => this.classes.push(name) }; },
          setAttribute() {},
          addEventListener(_name, callback) { this.click = callback; },
          remove() { buttons.delete(this.id); },
        };
      },
    },
    window: { addEventListener(name, callback, capture) {
      if (!windowListeners.has(name)) windowListeners.set(name, []);
      windowListeners.get(name).push({ callback, capture });
    } },
    chrome: { runtime: { sendMessage: async message => {
      calls.push(message);
      return { status: response };
    } } },
  });
  vm.runInContext(source, context);
  return {
    button: () => buttons.get('track-downloader-queue-button'), calls,
    siteKeyboardEvents: () => siteKeyboardEvents,
    async key(type, { key = ' ', code = 'Space', repeat = false, focusButton = true } = {}) {
      context.document.activeElement = focusButton ? buttons.get('track-downloader-queue-button') : {};
      let stopped = false;
      const event = { key, code, repeat,
        preventDefault() {}, stopImmediatePropagation() { stopped = true; } };
      for (const { callback, capture } of windowListeners.get(type) ?? []) {
        if (type !== 'blur') assert.equal(capture, true);
        callback(event);
        if (stopped) break;
      }
      if (!stopped && type !== 'blur') siteKeyboardEvents++;
      await new Promise(resolve => setImmediate(resolve));
    },
    navigate(url) { location.href = url; mutate(); },
  };
}

test('SoundCloud iframe layout creates one top-level floating control and queues explicitly', async () => {
  const p = page();
  assert.deepEqual(p.button().classes, ['track-downloader-floating-queue']);
  assert.equal(p.calls.length, 0);
  await p.button().click();
  assert.equal(p.button().textContent, 'Queued ✓');
  assert.equal(p.button().disabled, true);
  assert.equal(p.calls[0].metadata.platform, 'soundcloud');
  p.navigate('https://soundcloud.com/kevin-9-1/despair-and-triumph');
  assert.equal(p.calls.length, 1);
});

test('page reload can show the native duplicate response', async () => {
  const p = page({ response: 'duplicate' });
  await p.button().click();
  assert.equal(p.button().textContent, 'Already queued');
});

test('navigation to a non-track route removes the control without another message', () => {
  const p = page();
  p.navigate('https://soundcloud.com/discover');
  assert.equal(p.button(), undefined);
  assert.equal(p.calls.length, 0);
});

test('unrelated or cross-origin frames never get the fallback control', () => {
  for (const frame of ['https://example.com/n/kevin-9-1/despair-and-triumph',
    'https://soundcloud.com/n/another/track', null]) {
    assert.equal(page({ frame }).button(), undefined);
  }
});

test('legacy SoundCloud header keeps the inline control', () => {
  assert.deepEqual(page({ heading: true, frame: null }).button().classes, []);
});

test('failed native handoff keeps the control available for retry', async () => {
  const p = page({ response: 'rejected' });
  await p.button().click();
  assert.equal(p.button().textContent, 'Couldn’t queue—try again');
  assert.equal(p.button().disabled, false);
});

test('focused Space queues once without triggering the site player on keydown or keyup', async () => {
  const p = page();
  await p.key('keydown');
  await p.key('keyup', { focusButton: false });
  assert.equal(p.calls.length, 1);
  assert.equal(p.button().textContent, 'Queued ✓');
  assert.equal(p.siteKeyboardEvents(), 0);
});

test('held Space remains owned after the disabled button loses focus', async () => {
  const p = page();
  await p.key('keydown');
  await p.key('keydown', { repeat: true, focusButton: false });
  await p.key('keyup', { focusButton: false });
  assert.equal(p.calls.length, 1);
  assert.equal(p.siteKeyboardEvents(), 0);
});

test('other controls and keys keep their normal page shortcuts', async () => {
  const p = page();
  await p.key('keydown', { focusButton: false });
  await p.key('keyup', { focusButton: false });
  await p.key('keydown', { key: 'Enter', code: 'Enter' });
  assert.equal(p.calls.length, 0);
  assert.equal(p.siteKeyboardEvents(), 3);
});

test('window blur releases an unfinished owned Space press', async () => {
  const p = page();
  await p.key('keydown');
  await p.key('blur');
  await p.key('keydown', { focusButton: false });
  assert.equal(p.calls.length, 1);
  assert.equal(p.siteKeyboardEvents(), 1);
});

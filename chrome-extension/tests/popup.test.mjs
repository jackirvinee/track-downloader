import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import test from 'node:test';
import { createRequest, nativeHostName } from '../request.js';

// Exercise the real popup handler with Chrome and DOM boundaries substituted.
// These checks do not claim rendered Chrome or native-host integration proof.
async function popup({ url = 'https://www.youtube.com/watch?v=test', response, nativeError, queryError } = {}) {
  const elements = Object.fromEntries(['#send', '#detail', '#status'].map(id => [id, {
    textContent: '', disabled: false,
    addEventListener(_event, handler) { this.click = handler; },
  }]));
  const calls = [];
  const context = vm.createContext({
    createRequest, nativeHostName, Error,
    document: { querySelector: id => elements[id] },
    chrome: {
      tabs: { query: async () => {
        if (queryError) throw new Error(queryError);
        return [{ url, title: 'Test track' }];
      } },
      runtime: { sendNativeMessage: async (host, request) => {
        calls.push({ host, request });
        assert.equal(elements['#send'].disabled, true);
        if (nativeError) throw new Error(nativeError);
        return response;
      } },
    },
  });
  const source = (await readFile(new URL('../popup.js', import.meta.url), 'utf8'))
    .replace(/^import .*;\n/u, '');
  vm.runInContext(source, context);
  await elements['#send'].click();
  return { elements, calls };
}

for (const [status, message] of [
  ['queued', 'Queued in Track Downloader.'],
  ['duplicate', 'That page is already waiting in Track Downloader.'],
  ['full', 'Queue full—open Track Downloader to review.'],
  ['rejected', 'Track Downloader could not accept this page. Try opening the app first.'],
]) {
  test(`popup handles ${status} and enables another explicit attempt`, async () => {
    const { elements, calls } = await popup({ response: { status } });
    assert.equal(elements['#status'].textContent, message);
    assert.equal(elements['#send'].disabled, false);
    assert.equal(calls.length, 1);
    assert.equal(calls[0].host, nativeHostName);
    assert.equal(calls[0].request.url, 'https://www.youtube.com/watch?v=test');
    assert.equal(calls[0].request.metadata.title, 'Test track');
  });
}

test('unsupported page never contacts native host', async () => {
  const { elements, calls } = await popup({ url: 'https://example.com/' });
  assert.match(elements['#status'].textContent, /supported/);
  assert.equal(calls.length, 0);
  assert.equal(elements['#send'].disabled, false);
});

test('artist, discovery and non-video pages explain the required item without contacting the host', async () => {
  for (const url of ['https://soundcloud.com/kevin-9-1', 'https://soundcloud.com/discover',
    'https://soundcloud.com/search/sounds', 'https://www.youtube.com/',
    'https://www.youtube.com/watch', 'https://www.youtube.com/playlist?list=test']) {
    const { elements, calls } = await popup({ url });
    assert.equal(elements['#status'].textContent, 'Open an individual YouTube video or SoundCloud track first.');
    assert.equal(calls.length, 0);
    assert.equal(elements['#send'].disabled, false);
  }
});

for (const boundary of ['nativeError', 'queryError']) {
  test(`popup reports ${boundary} and restores retry`, async () => {
    const { elements } = await popup({ [boundary]: 'Test connection error' });
    assert.equal(elements['#status'].textContent, 'Test connection error');
    assert.equal(elements['#send'].disabled, false);
  });
}

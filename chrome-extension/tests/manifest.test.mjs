import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const extensionRoot = new URL("..", import.meta.url);

test("manifest grants only the narrow Chrome companion permissions", async () => {
  const manifest = JSON.parse(await readFile(new URL("manifest.json", extensionRoot), "utf8"));

  assert.equal(manifest.manifest_version, 3);
  assert.deepEqual(manifest.permissions.sort(), ["activeTab", "nativeMessaging"]);
  assert.deepEqual(manifest.host_permissions.sort(), [
    "https://*.soundcloud.com/*",
    "https://*.youtube.com/*",
    "https://soundcloud.com/*",
    "https://youtu.be/*",
  ]);
  assert.equal(manifest.key.length > 100, true);
  assert.equal(manifest.action.default_popup, "popup.html");
  assert.deepEqual(manifest.background, {
    service_worker: "service-worker.js",
    type: "module",
  });
  assert.deepEqual(manifest.content_scripts, [{
    matches: [
      "https://*.youtube.com/*",
      "https://soundcloud.com/*",
      "https://*.soundcloud.com/*",
    ],
    js: ["content-logic.js", "content-script.js"],
    css: ["content-script.css"],
    run_at: "document_idle",
  }]);
});

test("request builder canonicalizes a supported page and refuses an unrelated page", async () => {
  const { createRequest, nativeHostName } = await import(new URL("request.js", extensionRoot));
  const request = createRequest(
    "https://www.youtube.com/watch?v=example#comments",
    { title: "  Night   Drive ", creator: " Example Artist ", platform: "youtube" },
    1_723_651_200_000,
    "01234567-89ab-cdef-0123-456789abcdef"
  );

  assert.equal(nativeHostName, "com.jackirvine.trackdownloader.chrome");
  assert.deepEqual(request, {
    version: 2,
    requestId: "01234567-89ab-cdef-0123-456789abcdef",
    action: "enqueueDownload",
    url: "https://www.youtube.com/watch?v=example",
    issuedAtMs: 1_723_651_200_000,
    metadata: {
      title: "Night Drive",
      creator: "Example Artist",
      platform: "youtube",
    },
  });
  assert.throws(() => createRequest("https://example.com/track"), /supported/);
  assert.throws(
    () => createRequest("https://youtu.be/example", { title: "x".repeat(161), creator: null, platform: "youtube" }),
    /title/
  );
});

test("page logic limits injection to one supported item page and extracts bounded display text", async () => {
  await import(new URL("content-logic.js", extensionRoot));
  const { pageDetails } = globalThis.TrackDownloaderContentLogic;

  assert.deepEqual(pageDetails({
    url: "https://www.youtube.com/watch?v=example",
    title: "Night Drive - YouTube",
    heading: "Night Drive",
    creator: "Example Artist",
  }), {
    url: "https://www.youtube.com/watch?v=example",
    title: "Night Drive",
    creator: "Example Artist",
    platform: "youtube",
  });
  assert.equal(pageDetails({ url: "https://www.youtube.com/results?search_query=night" }), null);
  assert.equal(pageDetails({ url: "https://soundcloud.com/discover" }), null);
  assert.deepEqual(pageDetails({
    url: "https://soundcloud.com/example/night-drive",
    heading: "Night Drive",
    creator: "Example Artist",
  })?.platform, "soundcloud");
});

test("service worker rebuilds the native request from the verified sender tab", async () => {
  const { queuePage } = await import(new URL("service-worker.js", extensionRoot));
  let sentRequest;
  const response = await queuePage(
    {
      type: "queue-current-page",
      metadata: { title: "Night Drive", creator: "Example Artist", platform: "youtube" },
    },
    { tab: { url: "https://www.youtube.com/watch?v=verified#comments" } },
    async (_host, request) => {
      sentRequest = request;
      return { status: "queued" };
    }
  );

  assert.equal(response.status, "queued");
  assert.equal(sentRequest.url, "https://www.youtube.com/watch?v=verified");
  assert.equal(sentRequest.version, 2);
  assert.deepEqual(
    await queuePage({ type: "queue-current-page", metadata: {} }, {}, async () => ({ status: "queued" })),
    { status: "rejected" }
  );
});

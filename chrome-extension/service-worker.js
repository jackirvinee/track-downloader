import { createRequest, nativeHostName } from "./request.js";

export async function queuePage(message, sender, sendNativeMessage) {
  if (message?.type !== "queue-current-page" || typeof sender.tab?.url !== "string") {
    return { status: "rejected" };
  }

  try {
    const request = createRequest(sender.tab.url, message.metadata ?? {});
    return await sendNativeMessage(nativeHostName, request) ?? { status: "rejected" };
  } catch (error) {
    return {
      status: "rejected",
      message: error instanceof Error ? error.message : "Track Downloader could not accept this page.",
    };
  }
}

if (globalThis.chrome?.runtime?.onMessage) {
  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    queuePage(message, sender, chrome.runtime.sendNativeMessage.bind(chrome.runtime))
      .then(sendResponse);
    return true;
  });
}

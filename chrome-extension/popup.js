import { createRequest, nativeHostName } from "./request.js";

const sendButton = document.querySelector("#send");
const detail = document.querySelector("#detail");
const status = document.querySelector("#status");

function setStatus(message) {
  status.textContent = message;
}

sendButton.addEventListener("click", async () => {
  sendButton.disabled = true;
  setStatus("");
  try {
    const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
    const request = createRequest(tab?.url ?? "", { title: tab?.title ?? null });
    const response = await chrome.runtime.sendNativeMessage(nativeHostName, request);
    if (response?.status === "queued") {
      detail.textContent = "The page is waiting in your persistent queue.";
      setStatus("Queued in Track Downloader.");
    } else if (response?.status === "duplicate") {
      setStatus("That page is already waiting in Track Downloader.");
    } else if (response?.status === "full") {
      setStatus("Queue full—open Track Downloader to review.");
    } else {
      setStatus("Track Downloader could not accept this page. Try opening the app first.");
    }
  } catch (error) {
    setStatus(error instanceof Error ? error.message : "Chrome could not contact Track Downloader.");
  } finally {
    sendButton.disabled = false;
  }
});

(function installQueueButton() {
  const buttonID = "track-downloader-queue-button";
  let ownsSpacePress = false;

  // Capture before page shortcuts: SoundCloud uses Space for its player even
  // when our button has focus. Keep the whole owned press out of the page.
  window.addEventListener("keydown", (event) => {
    if (event.key !== " " && event.code !== "Space") return;
    const button = document.getElementById(buttonID);
    if (!ownsSpacePress && (!button || document.activeElement !== button)) return;
    ownsSpacePress = true;
    event.preventDefault();
    event.stopImmediatePropagation();
    if (!event.repeat && button && !button.disabled) button.click();
  }, true);
  window.addEventListener("keyup", (event) => {
    if (!ownsSpacePress || (event.key !== " " && event.code !== "Space")) return;
    ownsSpacePress = false;
    event.preventDefault();
    event.stopImmediatePropagation();
  }, true);
  window.addEventListener("blur", () => { ownsSpacePress = false; });
  let currentURL = location.href;

  function queryText(selectors) {
    for (const selector of selectors) {
      const value = document.querySelector(selector)?.textContent;
      if (value?.trim()) return value;
    }
    return null;
  }

  function readPage() {
    const youtube = location.hostname.endsWith("youtube.com");
    return TrackDownloaderContentLogic.pageDetails({
      url: location.href,
      title: document.title,
      heading: queryText(youtube
        ? ["h1.ytd-watch-metadata", "#title h1"]
        : ["h1[data-testid='sound-title']", "h1.soundTitle__title", ".soundTitle__title"]),
      creator: queryText(youtube
        ? ["#owner #channel-name", "ytd-video-owner-renderer #channel-name"]
        : ["a.soundTitle__username", "[data-testid='creator-link']", ".soundTitle__username"]),
    });
  }

  function findAnchor() {
    const youtube = location.hostname.endsWith("youtube.com");
    const selectors = youtube
      ? ["h1.ytd-watch-metadata", "#title h1"]
      : ["h1[data-testid='sound-title']", "h1.soundTitle__title", ".soundTitle__title"];
    const heading = selectors.map((selector) => document.querySelector(selector)).find(Boolean);
    if (heading) return { element: heading, floating: false };

    // SoundCloud's newer layout renders the track in an iframe. Keep the
    // control in the permitted top-level document without accessing frames
    // or expanding the extension's permissions.
    if (!youtube) {
      const frame = document.querySelector('iframe[title="SoundCloud"]');
      try {
        const frameURL = new URL(frame?.getAttribute("src"), location.href);
        if (frame && frameURL.origin === location.origin
          && frameURL.pathname === `/n${location.pathname.replace(/\/$/u, "")}`) {
          return { element: frame, floating: true };
        }
      } catch {}
    }
    return null;
  }

  function removeButton() {
    document.getElementById(buttonID)?.remove();
  }

  function ensureButton() {
    const details = readPage();
    const anchor = findAnchor();
    if (!details || !anchor) {
      removeButton();
      return;
    }
    if (document.getElementById(buttonID)) return;

    const button = document.createElement("button");
    button.id = buttonID;
    button.type = "button";
    if (anchor.floating) button.classList.add("track-downloader-floating-queue");
    button.textContent = "Queue in Track Downloader";
    button.setAttribute("aria-label", "Queue this track in Track Downloader");
    button.addEventListener("click", async () => {
      const currentDetails = readPage();
      if (!currentDetails) {
        button.textContent = "Open an individual track first";
        return;
      }
      button.disabled = true;
      button.textContent = "Queuing…";
      const response = await chrome.runtime.sendMessage({
        type: "queue-current-page",
        metadata: {
          title: currentDetails.title,
          creator: currentDetails.creator,
          platform: currentDetails.platform,
        },
      }).catch(() => ({ status: "rejected" }));

      if (response?.status === "queued") {
        button.textContent = "Queued ✓";
      } else if (response?.status === "duplicate") {
        button.textContent = "Already queued";
      } else if (response?.status === "full") {
        button.textContent = "Queue full—open Track Downloader to review";
      } else {
        button.textContent = "Couldn’t queue—try again";
        button.disabled = false;
      }
    });
    anchor.element.insertAdjacentElement("afterend", button);
  }

  const observer = new MutationObserver(() => {
    if (location.href !== currentURL) {
      currentURL = location.href;
      removeButton();
    }
    ensureButton();
  });
  observer.observe(document.documentElement, { childList: true, subtree: true });
  ensureButton();
})();

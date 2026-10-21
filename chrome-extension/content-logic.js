(function installContentLogic(root) {
  const soundCloudReservedRoutes = new Set([
    "charts", "discover", "jobs", "library", "pages", "search", "settings",
    "stations", "stream", "terms", "upload", "you",
  ]);

  function normalizeText(value, maximumLength) {
    if (typeof value !== "string") return null;
    const normalized = value.trim().replace(/\s+/gu, " ");
    if (!normalized || normalized.length > maximumLength || /[\u0000-\u001f\u007f]/u.test(normalized)) return null;
    return normalized;
  }

  function pageDetails(input) {
    let parsed;
    try {
      parsed = new URL(input.url);
    } catch {
      return null;
    }
    if (parsed.protocol !== "https:") return null;

    let platform;
    const host = parsed.hostname.toLowerCase();
    if ((host === "youtube.com" || host.endsWith(".youtube.com"))
      && parsed.pathname === "/watch" && parsed.searchParams.get("v")) {
      platform = "youtube";
      parsed.search = `?v=${encodeURIComponent(parsed.searchParams.get("v"))}`;
    } else if (host === "soundcloud.com" || host.endsWith(".soundcloud.com")) {
      const parts = parsed.pathname.split("/").filter(Boolean);
      if (parts.length !== 2 || soundCloudReservedRoutes.has(parts[0].toLowerCase())) return null;
      platform = "soundcloud";
      parsed.search = "";
      parsed.pathname = `/${parts.join("/")}`;
    } else {
      return null;
    }
    parsed.hash = "";

    const fallbackTitle = typeof input.title === "string"
      ? input.title.replace(/\s+(?:-|\|)\s+(?:YouTube|SoundCloud)$/iu, "")
      : null;
    return {
      url: parsed.toString(),
      title: normalizeText(input.heading, 160) ?? normalizeText(fallbackTitle, 160),
      creator: normalizeText(input.creator, 120),
      platform,
    };
  }

  root.TrackDownloaderContentLogic = { pageDetails };
})(globalThis);

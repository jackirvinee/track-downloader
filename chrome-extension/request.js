export const nativeHostName = "com.jackirvine.trackdownloader.chrome";

function isSupportedHost(host) {
  return host === "youtu.be" ||
    host.endsWith(".youtu.be") ||
    host === "youtube.com" ||
    host.endsWith(".youtube.com") ||
    host === "soundcloud.com" ||
    host.endsWith(".soundcloud.com");
}

function platformForHost(host) {
  if (host === "youtu.be" || host.endsWith(".youtu.be") || host === "youtube.com" || host.endsWith(".youtube.com")) {
    return "youtube";
  }
  if (host === "soundcloud.com" || host.endsWith(".soundcloud.com")) {
    return "soundcloud";
  }
  return null;
}

function isIndividualItemURL(parsed, platform) {
  const parts = parsed.pathname.split("/").filter(Boolean);
  if (platform === "youtube") {
    if (parsed.hostname === "youtu.be" || parsed.hostname.endsWith(".youtu.be")) {
      return parts.length === 1;
    }
    return parsed.pathname === "/watch" && Boolean(parsed.searchParams.get("v"));
  }
  const reserved = new Set([
    "charts", "discover", "jobs", "library", "pages", "search", "settings",
    "stations", "stream", "terms", "upload", "you",
  ]);
  return parts.length === 2 && !reserved.has(parts[0].toLowerCase());
}

function boundedText(value, maximumLength, fieldName) {
  if (value == null || value === "") return null;
  if (typeof value !== "string" || value.length > maximumLength || /[\u0000-\u001f\u007f]/u.test(value)) {
    throw new Error(`Page ${fieldName} is not safe to queue.`);
  }
  const normalized = value.trim().replace(/\s+/gu, " ");
  return normalized || null;
}

export function createRequest(url, metadata = {}, issuedAtMs = Date.now(), requestId = crypto.randomUUID()) {
  const parsed = new URL(url);
  const platform = platformForHost(parsed.hostname.toLowerCase());
  if (
    parsed.protocol !== "https:" ||
    parsed.username ||
    parsed.password ||
    !isSupportedHost(parsed.hostname.toLowerCase()) ||
    !platform
  ) {
    throw new Error("Open a supported YouTube or SoundCloud page first.");
  }
  if (!isIndividualItemURL(parsed, platform)) {
    throw new Error("Open an individual YouTube video or SoundCloud track first.");
  }

  parsed.hash = "";
  if (platform === "youtube" && parsed.hostname.endsWith("youtube.com") && parsed.pathname === "/watch") {
    const videoId = parsed.searchParams.get("v");
    parsed.search = videoId ? `?v=${encodeURIComponent(videoId)}` : "";
  } else if (platform === "soundcloud") {
    parsed.search = "";
    parsed.pathname = parsed.pathname.replace(/\/$/u, "");
  }
  const declaredPlatform = metadata.platform ?? platform;
  if (declaredPlatform !== platform) {
    throw new Error("Page platform does not match its URL.");
  }
  return {
    version: 2,
    requestId,
    action: "enqueueDownload",
    url: parsed.toString(),
    issuedAtMs,
    metadata: {
      title: boundedText(metadata.title, 160, "title"),
      creator: boundedText(metadata.creator, 120, "creator"),
      platform,
    },
  };
}

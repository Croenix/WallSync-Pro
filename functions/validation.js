const KEY_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;
const WALLPAPER_TYPES = new Set(["static", "animated", "video"]);

function classifyResolution(width, height) {
  const longSide = Math.max(width, height);
  const shortSide = Math.min(width, height);
  for (const [targetLong, targetShort, label] of [
    [1280, 720, "HD"],
    [1920, 1080, "Full HD"],
    [2048, 1080, "2K"],
    [2560, 1440, "2K"],
    [3840, 2160, "4K"],
    [4096, 2160, "4K"],
    [7680, 4320, "8K"],
    [15360, 8640, "16K"],
  ]) {
    const longRatio = longSide / targetLong;
    const shortRatio = shortSide / targetShort;
    if (Math.abs(longRatio - shortRatio) <= 0.03 &&
        Math.abs(longRatio - 1) <= 0.05 &&
        Math.abs(shortRatio - 1) <= 0.05) {
      return label;
    }
  }
  return "Other";
}

class ValidationError extends Error {
  constructor(message) {
    super(message);
    this.status = 400;
  }
}

function requiredText(value, field, maxLength) {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new ValidationError(`${field} is required.`);
  }
  const text = value.trim();
  if (text.length > maxLength) {
    throw new ValidationError(`${field} must be ${maxLength} characters or fewer.`);
  }
  return text;
}

function optionalText(value, field, maxLength) {
  if (value == null || value === "") return null;
  if (typeof value !== "string" || value.length > maxLength) {
    throw new ValidationError(`${field} must be a string of ${maxLength} characters or fewer.`);
  }
  return value.trim() || null;
}

function validateWallpaper(item, cloudName) {
  if (item == null || typeof item !== "object" || Array.isArray(item)) {
    throw new ValidationError("Each wallpaper must be an object.");
  }

  const id = requiredText(item.id, "id", 128);
  if (!KEY_PATTERN.test(id)) {
    throw new ValidationError("id may contain only letters, numbers, underscores, and hyphens.");
  }

  const type = requiredText(item.type, "type", 16);
  if (!WALLPAPER_TYPES.has(type)) {
    throw new ValidationError("type must be static, animated, or video.");
  }

  const url = requiredText(item.url, "url", 2048);
  let parsedUrl;
  try {
    parsedUrl = new URL(url);
  } catch {
    throw new ValidationError("url must be a valid URL.");
  }

  if (parsedUrl.protocol !== "https:" && parsedUrl.protocol !== "http:") {
    throw new ValidationError("url must use https or http.");
  }

  const isCloudinary = parsedUrl.hostname === "res.cloudinary.com";
  if (isCloudinary) {
    const isCloudinaryMatch =
      parsedUrl.pathname.startsWith(`/${cloudName}/image/upload/`) ||
      parsedUrl.pathname.startsWith(`/${cloudName}/video/upload/`);
    if (!isCloudinaryMatch) {
      throw new ValidationError("url must point to an asset in the configured Cloudinary account.");
    }
  } else if (type !== "video") {
    throw new ValidationError("url must point to an image in the configured Cloudinary account.");
  }

  let thumbnailUrl = optionalText(item.thumbnailUrl, "thumbnailUrl", 2048);
  if (thumbnailUrl) {
    try {
      const parsedThumb = new URL(thumbnailUrl);
      if (parsedThumb.protocol !== "https:" && parsedThumb.protocol !== "http:") {
        throw new ValidationError("thumbnailUrl must use https or http.");
      }
    } catch {
      throw new ValidationError("thumbnailUrl must be a valid URL.");
    }
  }

  let tags = null;
  if (item.tags != null) {
    if (!Array.isArray(item.tags) || item.tags.length > 30) {
      throw new ValidationError("tags must be an array containing at most 30 entries.");
    }
    tags = item.tags.map((tag) => requiredText(tag, "tag", 50));
  }

  return {
    id,
    wallpaperId: id,
    name: requiredText(item.name, "name", 160),
    category: requiredText(item.category, "category", 80),
    type,
    url,
    ...(thumbnailUrl ? { thumbnailUrl } : {}),
    description: optionalText(item.description, "description", 2000),
    tags,
    ...(Number.isSafeInteger(item.width) && item.width > 0
      ? { width: item.width }
      : {}),
    ...(Number.isSafeInteger(item.height) && item.height > 0
      ? { height: item.height }
      : {}),
    ...(Number.isSafeInteger(item.width) &&
    item.width > 0 &&
    Number.isSafeInteger(item.height) &&
    item.height > 0
      ? {
          resolutionLabel:
            classifyResolution(item.width, item.height),
          resolutionSource:
            typeof item.resolutionSource === "string" &&
            item.resolutionSource.length <= 40
              ? item.resolutionSource
              : "admin-upload",
          resolutionVerified: item.resolutionVerified === true,
        }
      : {
          width: 0,
          height: 0,
          resolutionLabel: "Resolution unavailable",
          resolutionSource: "unavailable",
          resolutionVerified: false,
        }),
  };
}

function validateWallpapers(items, cloudName) {
  if (!Array.isArray(items) || items.length === 0 || items.length > 100) {
    throw new ValidationError("items must contain between 1 and 100 wallpapers.");
  }

  const validated = items.map((item) => validateWallpaper(item, cloudName));
  const ids = new Set();
  for (const item of validated) {
    if (ids.has(item.id)) {
      throw new ValidationError("Wallpaper IDs must be unique in a request.");
    }
    ids.add(item.id);
  }
  return validated;
}

module.exports = { validateWallpapers, classifyResolution };

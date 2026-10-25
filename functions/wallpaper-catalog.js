const { randomUUID } = require("crypto");

const WALLPAPER_ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;

function migrateWallpaperCatalog(current) {
  if (!current || typeof current !== "object") {
    return { catalog: current, migrated: 0, total: 0, changed: false };
  }

  const isArray = Array.isArray(current);
  const entries = isArray
    ? current.map((item, index) => [String(index), item])
    : Object.entries(current);
  const catalog = Object.create(null);
  const usedIds = new Set();
  let migrated = 0;

  for (const [key, value] of entries) {
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      catalog[key] = value;
      usedIds.add(key);
      continue;
    }

    let id = isArray ? value.wallpaperId || value.id || "" : key;
    if (typeof id !== "string" || !WALLPAPER_ID_PATTERN.test(id) ||
        usedIds.has(id)) {
      id = randomUUID();
      while (usedIds.has(id)) id = randomUUID();
    }
    usedIds.add(id);

    if (id !== key || value.id !== id || value.wallpaperId !== id) {
      migrated++;
    }
    catalog[id] = {
      ...value,
      id,
      wallpaperId: id,
      width: Number.isSafeInteger(value.width) && value.width > 0 ? value.width : 0,
      height: Number.isSafeInteger(value.height) && value.height > 0 ? value.height : 0,
      resolutionLabel:
        typeof value.resolutionLabel === "string"
          ? value.resolutionLabel
          : "Resolution unavailable",
      resolutionSource:
        typeof value.resolutionSource === "string"
          ? value.resolutionSource
          : "unavailable",
      resolutionVerified: value.resolutionVerified === true,
    };
  }

  return {
    catalog,
    migrated,
    total: entries.length,
    changed: isArray || migrated > 0,
  };
}

module.exports = { migrateWallpaperCatalog };

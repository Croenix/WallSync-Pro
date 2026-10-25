const test = require("node:test");
const assert = require("node:assert/strict");
const { migrateWallpaperCatalog } = require("../wallpaper-catalog");

test("keeps canonical catalog IDs and preserves existing metadata", () => {
  const existing = {
    stable_id: {
      id: "stable_id",
      wallpaperId: "stable_id",
      url: "https://example.test/wallpaper.png",
      width: 1920,
      height: 1080,
      resolutionLabel: "Full HD",
      resolutionSource: "original-image",
      resolutionVerified: true,
    },
    malformed: "preserve",
  };

  const result = migrateWallpaperCatalog(existing);

  assert.equal(result.changed, false);
  assert.equal(result.migrated, 0);
  assert.equal(result.catalog.stable_id.url, existing.stable_id.url);
  assert.equal(result.catalog.malformed, "preserve");
});

test("converts arrays to unique IDs without dropping malformed entries", () => {
  const result = migrateWallpaperCatalog([
    { id: "wallpaper-1", url: "https://example.test/one.png" },
    { id: "wallpaper-1", url: "https://example.test/two.png" },
    null,
  ]);

  assert.equal(result.changed, true);
  assert.equal(result.total, 3);
  assert.equal(result.catalog["wallpaper-1"].url, "https://example.test/one.png");
  assert.equal(result.catalog["2"], null);
  const ids = Object.keys(result.catalog).filter((id) => id !== "2");
  assert.equal(ids.length, 2);
  assert.equal(new Set(ids).size, ids.length);
  for (const id of ids) {
    assert.match(id, /^[A-Za-z0-9_-]{1,128}$/);
    assert.equal(result.catalog[id].id, id);
    assert.equal(result.catalog[id].wallpaperId, id);
  }
});

const test = require("node:test");
const assert = require("node:assert/strict");
const { validateWallpapers } = require("../validation");

const cloudName = "wallsync";
const validWallpaper = {
  id: "nebula_1",
  name: "Nebula",
  category: "Space",
  type: "static",
  url: "https://res.cloudinary.com/wallsync/image/upload/nebula.jpg",
};

test("accepts a valid wallpaper and normalizes optional fields", () => {
  assert.deepEqual(validateWallpapers([validWallpaper], cloudName), [{
    ...validWallpaper,
    wallpaperId: validWallpaper.id,
    description: null,
    tags: null,
    width: 0,
    height: 0,
    resolutionLabel: "Resolution unavailable",
    resolutionSource: "unavailable",
    resolutionVerified: false,
  }]);
});

test("preserves validated source resolution and stable wallpaper ID", () => {
  const [wallpaper] = validateWallpapers([{
    ...validWallpaper,
    id: "d4ab97cc-0c2c-4d3f-b31d-04524c9062d7",
    width: 2560,
    height: 1440,
    resolutionLabel: "2K",
    resolutionSource: "original-image",
    resolutionVerified: true,
  }], cloudName);
  assert.equal(wallpaper.wallpaperId, wallpaper.id);
  assert.equal(wallpaper.width, 2560);
  assert.equal(wallpaper.height, 1440);
  assert.equal(wallpaper.resolutionLabel, "2K");
  assert.equal(wallpaper.resolutionVerified, true);
});

test("rejects IDs that could address non-key paths", () => {
  assert.throws(
    () => validateWallpapers([{ ...validWallpaper, id: "../other" }], cloudName),
    (error) => error.status === 400 &&
      /letters, numbers, underscores, and hyphens/.test(error.message),
  );
});

test("rejects URLs outside the configured Cloudinary account", () => {
  assert.throws(
    () => validateWallpapers([{
      ...validWallpaper,
      url: "https://example.com/image.jpg",
    }], cloudName),
    /configured Cloudinary account/,
  );
});

test("rejects duplicate IDs and oversized batches", () => {
  assert.throws(
    () => validateWallpapers([validWallpaper, validWallpaper], cloudName),
    /unique/,
  );
  assert.throws(
    () => validateWallpapers(Array(101).fill(validWallpaper), cloudName),
    /between 1 and 100/,
  );
});

test("rejects malformed tags and unsupported wallpaper types", () => {
  assert.throws(
    () => validateWallpapers([{ ...validWallpaper, type: "hologram" }], cloudName),
    /type must be static, animated, or video/,
  );
  assert.throws(
    () => validateWallpapers([{ ...validWallpaper, tags: "not-an-array" }], cloudName),
    /tags must be an array/,
  );
});

test("accepts valid video wallpapers with Cloudinary or direct streaming URLs", () => {
  const cloudinaryVideo = {
    id: "neon_loop_1",
    name: "Neon Loop",
    category: "Cyberpunk",
    type: "video",
    url: "https://res.cloudinary.com/wallsync/video/upload/loop.mp4",
    thumbnailUrl: "https://res.cloudinary.com/wallsync/video/upload/loop.jpg",
  };
  const directVideo = {
    id: "aurora_stream_1",
    name: "Aurora Stream",
    category: "Nature",
    type: "video",
    url: "https://assets.mixkit.co/videos/123-720.mp4",
  };

  const validated = validateWallpapers([cloudinaryVideo, directVideo], cloudName);
  assert.equal(validated.length, 2);
  assert.equal(validated[0].type, "video");
  assert.equal(validated[0].thumbnailUrl, "https://res.cloudinary.com/wallsync/video/upload/loop.jpg");
  assert.equal(validated[1].type, "video");
  assert.equal(validated[1].url, "https://assets.mixkit.co/videos/123-720.mp4");
});

const { initializeApp } = require("firebase-admin/app");
const { getAuth } = require("firebase-admin/auth");
const { getDatabase, ServerValue } = require("firebase-admin/database");
const { defineSecret, defineString } = require("firebase-functions/params");
const { onRequest } = require("firebase-functions/v2/https");
const { validateWallpapers } = require("./validation");
const { migrateWallpaperCatalog } = require("./wallpaper-catalog");

const cloudinaryCloudName = defineString("CLOUDINARY_CLOUD_NAME");
const cloudinaryApiKey = defineSecret("CLOUDINARY_API_KEY");
const cloudinaryApiSecret = defineSecret("CLOUDINARY_API_SECRET");
const adminUids = defineString("ADMIN_UIDS");
const adminOrigins = defineString("ADMIN_ORIGINS", {
  default:
    "http://localhost:3000,http://127.0.0.1:3000,http://localhost:8000,http://127.0.0.1:8000,https://wallsync-mo6b.onrender.com",
});
const databaseUrl = defineString("FIREBASE_DATABASE_URL", {
  default: "https://wallsync-e043c-default-rtdb.firebaseio.com",
});

initializeApp({ databaseURL: databaseUrl.value() });

function isOriginAllowed(normalizedOrigin, allowedOrigins) {
  if (!normalizedOrigin) return true;
  if (allowedOrigins.has(normalizedOrigin)) return true;
  if (/^https:\/\/[a-z0-9-]+\.onrender\.com$/i.test(normalizedOrigin)) return true;
  return false;
}

function setCorsHeaders(req, res) {
  const origin = req.get("origin");
  const allowedOrigins = new Set(
    adminOrigins.value().split(",").map((value) => value.trim().replace(/\/+$/, "")).filter(Boolean),
  );

  const normalizedOrigin = origin ? origin.trim().replace(/\/+$/, "") : "";
  if (normalizedOrigin && !isOriginAllowed(normalizedOrigin, allowedOrigins)) return false;
  if (normalizedOrigin) {
    res.set("Access-Control-Allow-Origin", normalizedOrigin);
    res.set("Vary", "Origin");
    res.set("Access-Control-Allow-Headers", "Authorization, Content-Type");
    res.set("Access-Control-Allow-Methods", "GET, POST, PATCH, OPTIONS");
  }
  return true;
}

async function requireAdmin(req) {
  const authorization = req.get("authorization") || "";
  const match = authorization.match(/^Bearer\s+(.+)$/i);
  if (!match) {
    const error = new Error("Authentication is required.");
    error.status = 401;
    throw error;
  }

  let decodedToken;
  try {
    decodedToken = await getAuth().verifyIdToken(match[1]);
  } catch {
    const error = new Error("The sign-in session is invalid or expired.");
    error.status = 401;
    throw error;
  }

  const allowedUids = new Set(
    adminUids.value().split(",").map((value) => value.trim()).filter(Boolean),
  );
  if (!allowedUids.has(decodedToken.uid)) {
    const error = new Error("This account is not authorized to use the admin API.");
    error.status = 403;
    throw error;
  }
}

async function listCloudinaryImages() {
  const cloudName = cloudinaryCloudName.value();
  const credentials = Buffer.from(
    `${cloudinaryApiKey.value()}:${cloudinaryApiSecret.value()}`,
  ).toString("base64");
  const response = await fetch(
    `https://api.cloudinary.com/v1_1/${encodeURIComponent(cloudName)}/resources/search`,
    {
      method: "POST",
      headers: {
        Authorization: `Basic ${credentials}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        expression: "resource_type:image",
        max_results: 100,
        with_field: ["context", "tags"],
      }),
      signal: AbortSignal.timeout(15000),
    },
  );
  if (!response.ok) {
    throw new Error("Cloudinary could not complete the image search.");
  }
  return response.json();
}

async function listCloudinaryVideos() {
  const cloudName = cloudinaryCloudName.value();
  const credentials = Buffer.from(
    `${cloudinaryApiKey.value()}:${cloudinaryApiSecret.value()}`,
  ).toString("base64");
  const response = await fetch(
    `https://api.cloudinary.com/v1_1/${encodeURIComponent(cloudName)}/resources/search`,
    {
      method: "POST",
      headers: {
        Authorization: `Basic ${credentials}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        expression: "resource_type:video",
        max_results: 100,
        with_field: ["context", "tags"],
      }),
      signal: AbortSignal.timeout(15000),
    },
  );
  if (!response.ok) {
    throw new Error("Cloudinary could not complete the video search.");
  }
  return response.json();
}

async function signCloudinaryUpload(folder) {
  const crypto = require("crypto");
  const timestamp = Math.round(new Date().getTime() / 1000);
  const cloudName = cloudinaryCloudName.value();
  const apiKey = cloudinaryApiKey.value();
  const apiSecret = cloudinaryApiSecret.value();

  const params = [];
  if (folder) params.push(`folder=${folder}`);
  params.push(`timestamp=${timestamp}`);
  const paramsToSign = params.sort().join("&");
  const signature = crypto
    .createHash("sha1")
    .update(paramsToSign + apiSecret)
    .digest("hex");

  return {
    signature,
    timestamp,
    apiKey,
    cloudName,
    folder: folder || undefined,
  };
}

async function saveWallpapers(items) {
  const cloudName = cloudinaryCloudName.value();
  const wallpapers = validateWallpapers(items, cloudName);
  const root = getDatabase().ref("wallpapers");
  for (const wallpaper of wallpapers) {
    let conflict = false;
    const record = {
      ...wallpaper,
      id: wallpaper.id,
      wallpaperId: wallpaper.id,
      thumbnailUrl: wallpaper.thumbnailUrl || null,
      description: wallpaper.description || null,
      tags: wallpaper.tags && wallpaper.tags.length > 0 ? wallpaper.tags : null,
    };
    const result = await root.child(wallpaper.id).transaction((current) => {
      if (current && current.url !== wallpaper.url) {
        conflict = true;
        return;
      }
      return record;
    }, undefined, false);
    if (!result.committed || conflict) {
      const error = new Error(
        `Wallpaper ID "${wallpaper.id}" is already assigned to a different source.`,
      );
      error.status = 409;
      throw error;
    }
  }
  return wallpapers.length;
}

async function migrateWallpaperIds() {
  const reference = getDatabase().ref("wallpapers");
  let migration;
  const result = await reference.transaction((current) => {
    migration = migrateWallpaperCatalog(current);
    return migration.changed ? migration.catalog : undefined;
  }, undefined, false);
  if (!migration) return { migrated: 0, total: 0 };
  return {
    migrated: migration.migrated,
    total: result.snapshot.exists() ? migration.total : 0,
  };
}

function validateWallpaperReportUpdate(body) {
  const allowedStatuses = new Set(["pending", "reviewing", "resolved", "rejected"]);
  if (!body || !allowedStatuses.has(body.status)) {
    const error = new Error("status must be pending, reviewing, resolved, or rejected.");
    error.status = 400;
    throw error;
  }
  if (body.adminNotes !== undefined &&
      (typeof body.adminNotes !== "string" || body.adminNotes.length > 2000)) {
    const error = new Error("adminNotes must be a string of 2,000 characters or fewer.");
    error.status = 400;
    throw error;
  }
  return {
    status: body.status,
    adminNotes: (body.adminNotes || "").trim(),
    updatedAt: ServerValue.TIMESTAMP,
  };
}

exports.adminApi = onRequest(
  {
    region: "us-central1",
    secrets: [cloudinaryApiKey, cloudinaryApiSecret],
    maxInstances: 5,
  },
  async (req, res) => {
    if (!setCorsHeaders(req, res)) {
      res.status(403).json({ error: "This origin is not allowed." });
      return;
    }
    if (req.method === "OPTIONS") {
      res.status(204).send("");
      return;
    }

    try {
      await requireAdmin(req);
      if (req.path === "/images" && req.method === "GET") {
        res.json(await listCloudinaryImages());
        return;
      }
      if (req.path === "/videos" && req.method === "GET") {
        res.json(await listCloudinaryVideos());
        return;
      }
      if (req.path === "/sign-upload" && req.method === "POST") {
        const folder = req.body && req.body.folder;
        res.json(await signCloudinaryUpload(folder));
        return;
      }
      if (req.path === "/wallpapers" && req.method === "POST") {
        const count = await saveWallpapers(req.body && req.body.items);
        res.json({ uploaded: count });
        return;
      }
      if (req.path === "/wallpapers/migrate" && req.method === "POST") {
        res.json(await migrateWallpaperIds());
        return;
      }
      if ((req.path === "/wallpaper-reports" || req.path === "/wallpaper_reports_pro" || req.path === "/wallpaper-reports-pro") && req.method === "GET") {
        const rootPath = (req.path === "/wallpaper_reports_pro" || req.path === "/wallpaper-reports-pro")
          ? "wallpaper_reports_pro"
          : "wallpaperReports";
        const snapshot = await getDatabase().ref(rootPath).once("value");
        res.json(snapshot.val() || {});
        return;
      }
      const reportMatch =
        /^\/(wallpaper-reports|reports|wallpaper_reports_pro|wallpaper-reports-pro)\/([A-Za-z0-9_-]{1,128})$/.exec(req.path);
      if (reportMatch && req.method === "PATCH") {
        const reportPath = reportMatch[1] === "reports"
          ? "reports"
          : (reportMatch[1] === "wallpaper_reports_pro" || reportMatch[1] === "wallpaper-reports-pro")
            ? "wallpaper_reports_pro"
            : "wallpaperReports";
        const reportRef = getDatabase().ref(`${reportPath}/${reportMatch[2]}`);
        const existing = await reportRef.once("value");
        if (!existing.exists()) {
          res.status(404).json({ error: "Wallpaper report not found." });
          return;
        }
        await reportRef.update(validateWallpaperReportUpdate(req.body));
        res.json({ updated: true });
        return;
      }
      res.status(404).json({ error: "Endpoint not found." });
    } catch (error) {
      const status = Number.isInteger(error.status) ? error.status : 500;
      if (status === 500) {
        console.error("Admin API request failed:", error);
      }
      res.status(status).json({
        error: status === 500 ? "The admin API request failed." : error.message,
      });
    }
  },
);

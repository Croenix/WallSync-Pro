/**
 * WallSync Local Node.js Backend Server
 * 
 * Provides:
 * 1. Static file hosting for WallSync Admin Panel
 * 2. Virtual fallback for `firebase-config.js` when Firebase credentials are not yet configured
 * 3. Direct client API sync & heartbeat tracking (Live active users, total users)
 * 4. Real-time updates via Server-Sent Events (SSE)
 * 5. Local wallpaper repository endpoints
 * 
 * Zero external dependencies: Uses only Node.js standard libraries (`http`, `fs`, `path`, `url`).
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const url = require('url');
const crypto = require('crypto');
const os = require('os');

try {
    process.loadEnvFile(path.join(__dirname, '.env'));
} catch (error) {
    if (error.code !== 'ENOENT') throw error;
}

const PORT = parseInt(process.env.PORT || '3000', 10);
const HOST = '127.0.0.1';
const FIREBASE_RTDB_BASE_URL = (process.env.FIREBASE_RTDB_URL || 'https://wallsync-e043c-default-rtdb.firebaseio.com').replace(/\/+$/, '');
const STATIC_DIR = path.resolve(__dirname);
const PROJECT_ROOT = path.resolve(__dirname, '..');
const ASSETS_DIR = path.join(PROJECT_ROOT, 'assets');
const DATA_DIR = path.join(STATIC_DIR, 'data');
const USERS_FILE = path.join(DATA_DIR, 'users.json');
const WALLPAPERS_FILE = path.join(DATA_DIR, 'wallpapers.json');
const NOTIFICATIONS_FILE = path.join(DATA_DIR, 'notifications.json');
const POPUP_FILE = path.join(DATA_DIR, 'popup.json');
const POPUP_PRO_FILE = path.join(DATA_DIR, 'popup_pro.json');
const PUBLIC_FILES = new Map([
    ['/', 'index.html'],
    ['/index.html', 'index.html'],
    ['/app.js', 'app.js'],
    ['/styles.css', 'styles.css'],
    ['/favicon.png', 'favicon.png'],
    ['/logo.png', 'logo.png'],
]);
const ALLOWED_ORIGINS = new Set([
    `http://localhost:${PORT}`,
    `http://127.0.0.1:${PORT}`,
    'http://localhost:8000',
    'http://127.0.0.1:8000',
]);

function getCloudinaryConfig() {
    return {
        cloudName: (process.env.CLOUDINARY_CLOUD_NAME || 'wallsync').trim(),
        uploadPreset: (process.env.CLOUDINARY_UPLOAD_PRESET || '').trim(),
        apiKey: (process.env.CLOUDINARY_API_KEY || '').trim(),
        apiSecret: (process.env.CLOUDINARY_API_SECRET || '').trim(),
    };
}

// Ensure data directory exists
if (!fs.existsSync(DATA_DIR)) {
    fs.mkdirSync(DATA_DIR, { recursive: true });
}

// In-memory device state: deviceId -> deviceRecord
const devicesMap = new Map();

// In-memory wallpapers cache
let localWallpapers = [];

// Connected Server-Sent Event (SSE) clients
const sseClients = new Set();

// Load persisted devices
try {
    if (fs.existsSync(USERS_FILE)) {
        const raw = fs.readFileSync(USERS_FILE, 'utf8');
        const parsed = JSON.parse(raw);
        if (Array.isArray(parsed)) {
            parsed.forEach((u) => {
                const key = u && (u.deviceId || u.clientId);
                if (key) {
                    devicesMap.set(key, {
                        ...u,
                        deviceId: u.deviceId || u.clientId,
                        clientId: u.clientId || u.deviceId,
                    });
                }
            });
        }
    }
} catch (err) {
    console.warn('[WallSync Server] Warning: Could not load users.json:', err.message);
}

// Load persisted wallpapers
try {
    if (fs.existsSync(WALLPAPERS_FILE)) {
        const raw = fs.readFileSync(WALLPAPERS_FILE, 'utf8');
        localWallpapers = JSON.parse(raw);
        if (!Array.isArray(localWallpapers)) localWallpapers = [];
    }
} catch (err) {
    console.warn('[WallSync Server] Warning: Could not load wallpapers.json:', err.message);
}

// Load persisted notifications
let notificationsList = [];
try {
    if (fs.existsSync(NOTIFICATIONS_FILE)) {
        const raw = fs.readFileSync(NOTIFICATIONS_FILE, 'utf8');
        notificationsList = JSON.parse(raw);
        if (!Array.isArray(notificationsList)) notificationsList = [];
    }
} catch (err) {
    console.warn('[WallSync Server] Warning: Could not load notifications.json:', err.message);
}

function saveNotifications() {
    try {
        fs.writeFileSync(NOTIFICATIONS_FILE, JSON.stringify(notificationsList.slice(0, 50), null, 2), 'utf8');
    } catch (err) {
        console.error('[WallSync Server] Failed to save notifications.json:', err.message);
    }
}

// Load persisted promotional launch popup configuration
let popupConfig = {
    enabled: false,
    imageUrl: '',
    actionText: 'Continue',
    actionUrl: '',
    id: 'popup_default',
    updatedAt: 0,
};

try {
    if (fs.existsSync(POPUP_FILE)) {
        const raw = fs.readFileSync(POPUP_FILE, 'utf8');
        const parsed = JSON.parse(raw);
        if (parsed && typeof parsed === 'object') {
            popupConfig = {
                enabled: Boolean(parsed.enabled),
                imageUrl: (parsed.imageUrl || '').trim(),
                actionText: (parsed.actionText || 'Continue').trim(),
                actionUrl: (parsed.actionUrl || '').trim(),
                id: parsed.id || ('popup_' + Date.now()),
                updatedAt: parsed.updatedAt || 0,
            };
        }
    }
} catch (err) {
    console.warn('[WallSync Server] Warning: Could not load popup.json:', err.message);
}

function savePopupConfig() {
    try {
        fs.writeFileSync(POPUP_FILE, JSON.stringify(popupConfig, null, 2), 'utf8');
    } catch (err) {
        console.error('[WallSync Server] Failed to save popup.json:', err.message);
    }
}

async function syncPopupToFirebase(popup, force = false, key = 'popup') {
    if (!force && (process.env.NODE_ENV === 'test' || PORT === 3099)) {
        return true;
    }
    try {
        const rtdbUrl = `${FIREBASE_RTDB_BASE_URL}/${key}.json`;
        await fetch(rtdbUrl, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(popup),
            signal: AbortSignal.timeout(5000),
        });
        return true;
    } catch (e) {
        console.warn(`[WallSync Server] Notice: Could not sync ${key} to Firebase RTDB (${e.message})`);
        return false;
    }
}

// Load persisted promotional launch popup pro configuration
let popupProConfig = {
    enabled: false,
    imageUrl: '',
    actionText: 'Continue',
    actionUrl: '',
    id: 'popup_pro_default',
    updatedAt: 0,
};

try {
    if (fs.existsSync(POPUP_PRO_FILE)) {
        const raw = fs.readFileSync(POPUP_PRO_FILE, 'utf8');
        const parsed = JSON.parse(raw);
        if (parsed && typeof parsed === 'object') {
            popupProConfig = {
                enabled: Boolean(parsed.enabled),
                imageUrl: (parsed.imageUrl || '').trim(),
                actionText: (parsed.actionText || 'Continue').trim(),
                actionUrl: (parsed.actionUrl || '').trim(),
                id: parsed.id || ('popup_pro_' + Date.now()),
                updatedAt: parsed.updatedAt || 0,
            };
        }
    }
} catch (err) {
    console.warn('[WallSync Server] Warning: Could not load popup_pro.json:', err.message);
}

function savePopupProConfig() {
    try {
        fs.writeFileSync(POPUP_PRO_FILE, JSON.stringify(popupProConfig, null, 2), 'utf8');
    } catch (err) {
        console.error('[WallSync Server] Failed to save popup_pro.json:', err.message);
    }
}

// Firebase Realtime Database Wallpapers Cache & Sync
const FIREBASE_RTDB_URL = `${FIREBASE_RTDB_BASE_URL}/wallpapers.json`;
let cachedFirebaseWallpapers = [];
let lastFirebaseFetchTime = 0;

function normalizeMixkitUrl(url) {
    if (!url || typeof url !== 'string') return url;
    const match = url.match(/assets\.mixkit\.co\/videos\/preview\/(?:mixkit-)?.*?(\d+)-(?:large|medium|small)\.mp4/i);
    if (match && match[1]) {
        return `https://assets.mixkit.co/videos/${match[1]}/${match[1]}-720.mp4`;
    }
    return url;
}

function classifyResolution(width, height) {
    if (!Number.isInteger(width) || width <= 0 ||
        !Number.isInteger(height) || height <= 0) {
        return 'Resolution unavailable';
    }
    const longSide = Math.max(width, height);
    const shortSide = Math.min(width, height);
    for (const [targetLong, targetShort, label] of [
        [1280, 720, 'HD'],
        [1920, 1080, 'Full HD'],
        [2048, 1080, '2K'],
        [2560, 1440, '2K'],
        [3840, 2160, '4K'],
        [4096, 2160, '4K'],
        [7680, 4320, '8K'],
        [15360, 8640, '16K'],
    ]) {
        const longRatio = longSide / targetLong;
        const shortRatio = shortSide / targetShort;
        if (Math.abs(longRatio - shortRatio) <= 0.03 &&
            Math.abs(longRatio - 1) <= 0.05 &&
            Math.abs(shortRatio - 1) <= 0.05) {
            return label;
        }
    }
    return 'Other';
}

function normalizeWallpaperItem(id, item, source = 'firebase') {
    const rawType = (item.type || '').toLowerCase();
    const rawUrl = (item.url || '').toLowerCase();
    const rawCat = (item.category || '').toLowerCase();
    const isVideo = rawType === 'video' ||
        rawType === 'animated' ||
        rawCat.includes('video') ||
        rawCat.includes('live') ||
        rawUrl.includes('/video/') ||
        Boolean(rawUrl.match(/\.(mp4|webm|ogg|mov|mkv)(\?.*)?$/i));

    let finalUrl = normalizeMixkitUrl(item.url || '');
    if (finalUrl.startsWith('asset://assets/')) {
        finalUrl = finalUrl.replace('asset://assets/', '/assets/');
    } else if (finalUrl.startsWith('assets/')) {
        finalUrl = '/' + finalUrl;
    }

    let thumb = item.thumbnailUrl;
    if (!thumb) {
        if (finalUrl.includes('res.cloudinary.com')) {
            thumb = finalUrl.replace(/\.[^.]+$/, '.jpg');
        } else if (!isVideo && finalUrl) {
            thumb = finalUrl;
        }
    }

    return {
        id: item.wallpaperId || item.id || id,
        wallpaperId: item.wallpaperId || item.id || id,
        name: item.name || id,
        category: item.category || (isVideo ? 'Live Video' : 'General'),
        type: isVideo ? 'video' : (rawType || 'static'),
        url: finalUrl,
        thumbnailUrl: thumb || null,
        description: item.description || null,
        tags: Array.isArray(item.tags) ? item.tags : (item.tags ? String(item.tags).split(',').map((t) => t.trim()).filter(Boolean) : null),
        animatedBgPreset: item.animatedBgPreset || null,
        width: Number.isSafeInteger(item.width) && item.width > 0 ? item.width : 0,
        height: Number.isSafeInteger(item.height) && item.height > 0 ? item.height : 0,
        resolutionLabel: classifyResolution(
            Number(item.width),
            Number(item.height),
        ),
        resolutionSource: item.resolutionSource || 'unavailable',
        resolutionVerified: item.resolutionVerified === true,
        isPro: item.isPro === true || item.pro === true,
        source: source,
    };
}

async function fetchFromFirebaseDatabase(force = false) {
    const now = Date.now();
    // Cache for 8 seconds unless force refreshed
    if (!force && cachedFirebaseWallpapers.length > 0 && (now - lastFirebaseFetchTime < 8000)) {
        return cachedFirebaseWallpapers;
    }

    const map = new Map();

    // Fetch all database wallpapers dynamically from Firebase Realtime Database
    try {
        const response = await fetch(FIREBASE_RTDB_URL, { signal: AbortSignal.timeout(8000) });
        if (response.ok) {
            const data = await response.json();
            if (data && typeof data === 'object') {
                if (Array.isArray(data)) {
                    data.forEach((val, idx) => {
                        if (val && typeof val === 'object' && (val.url || val.animatedBgPreset || val.type === 'animated')) {
                            const norm = normalizeWallpaperItem(String(idx), val, 'firebase');
                            map.set(norm.id, norm);
                        }
                    });
                } else {
                    Object.entries(data).forEach(([key, val]) => {
                        if (val && typeof val === 'object' && (val.url || val.animatedBgPreset || val.type === 'animated')) {
                            const norm = normalizeWallpaperItem(key, val, 'firebase');
                            map.set(norm.id, norm);
                        }
                    });
                }
            }
        }
    } catch (err) {
        console.warn('[WallSync Server] Firebase RTDB fetch warning:', err.message);
    }

    cachedFirebaseWallpapers = Array.from(map.values());
    lastFirebaseFetchTime = now;
    return cachedFirebaseWallpapers;
}

// Save devices to disk
let saveUsersTimeout = null;
function scheduleSaveUsers() {
    if (saveUsersTimeout) return;
    saveUsersTimeout = setTimeout(() => {
        saveUsersTimeout = null;
        try {
            const list = Array.from(devicesMap.values());
            fs.writeFileSync(USERS_FILE, JSON.stringify(list, null, 2), 'utf8');
        } catch (err) {
            console.error('[WallSync Server] Failed to save users.json:', err.message);
        }
    }, 1500);
}

// Calculate live devices (heartbeat seen within last 45 seconds)
const LIVE_THRESHOLD_MS = 45 * 1000;
function getStats() {
    const now = Date.now();
    let liveCount = 0;
    const activeClients = [];
    const allDevices = [];

    for (const dev of devicesMap.values()) {
        const isLive = (now - (dev.lastSeen || 0)) <= LIVE_THRESHOLD_MS;
        const entry = {
            deviceId: dev.deviceId || dev.clientId,
            clientId: dev.clientId || dev.deviceId,
            hostname: dev.hostname || 'Unknown',
            platform: dev.platform || 'windows',
            activeWallpaper: dev.activeWallpaper || '',
            activeWallpaperType: dev.activeWallpaperType || 'color',
            appVersion: dev.appVersion || '1.0.1',
            lastSeen: dev.lastSeen,
            firstSeen: dev.firstSeen,
            heartbeats: dev.heartbeats || 1,
            isLive,
        };
        allDevices.push(entry);
        if (isLive) {
            liveCount++;
            activeClients.push(entry);
        }
    }

    return {
        totalDevices: devicesMap.size,
        liveDevices: liveCount,
        totalUsers: devicesMap.size,
        liveUsers: liveCount,
        notificationsCount: notificationsList.length,
        latestNotification: notificationsList[0] || null,
        activeClients,
        allDevices,
    };
}

// Broadcast SSE event to connected admin dashboards
function broadcastEvent(type, payload = {}) {
    const message = `event: ${type}\ndata: ${JSON.stringify(payload)}\n\n`;
    for (const client of sseClients) {
        try {
            client.write(message);
        } catch {
            sseClients.delete(client);
        }
    }
}

// MIME types dictionary
const MIME_TYPES = {
    '.html': 'text/html; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.js': 'application/javascript; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.svg': 'image/svg+xml',
    '.ico': 'image/x-icon',
    '.mp4': 'video/mp4',
    '.webm': 'video/webm',
};

// Helper: send JSON response
function sendJson(res, statusCode, data) {
    const jsonStr = JSON.stringify(data);
    res.writeHead(statusCode, {
        'Content-Type': 'application/json; charset=utf-8',
        'Content-Length': Buffer.byteLength(jsonStr),
        'Access-Control-Allow-Methods': 'GET, POST, PATCH, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    });
    res.end(jsonStr);
}

// Helper: parse JSON request body
function parseJsonBody(req) {
    return new Promise((resolve, reject) => {
        let body = '';
        req.on('data', (chunk) => {
            body += chunk;
            if (body.length > 5 * 1024 * 1024) {
                // Max 5 MB payload limit
                reject(new Error('Request entity too large'));
            }
        });
        req.on('end', () => {
            if (!body.trim()) return resolve({});
            try {
                resolve(JSON.parse(body));
            } catch (err) {
                reject(new Error('Malformed JSON body: ' + err.message));
            }
        });
        req.on('error', reject);
    });
}

// Periodic check: purge old live states and broadcast if stats change
let lastBroadcastStats = { totalDevices: 0, liveDevices: 0, totalUsers: 0, liveUsers: 0 };
const statsInterval = setInterval(() => {
    const current = getStats();
    if (
        current.totalDevices !== lastBroadcastStats.totalDevices ||
        current.liveDevices !== lastBroadcastStats.liveDevices
    ) {
        lastBroadcastStats = {
            totalDevices: current.totalDevices,
            liveDevices: current.liveDevices,
            totalUsers: current.totalUsers,
            liveUsers: current.liveUsers,
        };
        broadcastEvent('stats', current);
    }
}, 5000);
if (statsInterval.unref) statsInterval.unref();

// Create HTTP server
const server = http.createServer(async (req, res) => {
    const host = req.headers.host;
    const allowedHosts = new Set([
        `localhost:${PORT}`,
        `127.0.0.1:${PORT}`,
        `[::1]:${PORT}`,
    ]);
    if (!host || !allowedHosts.has(host)) {
        return sendJson(res, 403, { error: 'Host is not allowed' });
    }

    const origin = req.headers.origin;
    if (origin && !ALLOWED_ORIGINS.has(origin)) {
        return sendJson(res, 403, { error: 'Origin is not allowed' });
    }
    if (origin) {
        res.setHeader('Access-Control-Allow-Origin', origin);
        res.setHeader('Vary', 'Origin');
    }
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PATCH, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');

    if (req.method === 'OPTIONS') {
        res.writeHead(204);
        res.end();
        return;
    }

    const requestUrl = new URL(req.url, `http://${req.headers.host || '127.0.0.1'}`);
    const pathname = requestUrl.pathname;

    // ─────────────────────────────────────────────────────────────
    // API ROUTING
    // ─────────────────────────────────────────────────────────────

    // GET /api/status - Server health check
    if (pathname === '/api/status' && req.method === 'GET') {
        const stats = getStats();
        return sendJson(res, 200, {
            status: 'online',
            service: 'WallSync Admin Backend',
            version: '1.0.0',
            port: PORT,
            timestamp: Date.now(),
            totalUsers: stats.totalUsers,
            liveUsers: stats.liveUsers,
        });
    }

    // POST /api/sync/heartbeat (and alias /api/heartbeat) - Flutter application heartbeat endpoint
    if ((pathname === '/api/sync/heartbeat' || pathname === '/api/heartbeat') && req.method === 'POST') {
        try {
            const body = await parseJsonBody(req);
            const deviceId = (body.deviceId || body.clientId || '').trim();

            if (!deviceId) {
                return sendJson(res, 400, { error: 'Missing deviceId or clientId in payload' });
            }

            const clientId = (body.clientId || deviceId).trim();
            const now = Date.now();
            const existing = devicesMap.get(deviceId) || {
                deviceId,
                clientId,
                firstSeen: now,
                heartbeats: 0,
            };

            const remoteIp = req.headers['x-forwarded-for'] || req.socket.remoteAddress || '127.0.0.1';

            const updated = {
                ...existing,
                deviceId,
                clientId: body.clientId || existing.clientId || deviceId,
                hostname: body.hostname || existing.hostname || 'Unknown',
                platform: body.platform || existing.platform || 'windows',
                appVersion: body.appVersion || existing.appVersion || '1.0.1',
                activeWallpaper: body.activeWallpaper || existing.activeWallpaper || '',
                activeWallpaperType: body.activeWallpaperType || existing.activeWallpaperType || 'color',
                lastSeen: now,
                ip: remoteIp,
                heartbeats: (existing.heartbeats || 0) + 1,
            };

            devicesMap.set(deviceId, updated);
            scheduleSaveUsers();

            const stats = getStats();
            broadcastEvent('stats', stats);

            return sendJson(res, 200, {
                success: true,
                liveDevices: stats.liveDevices,
                totalDevices: stats.totalDevices,
                liveUsers: stats.liveUsers,
                totalUsers: stats.totalUsers,
                deviceId,
                clientId: updated.clientId,
                latestNotification: notificationsList[0] || null,
                popup: popupConfig,
            });
        } catch (err) {
            return sendJson(res, 400, { error: err.message });
        }
    }

    // POST /api/devices/clear (and alias /api/users/clear) - Clear all registered devices
    if ((pathname === '/api/devices/clear' || pathname === '/api/users/clear') && req.method === 'POST') {
        devicesMap.clear();
        try {
            fs.writeFileSync(USERS_FILE, '[]', 'utf8');
        } catch (err) {
            console.error('[WallSync Server] Failed to clear users.json:', err.message);
        }
        const stats = getStats();
        broadcastEvent('stats', stats);
        return sendJson(res, 200, {
            success: true,
            message: 'All registered devices cleared successfully.',
            totalDevices: 0,
            liveDevices: 0,
            totalUsers: 0,
            liveUsers: 0,
            activeClients: [],
            allDevices: [],
        });
    }

    // POST /api/notifications/send - Broadcast a push notification to all client machines
    if ((pathname === '/api/notifications/send' || pathname === '/api/notifications') && req.method === 'POST') {
        try {
            const body = await parseJsonBody(req);
            const title = (body.title || '').trim();
            const message = (body.message || '').trim();
            if (!title) {
                return sendJson(res, 400, { error: 'Notification title is required' });
            }

            const notif = {
                id: 'notif_' + Date.now() + '_' + Math.random().toString(16).slice(2, 8),
                title,
                message,
                type: (body.type || 'update').trim(),
                version: (body.version || '').trim(),
                actionUrl: (body.actionUrl || body.url || '').trim(),
                timestamp: Date.now(),
            };

            notificationsList.unshift(notif);
            if (notificationsList.length > 50) {
                notificationsList = notificationsList.slice(0, 50);
            }
            saveNotifications();

            broadcastEvent('push_notification', notif);
            broadcastEvent('stats', getStats());

            return sendJson(res, 200, {
                success: true,
                message: 'Push notification broadcasted successfully to all devices.',
                notification: notif,
                totalNotifications: notificationsList.length,
            });
        } catch (err) {
            return sendJson(res, 400, { error: err.message });
        }
    }

    // GET /api/notifications - List notifications history
    if (pathname === '/api/notifications' && req.method === 'GET') {
        return sendJson(res, 200, {
            success: true,
            count: notificationsList.length,
            notifications: notificationsList,
            latest: notificationsList[0] || null,
        });
    }

    // GET /api/notifications/latest - Latest notification
    if (pathname === '/api/notifications/latest' && req.method === 'GET') {
        return sendJson(res, 200, {
            success: true,
            notification: notificationsList[0] || null,
        });
    }

    // POST /api/notifications/clear - Clear notifications history
    if (pathname === '/api/notifications/clear' && req.method === 'POST') {
        notificationsList = [];
        saveNotifications();
        broadcastEvent('stats', getStats());
        return sendJson(res, 200, {
            success: true,
            message: 'All notifications cleared successfully.',
            notifications: [],
        });
    }

    // GET /api/popup (and alias /api/popup/config) - Fetch launch popup configuration
    if ((pathname === '/api/popup' || pathname === '/api/popup/config') && req.method === 'GET') {
        return sendJson(res, 200, {
            success: true,
            popup: popupConfig,
        });
    }

    // GET /api/popup_pro - Fetch launch popup pro configuration
    if (pathname === '/api/popup_pro' && req.method === 'GET') {
        return sendJson(res, 200, {
            success: true,
            popup: popupProConfig,
        });
    }

    // POST /api/popup (and alias /api/popup/config) - Update launch popup configuration
    if ((pathname === '/api/popup' || pathname === '/api/popup/config') && req.method === 'POST') {
        try {
            const body = await parseJsonBody(req);
            const enabled = Boolean(body.enabled);
            const imageUrl = typeof body.imageUrl === 'string' ? body.imageUrl.trim() : (popupConfig.imageUrl || '');
            const actionText = typeof body.actionText === 'string' && body.actionText.trim() ? body.actionText.trim() : 'Continue';
            const actionUrl = typeof body.actionUrl === 'string' ? body.actionUrl.trim() : (popupConfig.actionUrl || '');

            popupConfig = {
                enabled,
                imageUrl,
                actionText,
                actionUrl,
                id: body.id || ('popup_' + Date.now()),
                updatedAt: Date.now(),
            };

            savePopupConfig();
            syncPopupToFirebase(popupConfig).catch(() => {});
            broadcastEvent('popup_update', popupConfig);

            return sendJson(res, 200, {
                success: true,
                message: 'Popup configuration saved successfully.',
                popup: popupConfig,
            });
        } catch (err) {
            return sendJson(res, 400, { error: err.message });
        }
    }

    // POST /api/popup_pro - Update launch popup pro configuration
    if (pathname === '/api/popup_pro' && req.method === 'POST') {
        try {
            const body = await parseJsonBody(req);
            const enabled = Boolean(body.enabled);
            const imageUrl = typeof body.imageUrl === 'string' ? body.imageUrl.trim() : (popupProConfig.imageUrl || '');
            const actionText = typeof body.actionText === 'string' && body.actionText.trim() ? body.actionText.trim() : 'Continue';
            const actionUrl = typeof body.actionUrl === 'string' ? body.actionUrl.trim() : (popupProConfig.actionUrl || '');

            popupProConfig = {
                enabled,
                imageUrl,
                actionText,
                actionUrl,
                id: body.id || ('popup_pro_' + Date.now()),
                updatedAt: Date.now(),
            };

            savePopupProConfig();
            syncPopupToFirebase(popupProConfig, false, 'popup_pro').catch(() => {});
            broadcastEvent('popup_pro_update', popupProConfig);

            return sendJson(res, 200, {
                success: true,
                message: 'Popup Pro configuration saved successfully.',
                popup: popupProConfig,
            });
        } catch (err) {
            return sendJson(res, 400, { error: err.message });
        }
    }

    // GET /api/devices (and alias /api/users) - All registered devices
    if ((pathname === '/api/devices' || pathname === '/api/users') && req.method === 'GET') {
        const stats = getStats();
        return sendJson(res, 200, {
            success: true,
            totalDevices: stats.totalDevices,
            liveDevices: stats.liveDevices,
            totalUsers: stats.totalUsers,
            liveUsers: stats.liveUsers,
            devices: stats.allDevices,
            activeClients: stats.activeClients,
        });
    }

    // GET /api/users/stats - Direct stats endpoint
    if ((pathname === '/api/users/stats' || pathname === '/api/devices/stats') && req.method === 'GET') {
        const stats = getStats();
        return sendJson(res, 200, {
            success: true,
            totalDevices: stats.totalDevices,
            liveDevices: stats.liveDevices,
            totalUsers: stats.totalUsers,
            liveUsers: stats.liveUsers,
            activeClients: stats.activeClients,
            devices: stats.allDevices,
        });
    }

    // GET /api/events - Server-Sent Events stream for real-time dashboard updates
    if (pathname === '/api/events' && req.method === 'GET') {
        res.writeHead(200, {
            'Content-Type': 'text/event-stream; charset=utf-8',
            'Cache-Control': 'no-cache, no-transform',
            'Connection': 'keep-alive',
        });
        res.flushHeaders?.();

        // Register client
        sseClients.add(res);

        // Send initial state immediately
        const stats = getStats();
        res.write(`event: stats\ndata: ${JSON.stringify(stats)}\n\n`);

        // Keepalive ping comment every 15s to keep connections open
        const keepAliveTimer = setInterval(() => {
            try {
                res.write(': keepalive\n\n');
            } catch {
                clearInterval(keepAliveTimer);
                sseClients.delete(res);
            }
        }, 15000);

        req.on('close', () => {
            clearInterval(keepAliveTimer);
            sseClients.delete(res);
        });
        return;
    }

    // ─────────────────────────────────────────────────────────────
    // FIREBASE DATABASE & LOCAL WALLPAPERS CATALOG
    // ─────────────────────────────────────────────────────────────

    // GET /api/database/wallpapers - Synced live wallpapers from Firebase RTDB & local storage
    if (pathname === '/api/database/wallpapers' && req.method === 'GET') {
        try {
            const force = requestUrl.searchParams.get('refresh') === 'true';
            const remoteList = await fetchFromFirebaseDatabase(force);

            const map = new Map();
            // 1. Add all Firebase database wallpapers
            for (const item of remoteList) {
                map.set(item.id, item);
            }
            // 2. Add local wallpapers (override or append)
            for (const local of localWallpapers) {
                map.set(local.id, normalizeWallpaperItem(local.id, local, 'local'));
            }

            const combined = Array.from(map.values());
            return sendJson(res, 200, {
                success: true,
                count: combined.length,
                wallpapers: combined,
            });
        } catch (err) {
            return sendJson(res, 500, {
                error: 'Failed to fetch database wallpapers: ' + err.message,
                wallpapers: localWallpapers,
            });
        }
    }

    // POST /api/database/delete - Remove wallpaper from catalog & Firebase Realtime Database
    if (pathname === '/api/database/delete' && req.method === 'POST') {
        try {
            const body = await parseJsonBody(req);
            const id = (body.id || '').trim();
            if (!id) return sendJson(res, 400, { error: 'Missing wallpaper id' });

            // Remove from Firebase Realtime Database
            try {
                const rtdbItemUrl = `${FIREBASE_RTDB_BASE_URL}/wallpapers/${encodeURIComponent(id)}.json`;
                await fetch(rtdbItemUrl, {
                    method: 'DELETE',
                    signal: AbortSignal.timeout(8000),
                });
            } catch (fbErr) {
                console.warn('[WallSync Server] Warning: Could not delete wallpaper from Firebase RTDB:', fbErr.message);
            }

            // Remove from local wallpapers
            const prevLen = localWallpapers.length;
            localWallpapers = localWallpapers.filter((w) => w.id !== id);
            if (localWallpapers.length !== prevLen) {
                fs.writeFileSync(WALLPAPERS_FILE, JSON.stringify(localWallpapers, null, 2), 'utf8');
            }

            // Remove from cached remote wallpapers
            cachedFirebaseWallpapers = cachedFirebaseWallpapers.filter((w) => w.id !== id);

            broadcastEvent('wallpaper_deleted', { id });
            broadcastEvent('wallpapers_updated', { id, action: 'deleted' });

            return sendJson(res, 200, { success: true, id });
        } catch (err) {
            return sendJson(res, 400, { error: err.message });
        }
    }

    // GET /api/wallpapers - Local wallpaper list fallback
    if (pathname === '/api/wallpapers' && req.method === 'GET') {
        return sendJson(res, 200, {
            success: true,
            wallpapers: localWallpapers,
        });
    }

    // POST /api/database/update - Edit wallpaper data (title, description, tags, etc.) & update RTDB
    if (pathname === '/api/database/update' && req.method === 'POST') {
        try {
            const body = await parseJsonBody(req);
            const id = (body.id || '').trim();
            if (!id) return sendJson(res, 400, { error: 'Missing wallpaper id' });
            if (!body.name || !body.name.trim()) return sendJson(res, 400, { error: 'Wallpaper title is required' });

            const normalized = normalizeWallpaperItem(id, body, 'local');

            // 1. Update in local storage
            const index = localWallpapers.findIndex((w) => w.id === id);
            if (index >= 0) {
                localWallpapers[index] = normalized;
            } else {
                localWallpapers.push(normalized);
            }
            fs.writeFileSync(WALLPAPERS_FILE, JSON.stringify(localWallpapers, null, 2), 'utf8');

            // 2. Persist update directly into Firebase Realtime Database
            const rtdbItemUrl = `${FIREBASE_RTDB_BASE_URL}/wallpapers/${encodeURIComponent(id)}.json`;
            const rtdbPayload = {
                id: normalized.id,
                wallpaperId: normalized.wallpaperId,
                name: normalized.name,
                category: normalized.category,
                type: normalized.type,
                url: normalized.url,
                thumbnailUrl: normalized.thumbnailUrl || null,
                description: normalized.description || null,
                tags: normalized.tags || null,
                animatedBgPreset: normalized.animatedBgPreset || null,
                width: normalized.width,
                height: normalized.height,
                resolutionLabel: normalized.resolutionLabel,
                resolutionSource: normalized.resolutionSource,
                resolutionVerified: normalized.resolutionVerified,
                isPro: normalized.isPro === true,
            };

            let rtdbSuccess = false;
            try {
                const fbRes = await fetch(rtdbItemUrl, {
                    method: 'PUT',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(rtdbPayload),
                    signal: AbortSignal.timeout(8000),
                });
                rtdbSuccess = fbRes.ok;
            } catch (fbErr) {
                console.warn('[WallSync Server] Warning: Could not update wallpaper in Firebase RTDB:', fbErr.message);
            }

            // 3. Update cached database list in memory
            const cachedIdx = cachedFirebaseWallpapers.findIndex((w) => w.id === id);
            if (cachedIdx >= 0) {
                cachedFirebaseWallpapers[cachedIdx] = normalized;
            } else {
                cachedFirebaseWallpapers.push(normalized);
            }

            broadcastEvent('wallpaper_updated', { id, wallpaper: normalized });
            broadcastEvent('wallpapers_updated', { id, action: 'updated' });

            return sendJson(res, 200, {
                success: true,
                id,
                rtdbUpdated: rtdbSuccess,
                wallpaper: normalized,
            });
        } catch (err) {
            return sendJson(res, 400, { error: err.message });
        }
    }

    // POST /api/wallpapers - Publish wallpaper to Firebase Realtime Database & local storage
    if (pathname === '/api/wallpapers' && req.method === 'POST') {
        try {
            const body = await parseJsonBody(req);
            const items = Array.isArray(body.items) ? body.items : [body];
            let addedCount = 0;

            for (const item of items) {
                if (!item || !item.id || !item.url) continue;
                const normalized = normalizeWallpaperItem(item.id, item, 'local');
                const index = localWallpapers.findIndex((w) => w.id === item.id);
                if (index >= 0) {
                    localWallpapers[index] = normalized;
                } else {
                    localWallpapers.push(normalized);
                }

                // Persist directly to Firebase Realtime Database
                try {
                    const rtdbItemUrl = `${FIREBASE_RTDB_BASE_URL}/wallpapers/${encodeURIComponent(item.id)}.json`;
                    const rtdbPayload = {
                        id: normalized.id,
                        wallpaperId: normalized.wallpaperId,
                        name: normalized.name,
                        category: normalized.category,
                        type: normalized.type,
                        url: normalized.url,
                        thumbnailUrl: normalized.thumbnailUrl || null,
                        description: normalized.description || null,
                        tags: normalized.tags || null,
                        animatedBgPreset: normalized.animatedBgPreset || null,
                        width: normalized.width,
                        height: normalized.height,
                        resolutionLabel: normalized.resolutionLabel,
                        resolutionSource: normalized.resolutionSource,
                        resolutionVerified: normalized.resolutionVerified,
                        isPro: normalized.isPro === true,
                    };
                    await fetch(rtdbItemUrl, {
                        method: 'PUT',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify(rtdbPayload),
                        signal: AbortSignal.timeout(8000),
                    });
                } catch (fbErr) {
                    console.warn('[WallSync Server] Warning: Could not sync wallpaper to Firebase RTDB:', fbErr.message);
                }

                // Update cached database list in memory
                const cachedIdx = cachedFirebaseWallpapers.findIndex((w) => w.id === item.id);
                if (cachedIdx >= 0) {
                    cachedFirebaseWallpapers[cachedIdx] = normalized;
                } else {
                    cachedFirebaseWallpapers.push(normalized);
                }

                addedCount++;
            }

            fs.writeFileSync(WALLPAPERS_FILE, JSON.stringify(localWallpapers, null, 2), 'utf8');
            broadcastEvent('wallpapers_updated', { count: addedCount, action: 'added' });
            return sendJson(res, 200, { success: true, saved: addedCount, uploaded: addedCount });
        } catch (err) {
            return sendJson(res, 400, { error: err.message });
        }
    }

    // POST /api/wallpapers/migrate - Migrate wallpaper records to canonical IDs
    if (pathname === '/api/wallpapers/migrate' && req.method === 'POST') {
        try {
            let migratedCount = 0;
            const usedIds = new Set();
            const idPattern = /^[A-Za-z0-9_-]{1,128}$/;

            if (Array.isArray(localWallpapers)) {
                localWallpapers.forEach((w) => {
                    if (w && w.id && idPattern.test(w.id)) usedIds.add(w.id);
                });

                localWallpapers = localWallpapers.map((item) => {
                    let id = item.wallpaperId || item.id;
                    if (!id || typeof id !== 'string' || !idPattern.test(id) || !usedIds.has(id)) {
                        id = 'wp_' + Date.now() + '_' + Math.random().toString(16).slice(2, 8);
                        usedIds.add(id);
                        migratedCount++;
                    }
                    return normalizeWallpaperItem(id, { ...item, id, wallpaperId: id }, 'local');
                });
                fs.writeFileSync(WALLPAPERS_FILE, JSON.stringify(localWallpapers, null, 2), 'utf8');
            }

            return sendJson(res, 200, {
                success: true,
                migrated: migratedCount,
                total: localWallpapers.length,
            });
        } catch (err) {
            return sendJson(res, 500, { error: err.message, migrated: 0 });
        }
    }

    // GET /api/wallpaper-reports & GET /api/reports - Fetch reports fallback from Firebase Realtime Database
    if ((pathname === '/api/wallpaper-reports' || pathname === '/api/reports' || pathname === '/api/wallpaper_reports_pro' || pathname === '/api/wallpaper-reports-pro') && req.method === 'GET') {
        try {
            const rootKey = (pathname === '/api/wallpaper_reports_pro' || pathname === '/api/wallpaper-reports-pro')
                ? 'wallpaper_reports_pro'
                : (pathname === '/api/reports' ? 'reports' : 'wallpaperReports');
            const rtdbRes = await fetch(`${FIREBASE_RTDB_BASE_URL}/${rootKey}.json`, {
                signal: AbortSignal.timeout(5000),
            });
            if (rtdbRes.ok) {
                const data = await rtdbRes.json();
                return sendJson(res, 200, data || {});
            }
            return sendJson(res, 200, {});
        } catch (err) {
            return sendJson(res, 200, {});
        }
    }

    // PATCH /api/wallpaper-reports/:id & PATCH /api/reports/:id - Update report status/notes in Firebase RTDB
    const reportPathMatch = /^\/api\/(wallpaper-reports|reports|wallpaper_reports_pro|wallpaper-reports-pro)\/([A-Za-z0-9_-]{1,128})$/.exec(pathname);
    if (reportPathMatch && req.method === 'PATCH') {
        try {
            const rootKey = (reportPathMatch[1] === 'wallpaper_reports_pro' || reportPathMatch[1] === 'wallpaper-reports-pro')
                ? 'wallpaper_reports_pro'
                : (reportPathMatch[1] === 'reports' ? 'reports' : 'wallpaperReports');
            const reportId = reportPathMatch[2];
            const body = await parseJsonBody(req);
            const updatePayload = {
                status: body.status || 'resolved',
                adminNotes: (body.adminNotes || '').trim(),
                updatedAt: Date.now(),
            };

            const rtdbRes = await fetch(`${FIREBASE_RTDB_BASE_URL}/${rootKey}/${encodeURIComponent(reportId)}.json`, {
                method: 'PATCH',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(updatePayload),
                signal: AbortSignal.timeout(5000),
            });

            if (!rtdbRes.ok) {
                return sendJson(res, 502, { error: 'Failed to update report in Firebase RTDB' });
            }
            return sendJson(res, 200, { success: true, ...updatePayload });
        } catch (err) {
            return sendJson(res, 500, { error: err.message });
        }
    }

    // ─────────────────────────────────────────────────────────────
    // CLOUDINARY CONFIGURATION & DIRECT UPLOAD SIGNING (NO FIREBASE REQUIRED)
    // ─────────────────────────────────────────────────────────────

    // GET /api/cloudinary-config - Retrieve Cloudinary setup
    if (pathname === '/api/cloudinary-config' && req.method === 'GET') {
        const cfg = getCloudinaryConfig();
        return sendJson(res, 200, {
            success: true,
            cloudName: cfg.cloudName,
            uploadPreset: cfg.uploadPreset,
            hasApiKey: Boolean(cfg.apiKey),
            hasApiSecret: Boolean(cfg.apiSecret),
        });
    }

    // POST /api/cloudinary-config - Save Cloudinary configuration
    if (pathname === '/api/cloudinary-config' && req.method === 'POST') {
        return sendJson(res, 410, {
            error: 'Cloudinary configuration must be managed through environment variables or Firebase secrets.',
        });
    }

    // POST /api/sign-upload - Sign upload or provide upload preset for direct Cloudinary upload
    if (pathname === '/api/sign-upload' && req.method === 'POST') {
        try {
            const body = await parseJsonBody(req);
            const folder = (body && body.folder) || 'wallsync_videos';
            const cfg = getCloudinaryConfig();

            if (!cfg.cloudName) {
                return sendJson(res, 400, {
                    error: 'Cloudinary Cloud Name is not configured. Please set your Cloud Name in System & Account.',
                });
            }

            // If apiKey and apiSecret are configured, generate signed upload parameters
            if (cfg.apiKey && cfg.apiSecret) {
                const timestamp = Math.round(new Date().getTime() / 1000);
                const params = [];
                if (folder) params.push(`folder=${folder}`);
                params.push(`timestamp=${timestamp}`);
                const paramsToSign = params.sort().join('&');
                const signature = crypto
                    .createHash('sha1')
                    .update(paramsToSign + cfg.apiSecret)
                    .digest('hex');

                return sendJson(res, 200, {
                    cloudName: cfg.cloudName,
                    apiKey: cfg.apiKey,
                    timestamp,
                    signature,
                    folder,
                });
            }

            // If unsigned uploadPreset is configured, return preset configuration
            if (cfg.uploadPreset) {
                return sendJson(res, 200, {
                    cloudName: cfg.cloudName,
                    uploadPreset: cfg.uploadPreset,
                    folder,
                });
            }

            return sendJson(res, 400, {
                error: 'Cloudinary is not configured yet. Go to System & Account to set your Cloud Name and Upload Preset.',
            });
        } catch (err) {
            return sendJson(res, 400, { error: err.message });
        }
    }

    // GET /api/images & GET /api/videos - Return media resources (from Cloudinary or active catalog)
    if ((pathname === '/api/images' || pathname === '/api/videos') && req.method === 'GET') {
        const resourceType = pathname === '/api/videos' ? 'video' : 'image';
        try {
            const cfg = getCloudinaryConfig();
            if (cfg.cloudName && cfg.apiKey && cfg.apiSecret) {
                const credentials = Buffer.from(`${cfg.apiKey}:${cfg.apiSecret}`).toString('base64');
                const cloudRes = await fetch(
                    `https://api.cloudinary.com/v1_1/${encodeURIComponent(cfg.cloudName)}/resources/search`,
                    {
                        method: 'POST',
                        headers: {
                            Authorization: `Basic ${credentials}`,
                            'Content-Type': 'application/json',
                        },
                        body: JSON.stringify({
                            expression: `resource_type:${resourceType}`,
                            max_results: 100,
                            with_field: ['context', 'tags'],
                        }),
                        signal: AbortSignal.timeout(15000),
                    }
                );
                if (cloudRes.ok) {
                    const data = await cloudRes.json();
                    return sendJson(res, 200, data);
                }
            }

            // Fallback: Return matching media from active catalog
            const catalog = await fetchFromFirebaseDatabase();
            const list = catalog.length > 0 ? catalog : localWallpapers;
            const filtered = list
                .filter((w) => {
                    const isVid = w.type === 'video' || w.type === 'animated' || Boolean(w.url && w.url.match(/\.(mp4|webm|ogg|mov)$/i));
                    return resourceType === 'video' ? isVid : !isVid;
                })
                .map((w) => ({
                    public_id: w.id || w.name,
                    secure_url: w.url,
                    thumbnail_url: w.thumbnailUrl || null,
                    width: w.width || 1920,
                    height: w.height || 1080,
                    format: resourceType === 'video' ? 'mp4' : 'png',
                    resource_type: resourceType,
                }));
            return sendJson(res, 200, { resources: filtered });
        } catch (err) {
            return sendJson(res, 200, { resources: [], error: err.message });
        }
    }

    // GET /api/server-url - Returns active server URL and detected network IP
    if (pathname === '/api/server-url' && req.method === 'GET') {
        const localIp = getNetworkIp();
        const activeUrl = process.env.PUBLIC_SERVER_URL || `http://${localIp}:${PORT}`;
        return sendJson(res, 200, {
            success: true,
            serverUrl: activeUrl,
            localIp: localIp,
            port: PORT,
            rtdbBase: FIREBASE_RTDB_BASE_URL
        });
    }

    // POST /api/server-url - Allows setting/publishing server URL to Firebase Realtime Database
    if (pathname === '/api/server-url' && req.method === 'POST') {
        try {
            const body = await parseJsonBody(req);
            let urlToSync = (body && body.serverUrl || '').trim();
            if (!urlToSync) {
                const localIp = getNetworkIp();
                urlToSync = `http://${localIp}:${PORT}`;
            }
            if (!/^https?:\/\//i.test(urlToSync)) {
                urlToSync = `http://${urlToSync}`;
            }
            urlToSync = urlToSync.replace(/\/+$/, '');

            const ok = await syncServerUrlToFirebase(urlToSync, true);
            if (!ok) {
                return sendJson(res, 502, {
                    success: false,
                    error: 'Failed to write server URL to Firebase Realtime Database.'
                });
            }

            return sendJson(res, 200, {
                success: true,
                message: 'Server URL successfully synchronized to Firebase Realtime Database.',
                serverUrl: urlToSync
            });
        } catch (err) {
            return sendJson(res, 400, { error: err.message });
        }
    }

    // ─────────────────────────────────────────────────────────────
    // STATIC FILE HOSTING & FIREBASE CONFIG FALLBACK
    // ─────────────────────────────────────────────────────────────

    // Special handling for firebase-config.js:
    if (pathname === '/firebase-config.js') {
        const diskConfigPath = path.join(STATIC_DIR, 'firebase-config.js');
        if (fs.existsSync(diskConfigPath)) {
            const content = fs.readFileSync(diskConfigPath, 'utf8');
            if (!content.includes('REPLACE_WITH_FIREBASE_WEB_API_KEY')) {
                res.writeHead(200, { 'Content-Type': 'application/javascript; charset=utf-8' });
                res.end(content);
                return;
            }
        }

        const firebaseWebApiKey = (process.env.FIREBASE_WEB_API_KEY || '').trim();
        if (firebaseWebApiKey) {
            const firebaseConfig = {
                apiKey: firebaseWebApiKey,
                authDomain: 'wallsync-e043c.firebaseapp.com',
                databaseURL: FIREBASE_RTDB_BASE_URL,
                projectId: 'wallsync-e043c',
                appId: '1:273002033077:web:239a7aa71bb6ff8faa33fc',
            };
            res.writeHead(200, { 'Content-Type': 'application/javascript; charset=utf-8' });
            res.end(`window.WALLSYNC_FIREBASE_CONFIG = ${JSON.stringify(firebaseConfig)};`);
            return;
        }

        // Virtual local server fallback configuration
        const virtualConfig = `/**
 * WallSync Virtual Configuration (Local Server Mode)
 * Provided automatically by admin_panel/server.js.
 */
window.WALLSYNC_FIREBASE_CONFIG = {
    apiKey: "LOCAL_SERVER_MODE",
    authDomain: "127.0.0.1",
    databaseURL: "http://127.0.0.1:${PORT}",
    projectId: "wallsync-local",
    storageBucket: "wallsync-local.appspot.com",
    messagingSenderId: "123456789",
    appId: "wallsync-local-app",
    isLocalServer: true,
    serverUrl: "http://127.0.0.1:${PORT}"
};
`;
        res.writeHead(200, { 'Content-Type': 'application/javascript; charset=utf-8' });
        res.end(virtualConfig);
        return;
    }

    // Serve application assets from WALLSYNC/assets
    if (pathname.startsWith('/assets/')) {
        let assetRel;
        try {
            assetRel = decodeURIComponent(pathname.slice('/assets/'.length));
        } catch (_) {
            res.writeHead(400, { 'Content-Type': 'text/plain; charset=utf-8' });
            res.end('400 Bad Request');
            return;
        }
        const assetFilePath = path.resolve(ASSETS_DIR, assetRel);
        const relativeAssetPath = path.relative(ASSETS_DIR, assetFilePath);
        if (
            relativeAssetPath &&
            relativeAssetPath !== '..' &&
            !relativeAssetPath.startsWith(`..${path.sep}`) &&
            !path.isAbsolute(relativeAssetPath) &&
            fs.existsSync(assetFilePath)
        ) {
            const ext = path.extname(assetFilePath).toLowerCase();
            const contentType = MIME_TYPES[ext] || 'application/octet-stream';
            res.writeHead(200, { 'Content-Type': contentType });
            fs.createReadStream(assetFilePath).pipe(res);
            return;
        }
    }

    const publicFile = PUBLIC_FILES.get(pathname);
    if (!publicFile) {
        res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
        res.end('404 Not Found');
        return;
    }
    const filePath = path.join(STATIC_DIR, publicFile);

    fs.stat(filePath, (err, stats) => {
        if (err || !stats.isFile()) {
            res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
            res.end('404 Not Found');
            return;
        }

        const ext = path.extname(filePath).toLowerCase();
        const contentType = MIME_TYPES[ext] || 'application/octet-stream';

        res.writeHead(200, {
            'Content-Type': contentType,
            'Content-Length': stats.size,
        });

        const readStream = fs.createReadStream(filePath);
        readStream.pipe(res);
    });
});

function getNetworkIp() {
    try {
        const interfaces = os.networkInterfaces();
        // Priority 1: Match Wi-Fi, Wireless, or WLAN adapters
        for (const name of Object.keys(interfaces)) {
            const lower = name.toLowerCase();
            if (lower.includes('wi-fi') || lower.includes('wireless') || lower.includes('wlan')) {
                for (const iface of interfaces[name]) {
                    if (iface.family === 'IPv4' && !iface.internal && !iface.address.startsWith('169.254.') && !iface.address.startsWith('192.168.56.')) {
                        return iface.address;
                    }
                }
            }
        }
        // Priority 2: Standard Ethernet (exclude virtual/bluetooth/loopback/host-only)
        for (const name of Object.keys(interfaces)) {
            const lower = name.toLowerCase();
            if (lower.includes('virtual') || lower.includes('vethernet') || lower.includes('wsl') || lower.includes('vmware') || lower.includes('bluetooth') || lower.includes('loopback')) {
                continue;
            }
            for (const iface of interfaces[name]) {
                if (iface.family === 'IPv4' && !iface.internal && !iface.address.startsWith('169.254.') && !iface.address.startsWith('192.168.56.')) {
                    return iface.address;
                }
            }
        }
        // Priority 3: Any non-internal IPv4 that is not link-local
        for (const name of Object.keys(interfaces)) {
            for (const iface of interfaces[name]) {
                if (iface.family === 'IPv4' && !iface.internal && !iface.address.startsWith('169.254.')) {
                    return iface.address;
                }
            }
        }
    } catch (_) {}
    return '127.0.0.1';
}

async function syncServerUrlToFirebase(urlToPublish, force = false) {
    // Avoid overwriting live Firebase RTDB during automated unit tests unless forced
    if (!force && (process.env.NODE_ENV === 'test' || PORT === 3099)) {
        return true;
    }
    try {
        const rtdbBase = FIREBASE_RTDB_BASE_URL;
        const parsed = new URL(urlToPublish);
        const serverPayload = {
            serverUrl: urlToPublish,
            ip: parsed.hostname,
            port: parsed.port ? parseInt(parsed.port, 10) : (parsed.protocol === 'https:' ? 443 : 80),
            updatedAt: new Date().toISOString()
        };
        await fetch(`${rtdbBase}/server.json`, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(serverPayload)
        });
        await fetch(`${rtdbBase}/serverUrl.json`, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(urlToPublish)
        });
        await fetch(`${rtdbBase}/config.json`, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ serverUrl: urlToPublish })
        });
        console.log(`  RTDB Dynamic IP:  Published dynamic server URL to Firebase (${urlToPublish})`);
        return true;
    } catch (e) {
        console.warn(`  RTDB Dynamic IP:  Notice: Could not publish server URL to Firebase (${e.message})`);
        return false;
    }
}

// Start listening
server.listen(PORT, HOST, () => {
    console.log(`====================================================`);
    console.log(`  WallSync Admin Server is running!`);
    console.log(`  Local URL:        http://127.0.0.1:${PORT}`);
    console.log(`  Network access:   disabled (loopback only)`);
    console.log(`  Live Sync API:    http://127.0.0.1:${PORT}/api/sync/heartbeat`);
    console.log(`  Users Stats API:  http://127.0.0.1:${PORT}/api/users/stats`);
    console.log(`====================================================`);
});

module.exports = server;

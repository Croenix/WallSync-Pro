const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');

const dataDir = path.join(__dirname, '..', 'data');
const preservedDataFiles = ['popup.json', 'popup_pro.json', 'wallpapers.json'].map((name) => {
    const filePath = path.join(dataDir, name);
    return {
        filePath,
        contents: fs.existsSync(filePath) ? fs.readFileSync(filePath) : null,
    };
});

test.after(() => {
    for (const { filePath, contents } of preservedDataFiles) {
        if (contents === null) {
            if (fs.existsSync(filePath)) fs.unlinkSync(filePath);
        } else {
            fs.writeFileSync(filePath, contents);
        }
    }
});

// Use port 3099 for isolated unit testing
process.env.PORT = '3099';
process.env.CLOUDINARY_CLOUD_NAME = 'test-cloud';
process.env.CLOUDINARY_UPLOAD_PRESET = 'test-preset';
const server = require('../server.js');

function request(options, postData = null) {
    return new Promise((resolve, reject) => {
        const req = http.request(
            {
                hostname: '127.0.0.1',
                port: 3099,
                ...options,
            },
            (res) => {
                let body = '';
                res.on('data', (chunk) => (body += chunk));
                res.on('end', () => {
                    let json = null;
                    try {
                        json = JSON.parse(body);
                    } catch (_) {}
                    resolve({
                        statusCode: res.statusCode,
                        headers: res.headers,
                        body,
                        json,
                    });
                });
            },
        );

        req.on('error', reject);

        if (postData) {
            req.write(typeof postData === 'string' ? postData : JSON.stringify(postData));
        }
        req.end();
    });
}

test('GET /api/status returns 200 and online status', async () => {
    const res = await request({ path: '/api/status', method: 'GET' });
    assert.equal(res.statusCode, 200);
    assert.equal(res.json.status, 'online');
    assert.equal(res.json.port, 3099);
    assert.equal(typeof res.json.totalUsers, 'number');
    assert.equal(typeof res.json.liveUsers, 'number');
});

test('GET /firebase-config.js returns virtual fallback configuration', async () => {
    const previousApiKey = process.env.FIREBASE_WEB_API_KEY;
    delete process.env.FIREBASE_WEB_API_KEY;
    try {
        const res = await request({ path: '/firebase-config.js', method: 'GET' });
        assert.equal(res.statusCode, 200);
        assert.match(res.body, /WALLSYNC_FIREBASE_CONFIG/);
        assert.match(res.body, /isLocalServer:\s*true/);
        assert.match(res.body, /LOCAL_SERVER_MODE/);
    } finally {
        if (previousApiKey !== undefined) {
            process.env.FIREBASE_WEB_API_KEY = previousApiKey;
        }
    }
});

test('GET /firebase-config.js serves Firebase configuration from the Web API key environment variable', async () => {
    const previousApiKey = process.env.FIREBASE_WEB_API_KEY;
    process.env.FIREBASE_WEB_API_KEY = 'test-web-api-key';
    try {
        const res = await request({ path: '/firebase-config.js', method: 'GET' });
        assert.equal(res.statusCode, 200);
        assert.match(res.body, /"apiKey":"test-web-api-key"/);
        assert.match(res.body, /"projectId":"wallsync-e043c"/);
        assert.doesNotMatch(res.body, /LOCAL_SERVER_MODE/);
    } finally {
        if (previousApiKey === undefined) {
            delete process.env.FIREBASE_WEB_API_KEY;
        } else {
            process.env.FIREBASE_WEB_API_KEY = previousApiKey;
        }
    }
});

test('GET / serves index.html', async () => {
    const res = await request({ path: '/', method: 'GET' });
    assert.equal(res.statusCode, 200);
    assert.match(res.headers['content-type'], /text\/html/);
    assert.match(res.body, /WallSync/);
});

test('server binds only to loopback and does not serve private files', async () => {
    assert.equal(server.address().address, '127.0.0.1');

    for (const pathname of [
        '/server.js',
        '/.env',
        '/data/users.json',
        '/data/cloudinary.json',
    ]) {
        const res = await request({ path: pathname, method: 'GET' });
        assert.equal(res.statusCode, 404, `${pathname} should not be served`);
    }

    const hostileOriginRes = await request({
        path: '/api/status',
        method: 'GET',
        headers: { Origin: 'https://attacker.example' },
    });
    assert.equal(hostileOriginRes.statusCode, 403);

    const hostileHostRes = await request({
        path: '/api/status',
        method: 'GET',
        headers: { Host: 'attacker.example:3099' },
    });
    assert.equal(hostileHostRes.statusCode, 403);
});

test('POST /api/sync/heartbeat requires clientId', async () => {
    const res = await request(
        {
            path: '/api/sync/heartbeat',
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
        },
        { hostname: 'test-pc' },
    );
    assert.equal(res.statusCode, 400);
    assert.match(res.json.error, /clientId/);
});

test('POST /api/sync/heartbeat registers client and updates live stats', async () => {
    const testClientId = 'unit_test_client_' + Date.now();
    const res = await request(
        {
            path: '/api/sync/heartbeat',
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
        },
        {
            clientId: testClientId,
            hostname: 'Unit-Test-Machine',
            platform: 'windows',
            appVersion: '1.0.1+0',
            activeWallpaper: 'test_wallpaper.mp4',
            activeWallpaperType: 'video',
            timestamp: new Date().toISOString(),
        },
    );

    assert.equal(res.statusCode, 200);
    assert.equal(res.json.success, true);
    assert.equal(res.json.clientId, testClientId);
    assert.ok(res.json.liveUsers >= 1);
    assert.ok(res.json.totalUsers >= 1);

    // Verify stats endpoint reflects registered user
    const statsRes = await request({ path: '/api/users/stats', method: 'GET' });
    assert.equal(statsRes.statusCode, 200);
    assert.equal(statsRes.json.success, true);
    assert.ok(statsRes.json.totalUsers >= 1);
    assert.ok(statsRes.json.liveUsers >= 1);
    const found = statsRes.json.activeClients.some((c) => c.clientId === testClientId);
    assert.equal(found, true);
});

test('POST /api/devices/clear clears all registered devices and resets count to 0', async () => {
    const res = await request({ path: '/api/devices/clear', method: 'POST' });
    assert.equal(res.statusCode, 200);
    assert.equal(res.json.success, true);
    assert.equal(res.json.totalDevices, 0);
    assert.equal(res.json.liveDevices, 0);

    const statsRes = await request({ path: '/api/devices/stats', method: 'GET' });
    assert.equal(statsRes.statusCode, 200);
    assert.equal(statsRes.json.totalDevices, 0);
    assert.equal(statsRes.json.liveDevices, 0);
});

test('deviceId ensures a single physical device is not counted as multiple devices', async () => {
    // Clear first to verify exact count
    await request({ path: '/api/devices/clear', method: 'POST' });

    const sharedDeviceId = 'dev_test_machine_uuid_999';

    // First ping with session 1
    const ping1 = await request(
        {
            path: '/api/sync/heartbeat',
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
        },
        {
            deviceId: sharedDeviceId,
            clientId: 'user_session_alpha_1',
            hostname: 'My-Laptop',
            platform: 'windows',
        },
    );
    assert.equal(ping1.statusCode, 200);
    assert.equal(ping1.json.totalDevices, 1);

    // Second ping from same machine with session 2 (e.g. app restart or overlay)
    const ping2 = await request(
        {
            path: '/api/sync/heartbeat',
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
        },
        {
            deviceId: sharedDeviceId,
            clientId: 'user_session_beta_2',
            hostname: 'My-Laptop',
            platform: 'windows',
        },
    );
    assert.equal(ping2.statusCode, 200);
    // Count MUST remain 1 because deviceId is identical!
    assert.equal(ping2.json.totalDevices, 1);
    assert.equal(ping2.json.liveDevices, 1);

    // Verify stats endpoint also shows exactly 1 registered device
    const statsRes = await request({ path: '/api/devices/stats', method: 'GET' });
    assert.equal(statsRes.json.totalDevices, 1);
    assert.equal(statsRes.json.liveDevices, 1);

    // Clean up
    await request({ path: '/api/devices/clear', method: 'POST' });
});

test('POST and GET /api/wallpapers supports local storage fallback', async () => {
    const sample = {
        id: 'test_local_wallpaper_001',
        name: 'Neon Cyber City Loop',
        category: 'Cyberpunk',
        type: 'video',
        url: 'https://assets.example.com/videos/neon.mp4',
        thumbnailUrl: 'https://assets.example.com/videos/neon.jpg',
    };

    const postRes = await request(
        {
            path: '/api/wallpapers',
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
        },
        sample,
    );
    assert.equal(postRes.statusCode, 200);
    assert.equal(postRes.json.success, true);

    const getRes = await request({ path: '/api/wallpapers', method: 'GET' });
    assert.equal(getRes.statusCode, 200);
    assert.equal(getRes.json.success, true);
    assert.ok(Array.isArray(getRes.json.wallpapers));
    const found = getRes.json.wallpapers.some((w) => w.id === sample.id);
    assert.equal(found, true);
});

test('GET /api/database/wallpapers returns synced database wallpapers', async () => {
    const res = await request({ path: '/api/database/wallpapers', method: 'GET' });
    assert.equal(res.statusCode, 200);
    assert.equal(res.json.success, true);
    assert.equal(typeof res.json.count, 'number');
    assert.ok(Array.isArray(res.json.wallpapers));
    assert.ok(res.json.count > 0);

    // Verify properties of catalog items
    const item = res.json.wallpapers[0];
    assert.ok(item.id);
    assert.ok(item.name);
    assert.ok(item.url);
});

test('POST /api/database/delete removes wallpaper from catalog', async () => {
    const deleteId = 'test_local_wallpaper_001';
    const res = await request(
        {
            path: '/api/database/delete',
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
        },
        { id: deleteId },
    );
    assert.equal(res.statusCode, 200);
    assert.equal(res.json.success, true);
    assert.equal(res.json.id, deleteId);

    // Verify it is no longer in local wallpapers
    const checkRes = await request({ path: '/api/wallpapers', method: 'GET' });
    assert.equal(checkRes.statusCode, 200);
    const stillExists = checkRes.json.wallpapers.some((w) => w.id === deleteId);
    assert.equal(stillExists, false);
});

test('POST /api/database/update modifies wallpaper metadata', async () => {
    const updatePayload = {
        id: 'test_edit_wallpaper_001',
        name: 'Edited Wallpaper Title',
        category: 'Abstract',
        type: 'video',
        url: 'https://assets.example.com/videos/edited.mp4',
        thumbnailUrl: 'https://assets.example.com/videos/edited.jpg',
        description: 'New updated description',
        tags: ['edited', 'test', 'rtdb'],
    };

    const res = await request(
        {
            path: '/api/database/update',
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
        },
        updatePayload,
    );
    assert.equal(res.statusCode, 200);
    assert.equal(res.json.success, true);
    assert.equal(res.json.wallpaper.name, 'Edited Wallpaper Title');
    assert.equal(res.json.wallpaper.description, 'New updated description');
    assert.equal(res.json.wallpaper.category, 'Abstract');
    assert.equal(res.json.wallpaper.type, 'video');

    // Cleanup test wallpaper from RTDB and local
    await request(
        {
            path: '/api/database/delete',
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
        },
        { id: 'test_edit_wallpaper_001' },
    );
});

test('Cloudinary config is read from environment and cannot be saved to disk', async () => {
    const cloudinaryFile = path.join(dataDir, 'cloudinary.json');
    const cloudinaryContents = fs.existsSync(cloudinaryFile)
        ? fs.readFileSync(cloudinaryFile)
        : null;
    const postRes = await request(
        {
            path: '/api/cloudinary-config',
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
        },
        { cloudName: 'test-cloud', uploadPreset: 'test-preset', apiSecret: 'must-not-persist' },
    );
    assert.equal(postRes.statusCode, 410);

    const getRes = await request({ path: '/api/cloudinary-config', method: 'GET' });
    assert.equal(getRes.statusCode, 200);
    assert.equal(getRes.json.success, true);
    assert.equal(getRes.json.cloudName, 'test-cloud');
    assert.equal(getRes.json.uploadPreset, 'test-preset');
    if (cloudinaryContents === null) {
        assert.equal(fs.existsSync(cloudinaryFile), false);
    } else {
        assert.deepEqual(fs.readFileSync(cloudinaryFile), cloudinaryContents);
    }
});

test('POST /api/sign-upload returns upload preset when preset is configured', async () => {
    const res = await request(
        {
            path: '/api/sign-upload',
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
        },
        { folder: 'wallsync_videos' },
    );
    assert.equal(res.statusCode, 200);
    assert.equal(res.json.cloudName, 'test-cloud');
    assert.equal(res.json.uploadPreset, 'test-preset');
    assert.equal(res.json.folder, 'wallsync_videos');
});

test('POST and GET /api/notifications manages push broadcasts and heartbeat synchronization', async () => {
    // 1. Clear any prior notifications
    await request({ path: '/api/notifications/clear', method: 'POST' });

    // 2. Broadcast a push notification
    const postRes = await request(
        {
            path: '/api/notifications/send',
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
        },
        {
            title: 'WallSync 1.0.2 Ready',
            message: 'Performance update is ready for desktop.',
            type: 'update',
            version: '1.0.2',
        },
    );
    assert.equal(postRes.statusCode, 200);
    assert.equal(postRes.json.success, true);
    assert.equal(postRes.json.notification.title, 'WallSync 1.0.2 Ready');
    assert.equal(postRes.json.notification.version, '1.0.2');

    // 3. GET /api/notifications returns the list and latest notification
    const getRes = await request({ path: '/api/notifications', method: 'GET' });
    assert.equal(getRes.statusCode, 200);
    assert.equal(getRes.json.count, 1);
    assert.equal(getRes.json.latest.title, 'WallSync 1.0.2 Ready');

    // 4. Heartbeat includes latestNotification in payload
    const hbRes = await request(
        {
            path: '/api/sync/heartbeat',
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
        },
        {
            deviceId: 'test_notif_device_1',
            clientId: 'client_1',
            hostname: 'Desktop-Notif-Test',
        },
    );
    assert.equal(hbRes.statusCode, 200);
    assert.ok(hbRes.json.latestNotification);
    assert.equal(hbRes.json.latestNotification.title, 'WallSync 1.0.2 Ready');

    // 5. Clear notifications
    const clearRes = await request({ path: '/api/notifications/clear', method: 'POST' });
    assert.equal(clearRes.statusCode, 200);
    assert.equal(clearRes.json.success, true);

    const afterClear = await request({ path: '/api/notifications', method: 'GET' });
    assert.equal(afterClear.json.count, 0);

    // Clean up device created during test
    await request({ path: '/api/devices/clear', method: 'POST' });
});

test('GET /api/server-url returns dynamic server URL and network IP', async () => {
    const res = await request({ path: '/api/server-url', method: 'GET' });
    assert.equal(res.statusCode, 200);
    assert.equal(res.json.success, true);
    assert.ok(res.json.serverUrl.startsWith('http'));
    assert.ok(res.json.localIp);
    assert.equal(res.json.port, 3099);
});

test('GET and POST /api/popup manages launch popup configuration', async () => {
    // 1. Initial GET
    const initialGet = await request({ path: '/api/popup', method: 'GET' });
    assert.equal(initialGet.statusCode, 200);
    assert.equal(initialGet.json.success, true);
    assert.ok(initialGet.json.popup);

    // 2. Update popup config via POST
    const updateRes = await request(
        { path: '/api/popup', method: 'POST' },
        {
            enabled: true,
            imageUrl: 'https://example.com/promo-poster.jpg',
            actionText: 'Explore Now',
            actionUrl: 'https://example.com/promo',
        },
    );
    assert.equal(updateRes.statusCode, 200);
    assert.equal(updateRes.json.success, true);
    assert.equal(updateRes.json.popup.enabled, true);
    assert.equal(updateRes.json.popup.imageUrl, 'https://example.com/promo-poster.jpg');
    assert.equal(updateRes.json.popup.actionText, 'Explore Now');
    assert.equal(updateRes.json.popup.actionUrl, 'https://example.com/promo');

    // 3. Verify via GET /api/popup
    const verifyGet = await request({ path: '/api/popup', method: 'GET' });
    assert.equal(verifyGet.statusCode, 200);
    assert.equal(verifyGet.json.popup.enabled, true);
    assert.equal(verifyGet.json.popup.imageUrl, 'https://example.com/promo-poster.jpg');

    // 4. Verify heartbeat returns popup configuration
    const hbRes = await request(
        { path: '/api/sync/heartbeat', method: 'POST' },
        {
            deviceId: 'test_popup_device_1',
            clientId: 'client_popup_1',
        },
    );
    assert.equal(hbRes.statusCode, 200);
    assert.ok(hbRes.json.popup);
    assert.equal(hbRes.json.popup.enabled, true);

    // 5. Restore default disabled state
    await request(
        { path: '/api/popup', method: 'POST' },
        {
            enabled: false,
            imageUrl: '',
            actionText: 'Continue',
            actionUrl: '',
        },
    );
    await request({ path: '/api/devices/clear', method: 'POST' });
});

test('POST /api/wallpapers/migrate normalizes IDs and returns migration count', async () => {
    const res = await request({ path: '/api/wallpapers/migrate', method: 'POST' }, {});
    assert.equal(res.statusCode, 200);
    assert.equal(res.json.success, true);
    assert.equal(typeof res.json.migrated, 'number');
    assert.equal(typeof res.json.total, 'number');
});

test('GET /api/wallpaper-reports returns report records or empty object', async () => {
    const res = await request({ path: '/api/wallpaper-reports', method: 'GET' });
    assert.equal(res.statusCode, 200);
    assert.equal(typeof res.json, 'object');
});

test('GET and POST /api/popup_pro manages launch popup pro configuration', async () => {
    const initialGet = await request({ path: '/api/popup_pro', method: 'GET' });
    assert.equal(initialGet.statusCode, 200);
    assert.equal(initialGet.json.success, true);
    assert.ok(initialGet.json.popup);

    const updateRes = await request(
        { path: '/api/popup_pro', method: 'POST' },
        {
            enabled: true,
            imageUrl: 'https://example.com/pro-poster.jpg',
            actionText: 'Upgrade Pro',
            actionUrl: 'https://example.com/pro',
        },
    );
    assert.equal(updateRes.statusCode, 200);
    assert.equal(updateRes.json.success, true);
    assert.equal(updateRes.json.popup.enabled, true);
    assert.equal(updateRes.json.popup.imageUrl, 'https://example.com/pro-poster.jpg');

    const verifyGet = await request({ path: '/api/popup_pro', method: 'GET' });
    assert.equal(verifyGet.statusCode, 200);
    assert.equal(verifyGet.json.popup.enabled, true);
    assert.equal(verifyGet.json.popup.imageUrl, 'https://example.com/pro-poster.jpg');

    await request(
        { path: '/api/popup_pro', method: 'POST' },
        { enabled: false, imageUrl: '', actionText: 'Continue', actionUrl: '' },
    );
});

test('GET /api/wallpaper_reports_pro returns report records or empty object', async () => {
    const res = await request({ path: '/api/wallpaper_reports_pro', method: 'GET' });
    assert.equal(res.statusCode, 200);
    assert.equal(typeof res.json, 'object');
});

// Clean up server after tests
test.after(() => {
    if (server.closeAllConnections) server.closeAllConnections();
    server.close();
});

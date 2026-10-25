#!/usr/bin/env node
/**
 * WallSync CLI Utility: Add / Update Server URL in Firebase Realtime Database
 * 
 * Usage:
 *   node admin_panel/set_rtdb_url.js                        # Auto-detects active LAN IP (Wi-Fi/Ethernet)
 *   node admin_panel/set_rtdb_url.js http://192.168.1.4:3000 # Sets custom URL
 *   node admin_panel/set_rtdb_url.js https://my-tunnel.ngrok.io
 */

const os = require('os');

const RTDB_BASE = process.env.FIREBASE_RTDB_URL || 'https://wallsync-e043c-default-rtdb.firebaseio.com';
const DEFAULT_PORT = parseInt(process.env.PORT || '3000', 10);

function getBestLanIp() {
    try {
        const interfaces = os.networkInterfaces();
        // Priority 1: Match Wi-Fi, Wireless, or WLAN
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
        // Priority 2: Standard Ethernet (exclude virtual/bluetooth/loopback)
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

function normalizeUrl(inputUrl) {
    let raw = (inputUrl || '').trim();
    if (!raw) {
        const ip = getBestLanIp();
        raw = `http://${ip}:${DEFAULT_PORT}`;
    }
    if (!/^https?:\/\//i.test(raw)) {
        raw = `http://${raw}`;
    }
    return raw.replace(/\/+$/, '');
}

async function updateRtdbServerUrl(targetUrl) {
    const finalUrl = normalizeUrl(targetUrl);
    console.log(`\n======================================================`);
    console.log(`  WallSync Firebase RTDB Server URL Publisher`);
    console.log(`  Target URL:  ${finalUrl}`);
    console.log(`  Firebase DB: ${RTDB_BASE}`);
    console.log(`======================================================\n`);

    const parsed = new URL(finalUrl);
    const ip = parsed.hostname;
    const port = parsed.port ? parseInt(parsed.port, 10) : (parsed.protocol === 'https:' ? 443 : 80);

    const serverObj = {
        serverUrl: finalUrl,
        ip: ip,
        port: port,
        updatedAt: new Date().toISOString()
    };

    try {
        console.log(`[1/3] Writing to ${RTDB_BASE}/serverUrl.json ...`);
        const res1 = await fetch(`${RTDB_BASE}/serverUrl.json`, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(finalUrl)
        });
        if (!res1.ok) throw new Error(`Failed to write /serverUrl.json: HTTP ${res1.status} ${res1.statusText}`);
        console.log(`      ✓ /serverUrl.json successfully updated!`);

        console.log(`[2/3] Writing to ${RTDB_BASE}/server.json ...`);
        const res2 = await fetch(`${RTDB_BASE}/server.json`, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(serverObj)
        });
        if (!res2.ok) throw new Error(`Failed to write /server.json: HTTP ${res2.status} ${res2.statusText}`);
        console.log(`      ✓ /server.json successfully updated!`);

        console.log(`[3/3] Writing to ${RTDB_BASE}/config.json ...`);
        const res3 = await fetch(`${RTDB_BASE}/config.json`, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ serverUrl: finalUrl })
        });
        if (!res3.ok) throw new Error(`Failed to write /config.json: HTTP ${res3.status} ${res3.statusText}`);
        console.log(`      ✓ /config.json successfully updated!`);

        console.log(`\n======================================================`);
        console.log(`  SUCCESS: Server URL has been added to RTDB database!`);
        console.log(`  Live URL: ${finalUrl}`);
        console.log(`======================================================\n`);
    } catch (err) {
        console.error(`\n[ERROR] Failed to update Firebase Realtime Database:`, err.message);
        process.exitCode = 1;
    }
}

const inputArg = process.argv[2];
updateRtdbServerUrl(inputArg);

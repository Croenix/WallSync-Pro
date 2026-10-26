const ADMIN_API_URL =
    'https://us-central1-wallsync-e043c.cloudfunctions.net/adminApi';

const MAX_VIDEO_SIZE_BYTES = 100 * 1024 * 1024; // 100 MB Cloudinary limit
const MAX_IMAGE_SIZE_BYTES = 25 * 1024 * 1024; // 25 MB Cloudinary image limit

const state = {
    auth: null,
    user: null,
    galleryType: 'images', // 'images' | 'videos'
    images: [],
    selectedImages: new Set(),
    queue: [],
    videoMode: 'cloudinary', // 'cloudinary' | 'direct'
    selectedVideoFile: null,
    uploadedVideoUrl: null,
    uploadedThumbUrl: null,
    uploadedVideoWidth: 0,
    uploadedVideoHeight: 0,
    staticMode: 'cloudinary', // 'cloudinary' | 'direct'
    selectedStaticFile: null,
    uploadedStaticUrl: null,
    uploadedStaticWidth: 0,
    uploadedStaticHeight: 0,
    isLocalServer: false,
    catalog: [],
    catalogFilterCategory: 'all',
    catalogFilterType: 'all', // 'all' | 'images' | 'videos'
    catalogSearchQuery: '',
    database: null,
    reportRefs: {},
    reportListeners: {},
    reportData: {},
    reportErrors: {},
    selectedReportEmail: null,
    idsMigrated: false,
    wallpaperReportStatus: 'all',
    wallpaperReportSearch: '',
    cloudFunctionsCorsBlocked: false,
};

const els = {
    nav: {
        overview: document.getElementById('nav-overview'),
        reports: document.getElementById('nav-reports'),
        catalog: document.getElementById('nav-catalog'),
        popup: document.getElementById('nav-popup'),
        static: document.getElementById('nav-static'),
        videos: document.getElementById('nav-videos'),
        gallery: document.getElementById('nav-gallery'),
        upload: document.getElementById('nav-upload'),
        account: document.getElementById('nav-credentials'),
        catalogCount: document.getElementById('catalog-nav-count'),
        queueCount: document.getElementById('queue-nav-count'),
    },
    sections: {
        overview: document.getElementById('section-overview'),
        reports: document.getElementById('section-reports'),
        catalog: document.getElementById('section-catalog'),
        popup: document.getElementById('section-popup'),
        static: document.getElementById('section-static'),
        videos: document.getElementById('section-videos'),
        gallery: document.getElementById('section-gallery'),
        upload: document.getElementById('section-upload'),
        account: document.getElementById('section-credentials'),
    },
    overview: {
        totalWallpapers: document.getElementById('dashboard-total-wallpapers'),
        totalImages: document.getElementById('dashboard-total-images'),
        totalVideos: document.getElementById('dashboard-total-videos'),
        liveUsers: document.getElementById('dashboard-live-users'),
        totalDevices: document.getElementById('dashboard-total-devices'),
        serverStatus: document.getElementById('dashboard-server-status'),
        serverUptime: document.getElementById('dashboard-server-uptime'),
        quickAddStatic: document.getElementById('btn-quick-add-static'),
        quickAddVideo: document.getElementById('btn-quick-add-video'),
        quickViewCatalog: document.getElementById('btn-quick-view-catalog'),
        quickBrowseCloudinary: document.getElementById('btn-quick-browse-cloudinary'),
        quickLaunchPopup: document.getElementById('btn-quick-launch-popup'),
        clientsList: document.getElementById('connected-clients-list'),
        clientsEmpty: document.getElementById('clients-empty-notice'),
    },
    static: {
        modeCloudinary: document.getElementById('btn-static-mode-cloudinary'),
        modeDirect: document.getElementById('btn-static-mode-direct'),
        panelCloudinary: document.getElementById('panel-static-cloudinary'),
        panelDirect: document.getElementById('panel-static-direct'),
        fileInput: document.getElementById('static-file-input'),
        fileSizeBadge: document.getElementById('static-file-size-badge'),
        progressContainer: document.getElementById('static-upload-progress-container'),
        progressBar: document.getElementById('static-upload-progress-bar'),
        uploadStatus: document.getElementById('static-upload-status'),
        uploadPercent: document.getElementById('static-upload-percent'),
        directUrlInput: document.getElementById('static-direct-url-input'),
        previewWrapper: document.getElementById('static-preview-wrapper'),
        previewElement: document.getElementById('static-preview-element'),
        specsText: document.getElementById('static-specs-text'),
        idInput: document.getElementById('static-id-input'),
        titleInput: document.getElementById('static-title-input'),
        categoryInput: document.getElementById('static-category-input'),
        tagsInput: document.getElementById('static-tags-input'),
        descriptionInput: document.getElementById('static-description-input'),
        isProInput: document.getElementById('static-is-pro-input'),
        addToQueue: document.getElementById('btn-add-static-to-queue'),
        saveDirect: document.getElementById('btn-save-static-direct'),
    },
    status: {
        dot: document.getElementById('firebase-status-dot'),
        text: document.getElementById('firebase-status-text'),
    },
    signin: {
        card: document.getElementById('signin-card'),
        form: document.getElementById('signin-form'),
        button: document.getElementById('btn-signin'),
        status: document.getElementById('signin-status'),
        email: document.getElementById('admin-email'),
        password: document.getElementById('admin-password'),
    },
    account: {
        card: document.getElementById('account-card'),
        email: document.getElementById('account-email'),
        signout: document.getElementById('btn-signout'),
    },
    cloudinary: {
        card: document.getElementById('cloudinary-config-card'),
        form: document.getElementById('cloudinary-config-form'),
        cloudName: document.getElementById('cloudinary-cloud-name'),
        uploadPreset: document.getElementById('cloudinary-upload-preset'),
        saveBtn: document.getElementById('btn-save-cloudinary-config'),
        status: document.getElementById('cloudinary-config-status'),
    },
    gallery: {
        typeImages: document.getElementById('btn-gallery-type-images'),
        typeVideos: document.getElementById('btn-gallery-type-videos'),
        grid: document.getElementById('gallery-grid'),
        loading: document.getElementById('gallery-loading'),
        loadingText: document.getElementById('gallery-loading-text'),
        refresh: document.getElementById('btn-refresh-gallery'),
        process: document.getElementById('btn-process-selected'),
        selectedCount: document.getElementById('selected-count'),
    },
    videos: {
        modeCloudinary: document.getElementById('btn-mode-cloudinary'),
        modeDirectUrl: document.getElementById('btn-mode-direct-url'),
        panelCloudinary: document.getElementById('panel-cloudinary-upload'),
        panelDirect: document.getElementById('panel-direct-url'),
        fileInput: document.getElementById('video-file-input'),
        fileSizeBadge: document.getElementById('video-file-size-badge'),
        progressContainer: document.getElementById('video-upload-progress-container'),
        progressBar: document.getElementById('video-upload-progress-bar'),
        uploadStatus: document.getElementById('video-upload-status'),
        uploadPercent: document.getElementById('video-upload-percent'),
        directUrlInput: document.getElementById('direct-video-url-input'),
        previewWrapper: document.getElementById('video-preview-wrapper'),
        previewElement: document.getElementById('video-preview-element'),
        specsText: document.getElementById('video-specs-text'),
        idInput: document.getElementById('video-id-input'),
        titleInput: document.getElementById('video-title-input'),
        categoryInput: document.getElementById('video-category-input'),
        thumbnailInput: document.getElementById('video-thumbnail-input'),
        tagsInput: document.getElementById('video-tags-input'),
        descriptionInput: document.getElementById('video-description-input'),
        isProInput: document.getElementById('video-is-pro-input'),
        addToQueue: document.getElementById('btn-add-video-to-queue'),
        saveDirect: document.getElementById('btn-save-video-direct'),
    },
    queue: {
        list: document.getElementById('queue-list'),
        uploadAll: document.getElementById('btn-bulk-upload'),
    },
    liveSync: {
        indicator: document.getElementById('live-sync-indicator'),
        dot: document.getElementById('live-users-dot'),
        liveCount: document.getElementById('live-users-count'),
        totalCount: document.getElementById('total-users-count'),
        serverCard: document.getElementById('server-status-card'),
        serverDot: document.getElementById('server-status-dot'),
        serverText: document.getElementById('server-status-text'),
        serverPortTag: document.getElementById('server-port-tag'),
        cardLiveCount: document.getElementById('card-live-users-count'),
        cardTotalCount: document.getElementById('card-total-users-count'),
        localBanner: document.getElementById('local-mode-banner'),
        localDescription: document.getElementById('local-mode-description'),
    },
    catalog: {
        typeAll: document.getElementById('btn-catalog-type-all'),
        typeImages: document.getElementById('btn-catalog-type-images'),
        typeVideos: document.getElementById('btn-catalog-type-videos'),
        refresh: document.getElementById('btn-refresh-catalog'),
        searchInput: document.getElementById('catalog-search-input'),
        categorySelect: document.getElementById('catalog-category-select'),
        summaryText: document.getElementById('catalog-summary-text'),
        loading: document.getElementById('catalog-loading'),
        loadingText: document.getElementById('catalog-loading-text'),
        grid: document.getElementById('catalog-grid'),
        modal: document.getElementById('catalog-preview-modal'),
        modalTitle: document.getElementById('modal-wallpaper-title'),
        modalClose: document.getElementById('btn-close-modal'),
        modalMedia: document.getElementById('modal-media-container'),
        modalDetails: document.getElementById('modal-wallpaper-details'),
        editModal: document.getElementById('catalog-edit-modal'),
        modalEditHeading: document.getElementById('modal-edit-heading'),
        btnCloseEditModal: document.getElementById('btn-close-edit-modal'),
        formEditWallpaper: document.getElementById('form-edit-wallpaper'),
        editWallpaperId: document.getElementById('edit-wallpaper-id'),
        editPreviewImage: document.getElementById('edit-preview-image'),
        editPreviewPlaceholder: document.getElementById('edit-preview-placeholder'),
        editIdDisplay: document.getElementById('edit-id-display'),
        editTitleInput: document.getElementById('edit-title-input'),
        editCategoryInput: document.getElementById('edit-category-input'),
        editTypeSelect: document.getElementById('edit-type-select'),
        editUrlInput: document.getElementById('edit-url-input'),
        editThumbnailInput: document.getElementById('edit-thumbnail-input'),
        editTagsInput: document.getElementById('edit-tags-input'),
        editDescriptionInput: document.getElementById('edit-description-input'),
        editIsProInput: document.getElementById('edit-is-pro-input'),
        btnCancelEdit: document.getElementById('btn-cancel-edit'),
        btnSaveEdit: document.getElementById('btn-save-edit'),
    },
    popup: {
        badge: document.getElementById('popup-status-badge'),
        toggle: document.getElementById('popup-enabled-toggle'),
        form: document.getElementById('popup-config-form'),
        imageUrl: document.getElementById('popup-image-url'),
        actionText: document.getElementById('popup-action-text'),
        actionUrl: document.getElementById('popup-action-url'),
        saveBtn: document.getElementById('btn-save-popup'),
        saveStatus: document.getElementById('popup-save-status'),
        previewCloseBtn: document.getElementById('preview-popup-close-btn'),
        previewPosterImg: document.getElementById('preview-poster-img'),
        previewPlaceholder: document.getElementById('preview-image-placeholder'),
        previewActionBtn: document.getElementById('preview-action-btn'),
        previewActionText: document.getElementById('preview-action-btn-text'),
    },
};

function switchSection(section) {
    const validSections = ['overview', 'reports', 'catalog', 'popup', 'static', 'videos', 'gallery', 'upload', 'account'];
    validSections.forEach((s) => {
        if (els.nav[s]) els.nav[s].classList.remove('active');
        if (els.sections[s]) els.sections[s].classList.remove('active');
    });
    if (els.nav[section]) els.nav[section].classList.add('active');
    if (els.sections[section]) els.sections[section].classList.add('active');
}

function setConnectionStatus(connected, message) {
    els.status.dot.className = connected ? 'dot connected' : 'dot disconnected';
    els.status.text.textContent = message;
}

function showToast(message, type = 'success') {
    const container = document.getElementById('toast-container');
    const toast = document.createElement('div');
    toast.className = `toast ${type}`;
    const text = document.createElement('span');
    text.textContent = message;
    toast.appendChild(text);
    container.appendChild(toast);

    setTimeout(() => {
        toast.style.animation = 'fadeOut 0.3s ease-out forwards';
        setTimeout(() => toast.remove(), 300);
    }, 3000);
}

function setSigninStatus(message, type = '') {
    els.signin.status.className = `status-message${type ? ` ${type}` : ''}`;
    els.signin.status.textContent = message;
    els.signin.status.style.display = message ? 'block' : 'none';
}

function updateNavQueueCount() {
    const count = String(state.queue.length);
    els.nav.queueCount.textContent = count;
    els.nav.upload.disabled = !state.user || state.queue.length === 0;
}

function setAuthenticatedUser(user) {
    state.user = user;
    const signedIn = Boolean(user);
    els.signin.card.classList.toggle('hidden', signedIn);
    els.account.card.classList.toggle('hidden', !signedIn);
    els.nav.gallery.disabled = !signedIn;
    els.nav.videos.disabled = false;
    els.nav.static.disabled = false;
    updateNavQueueCount();
    setConnectionStatus(signedIn, signedIn ? 'Signed in' : 'Disconnected');

    if (signedIn) {
        subscribeToReports();
        els.account.email.textContent = user.email || user.uid;
        setSigninStatus('');
        if (els.sections.account.classList.contains('active')) {
            switchSection('overview');
        }
        fetchCloudinaryMedia();
    } else {
        unsubscribeFromReports();
        state.images = [];
        state.selectedImages.clear();
        els.gallery.grid.replaceChildren();
        updateSelectedCount();
        switchSection('overview');
    }
}

async function adminApi(path, options = {}) {
    if (state.isLocalServer) {
        throw new Error('Cloudinary direct uploads require a Firebase Admin account. Switch to the "Direct URL" tab to publish wallpapers instantly in Local Server Mode.');
    }
    if (!state.auth || !state.auth.currentUser) {
        throw new Error('Sign in with an authorized Firebase account to use Cloud Functions.');
    }

    const token = await state.auth.currentUser.getIdToken();
    const canUseFallback = window.location.protocol.startsWith('http');

    // If Cloud Functions are CORS-blocked or unreachable in this session, use same-origin /api directly
    if (state.cloudFunctionsCorsBlocked && canUseFallback) {
        try {
            const fallbackRes = await fetch(`/api${path}`, {
                ...options,
                headers: {
                    Authorization: `Bearer ${token}`,
                    ...(options.body ? { 'Content-Type': 'application/json' } : {}),
                    ...options.headers,
                },
            });
            const fallbackData = await fallbackRes.json().catch(() => ({}));
            if (fallbackRes.ok) {
                return fallbackData;
            }
        } catch (_) {}
    }

    try {
        const response = await fetch(`${ADMIN_API_URL}${path}`, {
            ...options,
            headers: {
                Authorization: `Bearer ${token}`,
                ...(options.body ? { 'Content-Type': 'application/json' } : {}),
                ...options.headers,
            },
        });

        const data = await response.json().catch(() => ({}));
        if (!response.ok) {
            throw new Error(data.error || `Request failed (${response.status}).`);
        }
        return data;
    } catch (apiError) {
        if (apiError.name === 'TypeError') {
            state.cloudFunctionsCorsBlocked = true;
        }
        if (canUseFallback) {
            try {
                const fallbackRes = await fetch(`/api${path}`, {
                    ...options,
                    headers: {
                        Authorization: `Bearer ${token}`,
                        ...(options.body ? { 'Content-Type': 'application/json' } : {}),
                        ...options.headers,
                    },
                });
                const fallbackData = await fallbackRes.json().catch(() => ({}));
                if (fallbackRes.ok) {
                    return fallbackData;
                }
            } catch (_) {}
        }
        throw apiError;
    }
}

function switchToAccountWithError(message) {
    setConnectionStatus(false, 'Disconnected');
    setSigninStatus(message, 'error');
    switchSection('account');
}

// Sidebar Navigation Listeners
els.nav.overview.addEventListener('click', () => switchSection('overview'));
els.nav.reports.addEventListener('click', () => switchSection('reports'));
els.nav.catalog.addEventListener('click', () => {
    switchSection('catalog');
    fetchCatalogWallpapers();
});
els.nav.popup.addEventListener('click', () => {
    switchSection('popup');
    fetchPopupConfig();
});
els.nav.static.addEventListener('click', () => switchSection('static'));
els.nav.videos.addEventListener('click', () => switchSection('videos'));
els.nav.gallery.addEventListener('click', () => switchSection('gallery'));
els.nav.upload.addEventListener('click', () => switchSection('upload'));
els.nav.account.addEventListener('click', () => switchSection('account'));

// Overview Quick Action Listeners
els.overview.quickAddStatic.addEventListener('click', () => switchSection('static'));
els.overview.quickAddVideo.addEventListener('click', () => switchSection('videos'));
els.overview.quickViewCatalog.addEventListener('click', () => {
    switchSection('catalog');
    fetchCatalogWallpapers();
});
els.overview.quickBrowseCloudinary.addEventListener('click', () => switchSection('gallery'));
if (els.overview.quickLaunchPopup) {
    els.overview.quickLaunchPopup.addEventListener('click', () => {
        switchSection('popup');
        fetchPopupConfig();
    });
}

// Sign In / Sign Out
els.signin.form.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (!state.auth) return;

    els.signin.button.disabled = true;
    els.signin.button.textContent = 'Signing In...';
    setSigninStatus('');
    try {
        await state.auth.signInWithEmailAndPassword(
            els.signin.email.value.trim(),
            els.signin.password.value,
        );
        els.signin.password.value = '';
    } catch (error) {
        setSigninStatus(error.message || 'Unable to sign in.', 'error');
    } finally {
        els.signin.button.disabled = false;
        els.signin.button.textContent = 'Sign In';
    }
});

els.account.signout.addEventListener('click', async () => {
    try {
        await state.auth.signOut();
    } catch (error) {
        showToast(error.message || 'Unable to sign out.', 'error');
    }
});

function configureFirebaseAuth() {
    const config = window.WALLSYNC_FIREBASE_CONFIG;
    if (config && (config.apiKey === 'LOCAL_SERVER_MODE' || config.isLocalServer)) {
        state.isLocalServer = true;
        els.liveSync.localBanner.classList.remove('hidden');
        setConnectionStatus(true, 'Local Server Mode');
        setSigninStatus('Connected to WallSync Node Backend (Direct Sync Active).', 'info');
        setAuthenticatedUser({
            email: 'admin@wallsync.local',
            uid: 'local-admin',
            displayName: 'WallSync Local Admin',
        });
        return;
    }

    if (!window.firebase || !config || !config.apiKey ||
        config.apiKey === 'REPLACE_WITH_FIREBASE_WEB_API_KEY') {
        if (window.location.protocol === 'file:') {
            switchToAccountWithError(
                'Please open http://localhost:3000 in your browser instead of opening this file directly.',
            );
            return;
        }
        switchToAccountWithError(
            'Set FIREBASE_WEB_API_KEY in admin_panel/.env or configure admin_panel/firebase-config.js, then restart the server and reload this page.',
        );
        return;
    }

    try {
        if (!firebase.apps.length) firebase.initializeApp(config);
        state.auth = firebase.auth();
        state.database = firebase.database();
        state.auth.onAuthStateChanged(
            setAuthenticatedUser,
            (error) => switchToAccountWithError(error.message),
        );
    } catch (error) {
        switchToAccountWithError(error.message || 'Firebase Authentication failed.');
    }
}

function renderReportsMessage(message, className = 'clients-empty-notice') {
    const notice = document.createElement('div');
    notice.className = className;
    notice.textContent = message;
    document.getElementById('reports-list').replaceChildren(notice);
}

function unsubscribeFromReports() {
    for (const path of Object.keys(state.reportRefs)) {
        state.reportRefs[path].off('value', state.reportListeners[path]);
    }
    state.reportRefs = {};
    state.reportListeners = {};
    state.reportData = {};
    state.reportErrors = {};
    state.selectedReportEmail = null;
    renderReportsMessage('Sign in with an administrator account to load reports.');
    document.getElementById('wallpaper-reports-list').replaceChildren(
        Object.assign(document.createElement('div'), {
            className: 'clients-empty-notice',
            textContent: 'Sign in with an administrator account to load wallpaper reports.',
        }),
    );
}

function subscribeToReports() {
    unsubscribeFromReports();
    if (state.isLocalServer) {
        renderReportsMessage(
            'Reports require a Firebase connection. Set FIREBASE_WEB_API_KEY in admin_panel/.env, restart the Admin Panel server, reload this page, and sign in with your Firebase administrator account.',
            'reports-error',
        );
        return;
    }
    if (!state.database || !state.auth || !state.auth.currentUser) {
        renderReportsMessage('Connect to Firebase and sign in with an administrator account to view reports.', 'reports-error');
        return;
    }

    for (const path of ['reports', 'reports_pro', 'bugs', 'wallpaperReports', 'wallpaper_reports_pro']) {
        const reference = state.database.ref(path);
        const listener = (snapshot) => {
            state.reportData[path] = snapshot.val();
            delete state.reportErrors[path];
            renderReports(state.reportData);
        };
        state.reportRefs[path] = reference;
        state.reportListeners[path] = listener;
        reference.on('value', listener, (error) => {
            state.reportErrors[path] = error.message;
            renderReports(state.reportData);
            showToast(`Unable to load ${path}: ${error.message}`, 'error');
        });
    }
}

function isProReport(report, path) {
    if (path === 'reports_pro' || path === 'wallpaper_reports_pro') return true;
    if (!report || typeof report !== 'object') return false;
    if (String(report.badge || '').trim().toUpperCase() === 'PRO') return true;
    if (String(report.appType || '').trim().toLowerCase() === 'pro') return true;
    if (String(report.userType || '').trim().toLowerCase() === 'pro') return true;
    if (String(report.plan || '').trim().toLowerCase() === 'pro') return true;
    if (String(report.appVersion || '').toLowerCase().includes('pro')) return true;
    if (report.isPro === true) return true;
    return false;
}

function createReportBadge(isPro) {
    const badge = document.createElement('span');
    badge.className = `report-badge-pill ${isPro ? 'pro' : 'free'}`;
    badge.textContent = isPro ? 'PRO' : 'FREE';
    return badge;
}

function reportTimestampValue(value) {
    if (typeof value === 'number') {
        return value < 1e12 ? value * 1000 : value;
    }
    const parsed = Date.parse(String(value ?? ''));
    return Number.isFinite(parsed) ? parsed : 0;
}

function formatReportValue(key, value) {
    if (value === null || value === undefined || value === '') return '—';
    if (key.toLowerCase() === 'timestamp' || key.toLowerCase() === 'createdat') {
        const timestamp = reportTimestampValue(value);
        return timestamp ? new Date(timestamp).toLocaleString() : String(value);
    }
    if (typeof value === 'object') return JSON.stringify(value, null, 2);
    return String(value);
}

function formatReportTimestamp(report) {
    const value = report.timestamp || report.createdAt;
    const timestamp = reportTimestampValue(value);
    return timestamp ? new Date(timestamp).toLocaleString() : 'Date unavailable';
}

function reportPreview(report) {
    return String(report.title || report.description || report.message || 'Bug report')
        .replace(/\s+/g, ' ')
        .trim();
}

function renderReports(reportsByPath) {
    renderWallpaperReports();
    const list = document.getElementById('reports-list');
    const entries = Object.entries(reportsByPath).flatMap(([path, reports]) =>
        path !== 'wallpaperReports' && path !== 'wallpaper_reports_pro' && reports && typeof reports === 'object'
            ? Object.entries(reports)
                .filter(([, report]) => report && typeof report === 'object')
                .map(([id, report]) => ({ id, path, report }))
            : []);

    if (entries.length === 0) {
        const failedPaths = Object.entries(state.reportErrors);
        if (failedPaths.length > 0) {
            const [path, error] = failedPaths[0];
            renderReportsMessage(`Unable to load ${path}: ${error}`, 'reports-error');
            return;
        }
        renderReportsMessage('No reports have been submitted yet.');
        return;
    }

    const grouped = new Map();
    for (const { id, path, report } of entries) {
        const email = String(report.gmail || report.email || 'Unknown email');
        if (!grouped.has(email)) grouped.set(email, []);
        grouped.get(email).push({ id, path, report });
    }

    for (const userReports of grouped.values()) {
        userReports.sort((a, b) =>
            reportTimestampValue(b.report.timestamp || b.report.createdAt) -
            reportTimestampValue(a.report.timestamp || a.report.createdAt));
    }

    if (!grouped.has(state.selectedReportEmail)) {
        state.selectedReportEmail = grouped.keys().next().value;
    }

    const inbox = document.createElement('div');
    inbox.className = 'reports-inbox-layout';

    const conversations = document.createElement('aside');
    conversations.className = 'reports-conversations';
    const listHeader = document.createElement('div');
    listHeader.className = 'reports-panel-heading';
    const listTitle = document.createElement('h3');
    listTitle.textContent = 'Inbox';
    const totalBadge = document.createElement('span');
    totalBadge.className = 'reports-count';
    totalBadge.textContent = String(entries.length);
    listHeader.append(listTitle, totalBadge);
    conversations.appendChild(listHeader);

    for (const [email, userReports] of grouped) {
        const latest = userReports[0].report;
        const item = document.createElement('button');
        item.type = 'button';
        item.className = `report-conversation${email === state.selectedReportEmail ? ' active' : ''}`;
        item.addEventListener('click', () => {
            state.selectedReportEmail = email;
            renderReports(state.reportData);
        });
        const avatar = document.createElement('span');
        avatar.className = 'report-avatar';
        avatar.textContent = email.charAt(0).toUpperCase();
        const summary = document.createElement('span');
        summary.className = 'report-conversation-summary';
        const sender = document.createElement('span');
        sender.className = 'report-conversation-sender';
        sender.textContent = email;
        const userIsPro = userReports.some(r => isProReport(r.report, r.path));
        sender.appendChild(createReportBadge(userIsPro));
        const preview = document.createElement('span');
        preview.className = 'report-conversation-preview';
        preview.textContent = reportPreview(latest);
        const meta = document.createElement('span');
        meta.className = 'report-conversation-meta';
        const date = document.createElement('span');
        date.textContent = formatReportTimestamp(latest);
        meta.appendChild(date);
        if (userReports.length > 1) {
            const count = document.createElement('span');
            count.className = 'reports-count';
            count.textContent = String(userReports.length);
            meta.appendChild(count);
        }
        summary.append(sender, preview, meta);
        item.append(avatar, summary);
        conversations.appendChild(item);
    }

    const thread = document.createElement('section');
    thread.className = 'report-thread';
    const selectedReports = grouped.get(state.selectedReportEmail) || [];
    const threadHeader = document.createElement('header');
    threadHeader.className = 'report-thread-header';
    const threadAvatar = document.createElement('span');
    threadAvatar.className = 'report-avatar';
    threadAvatar.textContent = state.selectedReportEmail.charAt(0).toUpperCase();
    const identity = document.createElement('div');
    identity.className = 'report-thread-identity';
    const threadEmail = document.createElement('h3');
    threadEmail.textContent = state.selectedReportEmail;
    const selectedIsPro = selectedReports.some(r => isProReport(r.report, r.path));
    threadEmail.appendChild(createReportBadge(selectedIsPro));
    const threadInfo = document.createElement('span');
    threadInfo.textContent = `${selectedReports.length} ${selectedReports.length === 1 ? 'report' : 'reports'}`;
    identity.append(threadEmail, threadInfo);
    threadHeader.append(threadAvatar, identity);

    const messageList = document.createElement('div');
    messageList.className = 'report-message-list';
    const dateLabel = document.createElement('div');
    dateLabel.className = 'report-thread-date';
    dateLabel.textContent = 'BUG REPORTS';
    messageList.appendChild(dateLabel);

    for (const { id, path, report } of selectedReports) {
        const message = document.createElement('article');
        message.className = 'report-message';
        const bubble = document.createElement('div');
        bubble.className = 'report-message-bubble';
        const messageHeader = document.createElement('div');
        messageHeader.className = 'report-message-heading';
        const title = document.createElement('h4');
        title.textContent = String(report.title || report.subject || 'Bug report');
        title.appendChild(createReportBadge(isProReport(report, path)));
        const time = document.createElement('time');
        const timestamp = reportTimestampValue(report.timestamp || report.createdAt);
        if (timestamp) time.dateTime = new Date(timestamp).toISOString();
        time.textContent = formatReportTimestamp(report);
        messageHeader.append(title, time);
        bubble.appendChild(messageHeader);

        const content = report.description || report.message || report.content;
        if (content !== undefined && content !== null && content !== '') {
            const body = document.createElement('p');
            body.className = 'report-message-content';
            body.textContent = formatReportValue('description', content);
            bubble.appendChild(body);
        }

        const extraDetails = Object.entries(report).filter(([key]) =>
            !['gmail', 'email', 'title', 'subject', 'description', 'message', 'content', 'timestamp', 'createdat'].includes(key.toLowerCase()));
        for (const [key, value] of extraDetails) {
            const detail = document.createElement('p');
            detail.className = 'report-message-detail';
            const label = document.createElement('strong');
            label.textContent = `${key.replace(/([A-Z])/g, ' $1').replace(/^./, (char) => char.toUpperCase())}: `;
            const text = document.createElement('span');
            text.textContent = formatReportValue(key, value);
            detail.append(label, text);
            bubble.appendChild(detail);
        }

        const actions = document.createElement('div');
        actions.className = 'report-message-actions';
        const deleteButton = document.createElement('button');
        deleteButton.type = 'button';
        deleteButton.className = 'report-delete-button';
        deleteButton.textContent = 'Delete report';
        deleteButton.addEventListener('click', async () => {
            if (!window.confirm(`Delete this report from ${state.selectedReportEmail}? This cannot be undone.`)) return;
            deleteButton.disabled = true;
            deleteButton.textContent = 'Deleting...';
            try {
                await state.database.ref(`${path}/${id}`).remove();
                showToast('Report deleted.');
            } catch (error) {
                showToast(`Unable to delete report: ${error.message}`, 'error');
                deleteButton.disabled = false;
                deleteButton.textContent = 'Delete report';
            }
        });
        actions.appendChild(deleteButton);
        bubble.appendChild(actions);
        message.appendChild(bubble);
        messageList.appendChild(message);
    }

    thread.append(threadHeader, messageList);
    inbox.append(conversations, thread);
    list.replaceChildren(inbox);
}

function renderWallpaperReports() {
    const list = document.getElementById('wallpaper-reports-list');
    const reports = [
        ...Object.entries(state.reportData.wallpaper_reports_pro || {})
            .map(([id, report]) => ({ id, report, path: 'wallpaper_reports_pro' })),
        ...Object.entries(state.reportData.wallpaperReports || {})
            .map(([id, report]) => ({ id, report, path: 'wallpaperReports' })),
        ...Object.entries(state.reportData.reports_pro || {})
            .filter(([, report]) => report && typeof report === 'object' && report.wallpaperId)
            .map(([id, report]) => ({ id, report, path: 'reports_pro' })),
        ...Object.entries(state.reportData.reports || {})
            .filter(([, report]) => report && typeof report === 'object' && report.wallpaperId)
            .map(([id, report]) => ({ id, report, path: 'reports' })),
    ];
    const query = state.wallpaperReportSearch.trim().toLowerCase();
    const entries = reports
        .filter(({ report }) => report && typeof report === 'object')
        .filter(({ report }) => state.wallpaperReportStatus === 'all' ||
            (report.status || 'pending') === state.wallpaperReportStatus)
        .filter(({ id, report }) => !query || [
            id,
            report.reportId,
            report.wallpaperId,
            report.wallpaperTitle,
            report.userEmail || report.email,
        ].some((value) => String(value || '').toLowerCase().includes(query)))
        .sort((a, b) =>
            reportTimestampValue(b.report.createdAt || b.report.timestamp) -
            reportTimestampValue(a.report.createdAt || a.report.timestamp));

    if (entries.length === 0) {
        const error = state.reportErrors.wallpaperReports;
        const message = error
            ? `Unable to load wallpaper reports: ${error}`
            : query || state.wallpaperReportStatus !== 'all'
                ? 'No wallpaper reports match the current filters.'
                : 'No wallpaper reports have been submitted.';
        list.replaceChildren(Object.assign(document.createElement('div'), {
            className: error ? 'reports-error' : 'clients-empty-notice',
            textContent: message,
        }));
        return;
    }

    const table = document.createElement('table');
    table.className = 'wallpaper-reports-table';
    const thead = document.createElement('thead');
    const header = document.createElement('tr');
    for (const label of ['Report', 'Wallpaper', 'Reporter', 'Description', 'Submitted', 'Status', 'Admin review']) {
        const cell = document.createElement('th');
        cell.textContent = label;
        header.appendChild(cell);
    }
    thead.appendChild(header);
    const tbody = document.createElement('tbody');

    for (const { id, report, path } of entries) {
        const row = document.createElement('tr');
        const reportCell = document.createElement('td');
        reportCell.textContent = id;
        reportCell.className = 'wallpaper-report-id';
        const wallpaperCell = document.createElement('td');
        const wallpaperName = document.createElement('strong');
        wallpaperName.textContent = String(report.wallpaperTitle || 'Untitled wallpaper');
        const wallpaperId = document.createElement('small');
        wallpaperId.textContent = String(report.wallpaperId || 'ID unavailable');
        const wallpaperSpecs = document.createElement('small');
        wallpaperSpecs.textContent =
            `${String(report.wallpaperType || 'type unavailable')} · ${String(report.wallpaperResolution || 'Resolution unavailable')}`;
        const locateButton = document.createElement('button');
        locateButton.type = 'button';
        locateButton.className = 'wallpaper-report-locate';
        locateButton.textContent = 'Locate in catalog';
        locateButton.addEventListener('click', () => {
            switchSection('catalog');
            els.catalog.searchInput.value = String(report.wallpaperId || '');
            state.catalogSearchQuery = els.catalog.searchInput.value;
            renderCatalog();
            fetchCatalogWallpapers(true);
        });
        wallpaperCell.append(wallpaperName, wallpaperId, wallpaperSpecs, locateButton);

        const reporterCell = document.createElement('td');
        const reporterText = document.createElement('span');
        reporterText.textContent = String(report.userEmail || report.email || 'Unknown email');
        reporterCell.append(reporterText, createReportBadge(isProReport(report, path)));
        const descriptionCell = document.createElement('td');
        descriptionCell.className = 'wallpaper-report-description';
        descriptionCell.textContent = String(report.description || '');
        descriptionCell.title = String(report.description || '');
        const submittedCell = document.createElement('td');
        submittedCell.textContent = formatReportTimestamp(report);

        const statusCell = document.createElement('td');
        const status = document.createElement('select');
        status.className = 'wallpaper-report-status';
        for (const value of ['pending', 'reviewing', 'resolved', 'rejected']) {
            const option = document.createElement('option');
            option.value = value;
            option.textContent = value;
            status.appendChild(option);
        }
        status.value = ['pending', 'reviewing', 'resolved', 'rejected'].includes(report.status)
            ? report.status
            : 'pending';
        statusCell.appendChild(status);

        const reviewCell = document.createElement('td');
        const notes = document.createElement('textarea');
        notes.className = 'wallpaper-report-notes';
        notes.maxLength = 2000;
        notes.placeholder = 'Internal admin notes';
        notes.value = String(report.adminNotes || '');
        const save = document.createElement('button');
        save.type = 'button';
        save.className = 'btn primary-btn wallpaper-report-save';
        save.textContent = 'Save';
        save.addEventListener('click', async () => {
            save.disabled = true;
            save.textContent = 'Saving…';
            try {
                await adminApi(`/${path === 'reports' ? 'reports' : 'wallpaper-reports'}/${encodeURIComponent(id)}`, {
                    method: 'PATCH',
                    body: JSON.stringify({
                        status: status.value,
                        adminNotes: notes.value,
                    }),
                });
                showToast('Wallpaper report updated.');
            } catch (error) {
                showToast(`Unable to update wallpaper report: ${error.message}`, 'error');
            } finally {
                save.disabled = false;
                save.textContent = 'Save';
            }
        });
        reviewCell.append(notes, save);
        row.append(
            reportCell,
            wallpaperCell,
            reporterCell,
            descriptionCell,
            submittedCell,
            statusCell,
            reviewCell,
        );
        tbody.appendChild(row);
    }
    table.append(thead, tbody);
    list.replaceChildren(table);
}

document.getElementById('wallpaper-report-search').addEventListener('input', (event) => {
    state.wallpaperReportSearch = event.target.value;
    renderWallpaperReports();
});
document.getElementById('wallpaper-report-status').addEventListener('change', (event) => {
    state.wallpaperReportStatus = event.target.value;
    renderWallpaperReports();
});

function updateSelectedCount() {
    els.gallery.selectedCount.textContent = String(state.selectedImages.size);
    els.gallery.process.disabled = state.selectedImages.size === 0;
}

function showGalleryError(message) {
    const error = document.createElement('div');
    error.className = 'gallery-error';
    error.style.gridColumn = '1 / -1';
    error.style.textAlign = 'center';
    error.style.padding = '40px';

    const heading = document.createElement('h3');
    heading.textContent = 'Failed to fetch media';
    const detail = document.createElement('p');
    detail.textContent = message;
    error.append(heading, detail);
    els.gallery.grid.replaceChildren(error);
}

// Media Gallery (Images & Videos)
els.gallery.typeImages.addEventListener('click', () => {
    if (state.galleryType === 'images') return;
    state.galleryType = 'images';
    els.gallery.typeImages.classList.add('active');
    els.gallery.typeVideos.classList.remove('active');
    fetchCloudinaryMedia();
});

els.gallery.typeVideos.addEventListener('click', () => {
    if (state.galleryType === 'videos') return;
    state.galleryType = 'videos';
    els.gallery.typeVideos.classList.add('active');
    els.gallery.typeImages.classList.remove('active');
    fetchCloudinaryMedia();
});

async function fetchCloudinaryMedia() {
    if (!state.user) return;
    els.gallery.grid.replaceChildren();
    els.gallery.loading.classList.remove('hidden');
    els.gallery.loadingText.textContent = `Fetching ${state.galleryType}...`;
    els.gallery.refresh.disabled = true;
    state.selectedImages.clear();
    updateSelectedCount();

    if (state.isLocalServer) {
        try {
            const res = await fetch('/api/wallpapers');
            const data = await res.json().catch(() => ({}));
            const list = Array.isArray(data.wallpapers) ? data.wallpapers : [];
            state.images = list.map((item) => ({
                public_id: item.id,
                secure_url: item.url,
                width: 1920,
                height: 1080,
                format: item.type === 'video' ? 'mp4' : 'jpg',
                resource_type: item.type === 'video' ? 'video' : 'image',
            }));
            renderGallery(state.images, state.galleryType);
        } catch (_) {
            renderGallery([], state.galleryType);
        } finally {
            els.gallery.loading.classList.add('hidden');
            els.gallery.refresh.disabled = false;
        }
        return;
    }

    try {
        const endpoint = state.galleryType === 'videos' ? '/videos' : '/images';
        const data = await adminApi(endpoint);
        if (!Array.isArray(data.resources)) {
            throw new Error(`The admin API returned an invalid ${state.galleryType} list.`);
        }
        state.images = data.resources.filter((item) => {
            if (!Number.isFinite(item.width) || !Number.isFinite(item.height) ||
                item.width <= 0 || item.height <= 0) {
                return false;
            }
            const ratio = item.width / item.height;
            return ratio >= 1.6 && ratio <= 1.9; // 16:9 aspect ratio tolerance
        });
        renderGallery(state.images, state.galleryType);
    } catch (error) {
        showToast(error.message || 'Failed to fetch media.', 'error');
        showGalleryError(error.message || 'Failed to fetch media.');
    } finally {
        els.gallery.loading.classList.add('hidden');
        els.gallery.refresh.disabled = false;
    }
}

function getPreviewUrl(mediaUrl, width) {
    const url = new URL(mediaUrl);
    if (url.protocol !== 'https:' || url.hostname !== 'res.cloudinary.com') {
        return mediaUrl;
    }
    if (url.pathname.includes('/image/upload/')) {
        url.pathname = url.pathname.replace(
            '/image/upload/',
            `/image/upload/w_${width},c_scale,q_auto/`,
        );
    } else if (url.pathname.includes('/video/upload/')) {
        url.pathname = url.pathname.replace(
            '/video/upload/',
            `/video/upload/w_${width},c_scale,so_0/`,
        ).replace(/\.[^.]+$/, '.jpg');
    }
    return url.toString();
}

function renderGallery(items, type) {
    if (items.length === 0) {
        const empty = document.createElement('p');
        empty.textContent = `No 16:9 landscape ${type} found in Cloudinary.`;
        els.gallery.grid.replaceChildren(empty);
        return;
    }

    const fragment = document.createDocumentFragment();
    items.forEach((media) => {
        const item = document.createElement('button');
        item.type = 'button';
        item.className = 'gallery-item';

        const badge = document.createElement('div');
        badge.className = 'selected-badge';
        badge.textContent = '✓';

        const imageContainer = document.createElement('div');
        imageContainer.className = 'img-container';
        const preview = document.createElement('img');
        preview.loading = 'lazy';
        preview.alt = media.public_id || 'Cloudinary media';
        preview.src = getPreviewUrl(media.secure_url, 600);
        imageContainer.appendChild(preview);

        const info = document.createElement('div');
        info.className = 'info';
        const resolution = document.createElement('div');
        resolution.className = 'resolution';
        resolution.textContent = `${media.width} × ${media.height}${type === 'videos' ? ' • VIDEO' : ''}`;
        const publicId = document.createElement('div');
        publicId.className = 'image-public-id';
        publicId.textContent = media.public_id || '';
        info.append(resolution, publicId);
        item.append(badge, imageContainer, info);

        const id = media.asset_id || media.public_id;
        item.addEventListener('click', () => {
            if (state.selectedImages.has(id)) {
                state.selectedImages.delete(id);
                item.classList.remove('selected');
            } else {
                state.selectedImages.add(id);
                item.classList.add('selected');
            }
            updateSelectedCount();
        });
        fragment.appendChild(item);
    });
    els.gallery.grid.replaceChildren(fragment);
}

function mediaToQueueItem(media) {
    const publicId = media.public_id || '';
    const fileName = publicId.split('/').pop().replace(/[_-]/g, ' ');
    const fallbackName = fileName.charAt(0).toUpperCase() + fileName.slice(1);
    const context = media.context || {};
    const customContext = context.custom || {};
    const tags = Array.isArray(media.tags) ? media.tags.join(', ') : '';
    const contextualTags = context.tags || customContext.tags || '';
    const normalizedContextualTags = Array.isArray(contextualTags)
        ? contextualTags.join(', ')
        : typeof contextualTags === 'string'
            ? contextualTags
            : '';
    const isVideo = media.resource_type === 'video' || state.galleryType === 'videos';

    return {
        id: media.asset_id || publicId.replace(/\//g, '_'),
        url: media.secure_url,
        thumbnailUrl: isVideo ? getPreviewUrl(media.secure_url, 600) : null,
        name: context.title || context.caption || context.name ||
            customContext.title || customContext.caption || fallbackName,
        category: context.category || customContext.category || (isVideo ? 'Live Video' : 'General'),
        type: isVideo ? 'video' : (context.type || customContext.type || 'static'),
        description: context.description || context.alt ||
            customContext.description || customContext.alt || '',
        tags: tags || normalizedContextualTags,
    };
}

els.gallery.refresh.addEventListener('click', fetchCloudinaryMedia);

els.gallery.process.addEventListener('click', () => {
    const newItems = state.images
        .filter((image) => state.selectedImages.has(image.asset_id || image.public_id))
        .map(mediaToQueueItem);
    state.queue.push(...newItems);
    renderQueue();
    updateNavQueueCount();
    switchSection('upload');
});

// ── Video Wallpaper Section Logic ──────────────────────────────────────────

function sanitizeId(text) {
    return text.toLowerCase().replace(/[^a-z0-9_-]/g, '_').replace(/^_+|_+$/g, '').substring(0, 80);
}

function generateIdFromTitle(title) {
    return generateStableWallpaperId();
}

function generateStableWallpaperId() {
    if (!globalThis.crypto || !globalThis.crypto.getRandomValues) {
        throw new Error('Secure wallpaper ID generation is unavailable in this browser.');
    }
    if (typeof globalThis.crypto.randomUUID === 'function') {
        return globalThis.crypto.randomUUID();
    }
    const bytes = new Uint8Array(16);
    globalThis.crypto.getRandomValues(bytes);
    return [...bytes].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

function classifyWallpaperResolution(width, height) {
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
        [4096, 2160, '4K'],
        [3840, 2160, '4K'],
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

// Mode toggle: Cloudinary Upload vs Direct URL
els.videos.modeCloudinary.addEventListener('click', () => {
    state.videoMode = 'cloudinary';
    els.videos.modeCloudinary.classList.add('active');
    els.videos.modeDirectUrl.classList.remove('active');
    els.videos.panelCloudinary.classList.remove('hidden');
    els.videos.panelDirect.classList.add('hidden');
    if (state.selectedVideoFile) {
        setVideoPreview(state.selectedVideoFile);
    }
});

els.videos.modeDirectUrl.addEventListener('click', () => {
    state.videoMode = 'direct';
    els.videos.modeDirectUrl.classList.add('active');
    els.videos.modeCloudinary.classList.remove('active');
    els.videos.panelDirect.classList.remove('hidden');
    els.videos.panelCloudinary.classList.add('hidden');
    const url = els.videos.directUrlInput.value.trim();
    if (url) {
        setVideoPreview(url);
    }
});

// File picker validation & preview
els.videos.fileInput.addEventListener('change', () => {
    const file = els.videos.fileInput.files && els.videos.fileInput.files[0];
    if (!file) {
        state.selectedVideoFile = null;
        els.videos.fileSizeBadge.className = 'file-size-badge';
        els.videos.fileSizeBadge.textContent = 'Max allowed file size: 100 MB';
        return;
    }

    const sizeMB = (file.size / (1024 * 1024)).toFixed(1);
    if (file.size > MAX_VIDEO_SIZE_BYTES) {
        els.videos.fileSizeBadge.className = 'file-size-badge invalid';
        els.videos.fileSizeBadge.textContent =
            `Selected file is ${sizeMB} MB. Exceeds max allowed size of 100 MB!`;
        showToast(`File size (${sizeMB} MB) exceeds maximum upload limit of 100 MB.`, 'error');
        state.selectedVideoFile = null;
        els.videos.previewWrapper.classList.add('hidden');
        return;
    }

    state.selectedVideoFile = file;
    state.uploadedVideoUrl = null;
    state.uploadedVideoWidth = 0;
    state.uploadedVideoHeight = 0;
    els.videos.fileSizeBadge.className = 'file-size-badge valid';
    els.videos.fileSizeBadge.textContent =
        `Selected: ${file.name} (${sizeMB} MB / Max 100 MB) ✓`;

    // Populate title & ID suggestions from filename if empty
    const rawName = file.name.replace(/\.[^/.]+$/, '').replace(/[_-]/g, ' ');
    const title = rawName.charAt(0).toUpperCase() + rawName.slice(1);
    if (!els.videos.titleInput.value) {
        els.videos.titleInput.value = title;
    }
    if (!els.videos.idInput.value) {
        els.videos.idInput.value = generateIdFromTitle(title);
    }
    if (!els.videos.categoryInput.value) {
        els.videos.categoryInput.value = 'Live Video';
    }

    setVideoPreview(file);
});

// Direct URL input listener
els.videos.directUrlInput.addEventListener('input', () => {
    const url = els.videos.directUrlInput.value.trim();
    if (!url) {
        els.videos.previewWrapper.classList.add('hidden');
        return;
    }

    try {
        new URL(url);
        setVideoPreview(url);

        const segments = url.split('/').pop().replace(/\.[^/.]+$/, '').replace(/[_-]/g, ' ');
        if (segments && !els.videos.titleInput.value) {
            const title = segments.charAt(0).toUpperCase() + segments.slice(1);
            els.videos.titleInput.value = title;
            if (!els.videos.idInput.value) {
                els.videos.idInput.value = generateIdFromTitle(title);
            }
        }
        if (!els.videos.categoryInput.value) {
            els.videos.categoryInput.value = 'Live Video';
        }
    } catch (_) {
        // Incomplete URL while typing, ignore
    }
});

function setVideoPreview(source) {
    const preview = els.videos.previewElement;
    if (source instanceof File) {
        preview.src = URL.createObjectURL(source);
    } else {
        preview.src = source;
    }

    els.videos.previewWrapper.classList.remove('hidden');
    preview.onloadedmetadata = () => {
        const dur = Number.isFinite(preview.duration) ? `${preview.duration.toFixed(1)}s` : '';
        const res = preview.videoWidth ? `${preview.videoWidth} × ${preview.videoHeight}` : '';
        els.videos.specsText.textContent = [res, dur, 'Looping Preview'].filter(Boolean).join(' • ');
    };
    preview.onerror = () => {
        els.videos.specsText.textContent = 'Unable to decode video format for in-browser playback.';
    };
}

async function getUploadSignature(folder) {
    if (state.isLocalServer || window.location.protocol.startsWith('http')) {
        try {
            const signRes = await fetch('/api/sign-upload', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ folder }),
            });
            const signData = await signRes.json().catch(() => ({}));
            if (signRes.ok && signData && (signData.cloudName || signData.signature || signData.uploadPreset)) {
                return signData;
            }
        } catch (_) {}
    }

    return adminApi('/sign-upload', {
        method: 'POST',
        body: JSON.stringify({ folder }),
    });
}

// Upload file to Cloudinary with live progress bar
async function uploadVideoToCloudinary(file) {
    els.videos.progressContainer.classList.remove('hidden');
    els.videos.progressBar.style.width = '0%';
    els.videos.uploadPercent.textContent = '0%';
    els.videos.uploadStatus.textContent = 'Requesting Cloudinary upload configuration...';

    // 1. Get secure signature or upload preset from backend
    const signData = await getUploadSignature('wallsync_videos');

    els.videos.uploadStatus.textContent = 'Uploading video file to Cloudinary...';

    // 2. Perform direct upload to Cloudinary with live progress
    return new Promise((resolve, reject) => {
        const xhr = new XMLHttpRequest();
        const uploadUrl = `https://api.cloudinary.com/v1_1/${encodeURIComponent(signData.cloudName)}/video/upload`;

        xhr.upload.onprogress = (event) => {
            if (event.lengthComputable) {
                const percent = Math.round((event.loaded / event.total) * 100);
                els.videos.progressBar.style.width = `${percent}%`;
                els.videos.uploadPercent.textContent = `${percent}%`;
                els.videos.uploadStatus.textContent = `Uploading video: ${(event.loaded / (1024 * 1024)).toFixed(1)}MB / ${(event.total / (1024 * 1024)).toFixed(1)}MB`;
            }
        };

        xhr.onload = () => {
            if (xhr.status >= 200 && xhr.status < 300) {
                try {
                    const res = JSON.parse(xhr.responseText);
                    els.videos.uploadStatus.textContent = 'Upload complete! Processing video...';
                    els.videos.progressBar.style.width = '100%';
                    els.videos.uploadPercent.textContent = '100%';
                    resolve(res);
                } catch (e) {
                    reject(new Error('Invalid response from Cloudinary.'));
                }
            } else {
                let errorDetails = xhr.responseText;
                try {
                    const parsed = JSON.parse(xhr.responseText);
                    if (parsed.error && parsed.error.message) {
                        errorDetails = parsed.error.message;
                    }
                } catch (_) {}
                reject(new Error(`Cloudinary upload failed (${xhr.status}): ${errorDetails}`));
            }
        };

        xhr.onerror = () => reject(new Error('Network error during video upload.'));

        const formData = new FormData();
        formData.append('file', file);
        if (signData.uploadPreset) {
            formData.append('upload_preset', signData.uploadPreset);
        } else if (signData.signature) {
            formData.append('signature', signData.signature);
            formData.append('timestamp', signData.timestamp);
            formData.append('api_key', signData.apiKey);
            if (signData.folder) formData.append('folder', signData.folder);
        }

        xhr.open('POST', uploadUrl);
        xhr.send(formData);
    });
}

async function prepareVideoItem() {
    const title = els.videos.titleInput.value.trim();
    if (!title) {
        showToast('Wallpaper Title / Name is required.', 'error');
        els.videos.titleInput.focus();
        return null;
    }

    const category = els.videos.categoryInput.value.trim() || 'Live Video';
    const id = sanitizeId(els.videos.idInput.value.trim() || generateIdFromTitle(title));

    let videoUrl = '';
    let autoThumb = null;

    if (state.videoMode === 'cloudinary') {
        if (!state.selectedVideoFile && !state.uploadedVideoUrl) {
            showToast('Please select a video file to upload (Max 100 MB).', 'error');
            return null;
        }

        if (!state.uploadedVideoUrl) {
            try {
                const uploadResult = await uploadVideoToCloudinary(state.selectedVideoFile);
                state.uploadedVideoUrl = uploadResult.secure_url;
                state.uploadedThumbUrl = uploadResult.secure_url.replace(/\.[^.]+$/, '.jpg');
                state.uploadedVideoWidth = Number(uploadResult.width) || 0;
                state.uploadedVideoHeight = Number(uploadResult.height) || 0;
            } catch (err) {
                showToast(err.message || 'Video upload failed.', 'error');
                els.videos.uploadStatus.textContent = 'Upload failed.';
                return null;
            }
        }
        videoUrl = state.uploadedVideoUrl;
        autoThumb = state.uploadedThumbUrl;
    } else {
        videoUrl = els.videos.directUrlInput.value.trim();
        if (!videoUrl) {
            showToast('Direct video stream URL is required.', 'error');
            els.videos.directUrlInput.focus();
            return null;
        }
        try {
            new URL(videoUrl);
        } catch (_) {
            showToast('Direct video URL is not a valid URL.', 'error');
            return null;
        }
        if (videoUrl.includes('res.cloudinary.com')) {
            autoThumb = videoUrl.replace(/\.[^.]+$/, '.jpg');
        }
    }

    const explicitThumb = els.videos.thumbnailInput.value.trim();
    const description = els.videos.descriptionInput.value.trim();
    const tags = els.videos.tagsInput.value.trim();
    const isPro = Boolean(els.videos.isProInput && els.videos.isProInput.checked);
    const width = state.uploadedVideoWidth || els.videos.previewElement.videoWidth || 0;
    const height = state.uploadedVideoHeight || els.videos.previewElement.videoHeight || 0;

    return {
        id,
        wallpaperId: id,
        name: title,
        category,
        type: 'video',
        url: videoUrl,
        thumbnailUrl: explicitThumb || autoThumb || null,
        description: description || null,
        tags: tags || null,
        isPro,
        width,
        height,
        resolutionLabel: classifyWallpaperResolution(width, height),
        resolutionSource: width > 0 ? 'video-stream' : 'unavailable',
        resolutionVerified: width > 0 && height > 0,
    };
}

// Add to Queue
els.videos.addToQueue.addEventListener('click', async () => {
    els.videos.addToQueue.disabled = true;
    try {
        const item = await prepareVideoItem();
        if (!item) return;

        state.queue.push(item);
        renderQueue();
        updateNavQueueCount();
        showToast(`Added "${item.name}" to upload queue.`);
        switchSection('upload');
    } finally {
        els.videos.addToQueue.disabled = false;
    }
});

// Publish directly
els.videos.saveDirect.addEventListener('click', async () => {
    els.videos.saveDirect.disabled = true;
    els.videos.saveDirect.textContent = 'Publishing...';
    try {
        const item = await prepareVideoItem();
        if (!item) return;

        const success = await uploadToFirebase([item]);
        if (success) {
            showToast(`Published live wallpaper "${item.name}"!`);
            // Reset fields
            els.videos.fileInput.value = '';
            els.videos.directUrlInput.value = '';
            els.videos.titleInput.value = '';
            els.videos.idInput.value = '';
            els.videos.tagsInput.value = '';
            els.videos.descriptionInput.value = '';
            if (els.videos.isProInput) els.videos.isProInput.checked = false;
            els.videos.thumbnailInput.value = '';
            els.videos.previewWrapper.classList.add('hidden');
            els.videos.progressContainer.classList.add('hidden');
            els.videos.fileSizeBadge.className = 'file-size-badge';
            els.videos.fileSizeBadge.textContent = 'Max allowed file size: 100 MB';
            state.selectedVideoFile = null;
            state.uploadedVideoUrl = null;
            state.uploadedThumbUrl = null;

            // Automatically refresh the active wallpapers database view
            fetchCatalogWallpapers(true);
        }
    } finally {
        els.videos.saveDirect.disabled = false;
        els.videos.saveDirect.textContent = 'Publish Live Wallpaper';
    }
});

// ── Static Image Wallpaper Section Logic ───────────────────────────────────

function generateStaticIdFromTitle(title) {
    return generateStableWallpaperId();
}

// Mode toggle: Cloudinary Upload vs Direct Image URL
els.static.modeCloudinary.addEventListener('click', () => {
    state.staticMode = 'cloudinary';
    els.static.modeCloudinary.classList.add('active');
    els.static.modeDirect.classList.remove('active');
    els.static.panelCloudinary.classList.remove('hidden');
    els.static.panelDirect.classList.add('hidden');
    if (state.selectedStaticFile) {
        setStaticImagePreview(state.selectedStaticFile);
    }
});

els.static.modeDirect.addEventListener('click', () => {
    state.staticMode = 'direct';
    els.static.modeDirect.classList.add('active');
    els.static.modeCloudinary.classList.remove('active');
    els.static.panelDirect.classList.remove('hidden');
    els.static.panelCloudinary.classList.add('hidden');
    const url = els.static.directUrlInput.value.trim();
    if (url) {
        setStaticImagePreview(url);
    }
});

// File picker validation & preview
els.static.fileInput.addEventListener('change', () => {
    const file = els.static.fileInput.files && els.static.fileInput.files[0];
    if (!file) return;

    if (!file.type.startsWith('image/')) {
        showToast('Please select a valid image file (PNG, JPG, WebP, AVIF).', 'error');
        state.selectedStaticFile = null;
        els.static.previewWrapper.classList.add('hidden');
        return;
    }

    if (file.size > MAX_IMAGE_SIZE_BYTES) {
        const sizeMB = (file.size / (1024 * 1024)).toFixed(1);
        els.static.fileSizeBadge.className = 'file-size-badge invalid';
        els.static.fileSizeBadge.textContent =
            `Selected file is ${sizeMB} MB. Exceeds max allowed size of 25 MB!`;
        showToast(`File size (${sizeMB} MB) exceeds maximum upload limit of 25 MB.`, 'error');
        state.selectedStaticFile = null;
        els.static.previewWrapper.classList.add('hidden');
        return;
    }

    const sizeMB = (file.size / (1024 * 1024)).toFixed(1);
    state.selectedStaticFile = file;
    state.uploadedStaticUrl = null;
    state.uploadedStaticWidth = 0;
    state.uploadedStaticHeight = 0;
    els.static.fileSizeBadge.className = 'file-size-badge valid';
    els.static.fileSizeBadge.textContent =
        `Selected: ${file.name} (${sizeMB} MB / Max 25 MB) ✓`;

    // Populate title & ID suggestions from filename if empty
    const rawName = file.name.replace(/\.[^/.]+$/, '').replace(/[_-]/g, ' ');
    const title = rawName.charAt(0).toUpperCase() + rawName.slice(1);
    if (!els.static.titleInput.value) {
        els.static.titleInput.value = title;
    }
    if (!els.static.idInput.value) {
        els.static.idInput.value = generateStaticIdFromTitle(title);
    }
    if (!els.static.categoryInput.value) {
        els.static.categoryInput.value = 'Nature';
    }

    setStaticImagePreview(file);
});

// Direct URL input listener
els.static.directUrlInput.addEventListener('input', () => {
    const url = els.static.directUrlInput.value.trim();
    if (!url) {
        els.static.previewWrapper.classList.add('hidden');
        return;
    }

    try {
        if (url.startsWith('http://') || url.startsWith('https://') || url.startsWith('/assets/')) {
            setStaticImagePreview(url);

            const segments = url.split('/').pop().replace(/\.[^/.]+$/, '').replace(/[_-]/g, ' ');
            if (segments && !els.static.titleInput.value) {
                const title = segments.charAt(0).toUpperCase() + segments.slice(1);
                els.static.titleInput.value = title;
                if (!els.static.idInput.value) {
                    els.static.idInput.value = generateStaticIdFromTitle(title);
                }
            }
            if (!els.static.categoryInput.value) {
                els.static.categoryInput.value = 'Landscape';
            }
        }
    } catch (_) {
        // Incomplete URL while typing
    }
});

function setStaticImagePreview(source) {
    const preview = els.static.previewElement;
    if (source instanceof File) {
        preview.src = URL.createObjectURL(source);
    } else {
        preview.src = source;
    }

    els.static.previewWrapper.classList.remove('hidden');
    preview.onload = () => {
        const res = preview.naturalWidth ? `${preview.naturalWidth} × ${preview.naturalHeight}` : '';
        const size = (source instanceof File) ? `${(source.size / (1024 * 1024)).toFixed(2)} MB` : 'Remote Image';
        els.static.specsText.textContent = [res, size, 'Static Wallpaper'].filter(Boolean).join(' • ');
    };
    preview.onerror = () => {
        els.static.specsText.textContent = 'Unable to preview image from the specified source.';
    };
}

// Upload image file to Cloudinary with live progress bar
async function uploadImageToCloudinary(file) {
    els.static.progressContainer.classList.remove('hidden');
    els.static.progressBar.style.width = '0%';
    els.static.uploadPercent.textContent = '0%';
    els.static.uploadStatus.textContent = 'Requesting Cloudinary upload configuration...';

    // 1. Get secure signature or upload preset from backend
    const signData = await getUploadSignature('wallsync_wallpapers');

    els.static.uploadStatus.textContent = 'Uploading image file to Cloudinary...';

    // 2. Perform direct upload to Cloudinary with live progress
    return new Promise((resolve, reject) => {
        const xhr = new XMLHttpRequest();
        const uploadUrl = `https://api.cloudinary.com/v1_1/${encodeURIComponent(signData.cloudName)}/image/upload`;

        xhr.upload.onprogress = (event) => {
            if (event.lengthComputable) {
                const percent = Math.round((event.loaded / event.total) * 100);
                els.static.progressBar.style.width = `${percent}%`;
                els.static.uploadPercent.textContent = `${percent}%`;
                els.static.uploadStatus.textContent = `Uploading image: ${(event.loaded / (1024 * 1024)).toFixed(1)}MB / ${(event.total / (1024 * 1024)).toFixed(1)}MB`;
            }
        };

        xhr.onload = () => {
            if (xhr.status >= 200 && xhr.status < 300) {
                try {
                    const res = JSON.parse(xhr.responseText);
                    els.static.uploadStatus.textContent = 'Upload complete! Image saved.';
                    els.static.progressBar.style.width = '100%';
                    els.static.uploadPercent.textContent = '100%';
                    resolve(res);
                } catch (e) {
                    reject(new Error('Invalid response from Cloudinary.'));
                }
            } else {
                let errorDetails = xhr.responseText;
                try {
                    const parsed = JSON.parse(xhr.responseText);
                    if (parsed.error && parsed.error.message) {
                        errorDetails = parsed.error.message;
                    }
                } catch (_) {}
                reject(new Error(`Cloudinary upload failed (${xhr.status}): ${errorDetails}`));
            }
        };

        xhr.onerror = () => reject(new Error('Network error during image upload.'));

        const formData = new FormData();
        formData.append('file', file);
        if (signData.uploadPreset) {
            formData.append('upload_preset', signData.uploadPreset);
        } else if (signData.signature) {
            formData.append('signature', signData.signature);
            formData.append('timestamp', signData.timestamp);
            formData.append('api_key', signData.apiKey);
            if (signData.folder) formData.append('folder', signData.folder);
        }

        xhr.open('POST', uploadUrl);
        xhr.send(formData);
    });
}

async function prepareStaticItem() {
    const title = els.static.titleInput.value.trim();
    if (!title) {
        showToast('Wallpaper Title / Name is required.', 'error');
        els.static.titleInput.focus();
        return null;
    }

    const category = els.static.categoryInput.value.trim() || 'Landscape';
    const id = sanitizeId(els.static.idInput.value.trim() || generateStaticIdFromTitle(title));

    let imageUrl = '';

    if (state.staticMode === 'cloudinary') {
        if (!state.selectedStaticFile && !state.uploadedStaticUrl) {
            showToast('Please select an image file to upload (Max 25 MB).', 'error');
            return null;
        }

        if (!state.uploadedStaticUrl) {
            try {
                const uploadResult = await uploadImageToCloudinary(state.selectedStaticFile);
                state.uploadedStaticUrl = uploadResult.secure_url;
                state.uploadedStaticWidth = Number(uploadResult.width) || 0;
                state.uploadedStaticHeight = Number(uploadResult.height) || 0;
            } catch (err) {
                showToast(err.message || 'Image upload failed.', 'error');
                els.static.uploadStatus.textContent = 'Upload failed.';
                return null;
            }
        }
        imageUrl = state.uploadedStaticUrl;
    } else {
        imageUrl = els.static.directUrlInput.value.trim();
        if (!imageUrl) {
            showToast('Direct image URL is required.', 'error');
            els.static.directUrlInput.focus();
            return null;
        }
        if (!imageUrl.startsWith('/assets/')) {
            try {
                new URL(imageUrl);
            } catch (_) {
                showToast('Direct image URL is not a valid URL or asset path.', 'error');
                return null;
            }
        }
    }

    const description = els.static.descriptionInput.value.trim();
    const tags = els.static.tagsInput.value.trim();
    const isPro = Boolean(els.static.isProInput && els.static.isProInput.checked);
    const width = state.uploadedStaticWidth || els.static.previewElement.naturalWidth || 0;
    const height = state.uploadedStaticHeight || els.static.previewElement.naturalHeight || 0;

    return {
        id,
        wallpaperId: id,
        name: title,
        category,
        type: 'static',
        url: imageUrl,
        thumbnailUrl: imageUrl,
        description: description || null,
        tags: tags || null,
        isPro,
        width,
        height,
        resolutionLabel: classifyWallpaperResolution(width, height),
        resolutionSource: width > 0 ? 'original-image' : 'unavailable',
        resolutionVerified: width > 0 && height > 0,
    };
}

// Add Static Wallpaper to Queue
els.static.addToQueue.addEventListener('click', async () => {
    els.static.addToQueue.disabled = true;
    try {
        const item = await prepareStaticItem();
        if (!item) return;

        state.queue.push(item);
        renderQueue();
        updateNavQueueCount();
        showToast(`Added "${item.name}" to upload queue.`);
        switchSection('upload');
    } finally {
        els.static.addToQueue.disabled = false;
    }
});

// Publish Static Wallpaper directly
els.static.saveDirect.addEventListener('click', async () => {
    els.static.saveDirect.disabled = true;
    els.static.saveDirect.textContent = 'Publishing...';
    try {
        const item = await prepareStaticItem();
        if (!item) return;

        const success = await uploadToFirebase([item]);
        if (success) {
            showToast(`Published static wallpaper "${item.name}"!`);
            // Reset fields
            els.static.fileInput.value = '';
            els.static.directUrlInput.value = '';
            els.static.titleInput.value = '';
            els.static.idInput.value = '';
            els.static.tagsInput.value = '';
            els.static.descriptionInput.value = '';
            if (els.static.isProInput) els.static.isProInput.checked = false;
            els.static.previewWrapper.classList.add('hidden');
            els.static.progressContainer.classList.add('hidden');
            els.static.fileSizeBadge.className = 'file-size-badge';
            els.static.fileSizeBadge.textContent = 'Max allowed file size: 25 MB';
            state.selectedStaticFile = null;
            state.uploadedStaticUrl = null;

            // Automatically refresh the active wallpapers database view
            fetchCatalogWallpapers(true);
        }
    } finally {
        els.static.saveDirect.disabled = false;
        els.static.saveDirect.textContent = 'Publish Static Wallpaper';
    }
});

// ── Upload Queue Logic ─────────────────────────────────────────────────────

function addQueueField(container, labelText, value, onChange, options = {}) {
    const group = document.createElement('div');
    group.className = `form-group${options.fullWidth ? ' full-width' : ''}`;
    group.style.marginBottom = '0';
    const label = document.createElement('label');
    label.textContent = labelText;

    let input;
    if (options.type === 'select') {
        input = document.createElement('select');
        for (const [optionValue, optionText] of [
            ['static', 'Static'],
            ['video', 'Live Video'],
            ['animated', 'Animated'],
        ]) {
            const option = document.createElement('option');
            option.value = optionValue;
            option.textContent = optionText;
            input.appendChild(option);
        }
    } else if (options.type === 'textarea') {
        input = document.createElement('textarea');
        input.rows = 2;
    } else {
        input = document.createElement('input');
        input.type = 'text';
        if (options.placeholder) input.placeholder = options.placeholder;
        if (options.listId) {
            input.setAttribute('list', options.listId);
        }
    }

    input.value = value ?? '';
    input.addEventListener('input', () => onChange(input.value));
    input.addEventListener('change', () => onChange(input.value));
    group.append(label, input);
    container.appendChild(group);
}

function renderQueue() {
    if (state.queue.length === 0) {
        const empty = document.createElement('p');
        empty.textContent = 'No items in queue.';
        els.queue.list.replaceChildren(empty);
        els.queue.uploadAll.disabled = true;
        updateNavQueueCount();
        return;
    }

    const fragment = document.createDocumentFragment();
    state.queue.forEach((item, index) => {
        const queueItem = document.createElement('div');
        queueItem.className = 'queue-item';

        const previewContainer = document.createElement('div');
        previewContainer.className = 'preview';

        const isVideo = item.type === 'video' || (item.url && item.url.endsWith('.mp4'));
        if (isVideo) {
            const preview = document.createElement('video');
            preview.muted = true;
            preview.loop = true;
            preview.playsInline = true;
            preview.autoplay = true;
            preview.src = item.url;
            previewContainer.appendChild(preview);
        } else {
            const preview = document.createElement('img');
            preview.alt = item.name || 'Wallpaper preview';
            preview.src = getPreviewUrl(item.url, 400);
            previewContainer.appendChild(preview);
        }

        const metadata = document.createElement('div');
        metadata.className = 'metadata';
        const update = (field) => (value) => {
            state.queue[index][field] = value;
        };
        addQueueField(metadata, 'Database ID Key', item.id, update('id'), {
            fullWidth: true,
            placeholder: 'e.g. cyberpunk_city',
        });
        addQueueField(metadata, 'Wallpaper Name', item.name, update('name'));
        addQueueField(metadata, 'Category', item.category, update('category'));
        addQueueField(metadata, 'Type', item.type, update('type'), {
            type: 'select',
        });
        addQueueField(metadata, 'Thumbnail URL (Optional)', item.thumbnailUrl, update('thumbnailUrl'), {
            placeholder: 'https://...',
        });
        addQueueField(metadata, 'Tags (comma separated)', item.tags, update('tags'), {
            fullWidth: true,
            placeholder: 'e.g. dark, city, neon, loop',
        });
        addQueueField(
            metadata,
            'Description',
            item.description,
            update('description'),
            { fullWidth: true, type: 'textarea' },
        );

        const actions = document.createElement('div');
        actions.className = 'queue-actions';
        const uploadButton = document.createElement('button');
        uploadButton.className = 'btn primary-btn';
        uploadButton.textContent = 'Upload';
        uploadButton.addEventListener('click', async () => {
            uploadButton.disabled = true;
            if (await uploadToFirebase([state.queue[index]])) {
                state.queue.splice(index, 1);
                renderQueue();
            } else {
                uploadButton.disabled = false;
            }
        });

        const removeButton = document.createElement('button');
        removeButton.className = 'btn secondary-btn';
        removeButton.textContent = 'Remove';
        removeButton.addEventListener('click', () => {
            state.queue.splice(index, 1);
            renderQueue();
            updateNavQueueCount();
        });
        actions.append(uploadButton, removeButton);
        queueItem.append(previewContainer, metadata, actions);
        fragment.appendChild(queueItem);
    });

    els.queue.list.replaceChildren(fragment);
    els.queue.uploadAll.disabled = false;
    updateNavQueueCount();
}

async function uploadToFirebase(items) {
    try {
        const payload = items.map((item) => ({
            id: item.id,
            wallpaperId: item.wallpaperId || item.id,
            name: item.name,
            category: item.category,
            type: item.type,
            url: item.url,
            thumbnailUrl: item.thumbnailUrl || null,
            description: item.description || null,
            tags: item.tags
                ? (Array.isArray(item.tags)
                    ? item.tags
                    : item.tags.split(',').map((tag) => tag.trim()).filter(Boolean))
                : null,
            width: item.width || 0,
            height: item.height || 0,
            resolutionLabel: item.resolutionLabel || 'Resolution unavailable',
            resolutionSource: item.resolutionSource || 'unavailable',
            resolutionVerified: item.resolutionVerified === true,
            isPro: item.isPro === true,
        }));

        if (state.isLocalServer) {
            const response = await fetch('/api/wallpapers', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ items: payload }),
            });
            const data = await response.json().catch(() => ({}));
            if (!response.ok) {
                throw new Error(data.error || `Save failed (${response.status}).`);
            }
            showToast(`Successfully published ${data.saved || payload.length} wallpaper(s) to Firebase Realtime Database!`);
            fetchCatalogWallpapers(true);
            return true;
        }

        try {
            const result = await adminApi('/wallpapers', {
                method: 'POST',
                body: JSON.stringify({ items: payload }),
            });
            showToast(`Successfully uploaded ${result.uploaded} wallpaper(s)!`);
            fetchCatalogWallpapers(true);
            return true;
        } catch (adminErr) {
            // Direct Firebase Realtime Database write
            for (const item of payload) {
                const fbRes = await fetch(`https://wallsync-e043c-default-rtdb.firebaseio.com/wallpapers/${encodeURIComponent(item.id)}.json`, {
                    method: 'PUT',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(item),
                });
                if (!fbRes.ok) {
                    throw new Error(`Firebase RTDB write failed: ${fbRes.statusText}`);
                }
            }
            showToast(`Successfully published ${payload.length} wallpaper(s) to Firebase Realtime Database!`);
            fetchCatalogWallpapers(true);
            return true;
        }
    } catch (error) {
        showToast(error.message || 'Upload failed.', 'error');
        return false;
    }
}

els.queue.uploadAll.addEventListener('click', async () => {
    if (state.queue.length === 0) return;
    els.queue.uploadAll.disabled = true;
    els.queue.uploadAll.textContent = 'Uploading...';
    if (await uploadToFirebase(state.queue)) {
        state.queue = [];
        renderQueue();
        updateNavQueueCount();
        switchSection('gallery');
    }
    els.queue.uploadAll.textContent = 'Upload All to Firebase';
    els.queue.uploadAll.disabled = state.queue.length === 0;
});

// ─────────────────────────────────────────────────────────────
// ACTIVE WALLPAPERS DATABASE CATALOG IMPLEMENTATION
// ─────────────────────────────────────────────────────────────

function normalizeMixkitUrl(url) {
    if (!url || typeof url !== 'string') return url;
    const match = url.match(/assets\.mixkit\.co\/videos\/preview\/(?:mixkit-)?.*?(\d+)-(?:large|medium|small)\.mp4/i);
    if (match && match[1]) {
        return `https://assets.mixkit.co/videos/${match[1]}/${match[1]}-720.mp4`;
    }
    return url;
}

function normalizeCatalogItem(id, item) {
    const rawType = (item.type || '').toLowerCase();
    const finalUrl = normalizeMixkitUrl(item.url || '');
    const isVideo = rawType === 'video' || rawType === 'animated' || (finalUrl && finalUrl.match(/\.(mp4|webm|ogg|mov)$/i));
    return {
        id: item.wallpaperId || item.id || id,
        wallpaperId: item.wallpaperId || item.id || id,
        name: item.name || id,
        category: item.category || (isVideo ? 'Live Video' : 'General'),
        type: rawType || (isVideo ? 'video' : 'static'),
        url: finalUrl,
        thumbnailUrl: item.thumbnailUrl || (finalUrl && finalUrl.includes('res.cloudinary.com') ? finalUrl.replace(/\.[^.]+$/, '.jpg') : null),
        description: item.description || null,
        tags: Array.isArray(item.tags) ? item.tags : (item.tags ? String(item.tags).split(',').map((t) => t.trim()).filter(Boolean) : null),
        width: Number(item.width) || 0,
        height: Number(item.height) || 0,
        resolutionLabel: item.resolutionLabel || 'Resolution unavailable',
        resolutionSource: item.resolutionSource || 'unavailable',
        resolutionVerified: item.resolutionVerified === true,
        source: item.source || 'firebase',
    };
}

async function fetchCatalogWallpapers(force = false) {
    els.catalog.loading.classList.remove('hidden');
    els.catalog.loadingText.textContent = 'Fetching database wallpapers...';
    els.catalog.refresh.disabled = true;

    try {
        let wallpapers = [];
        if (!state.isLocalServer && state.auth && state.auth.currentUser && !state.idsMigrated) {
            state.idsMigrated = true;
            try {
                const migration = await adminApi('/wallpapers/migrate', {
                    method: 'POST',
                    body: JSON.stringify({}),
                });
                if (migration && migration.migrated > 0) {
                    showToast(`Migrated stable IDs for ${migration.migrated} wallpaper record(s).`);
                }
            } catch (error) {
                console.warn('Wallpaper ID migration notice:', error.message);
            }
        }
        // 1. Try local server endpoint first
        try {
            const res = await fetch(`/api/database/wallpapers${force ? '?refresh=true' : ''}`);
            if (res.ok) {
                const data = await res.json();
                if (Array.isArray(data.wallpapers)) {
                    wallpapers = data.wallpapers;
                }
            }
        } catch (_) {}

        // 2. If server endpoint was empty or failed, fetch directly from Firebase RTDB (public read)
        if (wallpapers.length === 0) {
            try {
                const fbRes = await fetch('https://wallsync-e043c-default-rtdb.firebaseio.com/wallpapers.json');
                if (fbRes.ok) {
                    const fbData = await fbRes.json();
                    if (fbData && typeof fbData === 'object') {
                        if (Array.isArray(fbData)) {
                            fbData.forEach((val, idx) => {
                                if (val && val.url) wallpapers.push(normalizeCatalogItem(String(idx), val));
                            });
                        } else {
                            Object.entries(fbData).forEach(([key, val]) => {
                                if (val && val.url) wallpapers.push(normalizeCatalogItem(key, val));
                            });
                        }
                    }
                }
            } catch (_) {}
        }

        state.catalog = wallpapers;
        els.nav.catalogCount.textContent = String(wallpapers.length);
        updateCatalogCategories(wallpapers);
        renderCatalog();
    } catch (err) {
        showToast('Error loading wallpapers: ' + err.message, 'error');
    } finally {
        els.catalog.loading.classList.add('hidden');
        els.catalog.refresh.disabled = false;
    }
}

function updateCatalogCategories(wallpapers) {
    const categories = new Set();
    wallpapers.forEach((w) => {
        if (w.category) categories.add(w.category);
    });

    const select = els.catalog.categorySelect;
    select.replaceChildren();

    const allOption = document.createElement('option');
    allOption.value = 'all';
    allOption.textContent = `All Categories (${wallpapers.length})`;
    select.appendChild(allOption);

    Array.from(categories).sort().forEach((cat) => {
        const count = wallpapers.filter((w) => w.category === cat).length;
        const opt = document.createElement('option');
        opt.value = cat;
        opt.textContent = `${cat} (${count})`;
        if (state.catalogFilterCategory === cat) {
            opt.selected = true;
        }
        select.appendChild(opt);
    });
}

function updateCatalogMetrics() {
    const list = Array.isArray(state.catalog) ? state.catalog : [];
    if (els.overview.totalWallpapers) els.overview.totalWallpapers.textContent = String(list.length);
    if (els.nav.catalogCount) els.nav.catalogCount.textContent = String(list.length);

    let imagesCount = 0;
    let videosCount = 0;
    list.forEach((w) => {
        const isVideo = w.type === 'video' || w.type === 'animated' || (w.url && w.url.match(/\.(mp4|webm|ogg|mov)$/i));
        if (isVideo) videosCount++;
        else imagesCount++;
    });

    if (els.overview.totalImages) els.overview.totalImages.textContent = String(imagesCount);
    if (els.overview.totalVideos) els.overview.totalVideos.textContent = String(videosCount);
}

function renderCatalog() {
    updateCatalogMetrics();
    const grid = els.catalog.grid;
    grid.replaceChildren();

    const query = state.catalogSearchQuery.toLowerCase().trim();
    const catFilter = state.catalogFilterCategory;
    const typeFilter = state.catalogFilterType;

    const filtered = state.catalog.filter((item) => {
        // Filter by category
        if (catFilter !== 'all' && item.category !== catFilter) {
            return false;
        }

        // Filter by type
        if (typeFilter === 'images' && item.type !== 'static') {
            return false;
        }
        if (typeFilter === 'videos' && item.type !== 'video' && item.type !== 'animated') {
            return false;
        }

        // Filter by search query
        if (query) {
            const nameMatch = (item.name || '').toLowerCase().includes(query);
            const catMatch = (item.category || '').toLowerCase().includes(query);
            const idMatch = (item.id || '').toLowerCase().includes(query);
            const descMatch = (item.description || '').toLowerCase().includes(query);
            const tagMatch = Array.isArray(item.tags) && item.tags.some((t) => t.toLowerCase().includes(query));
            if (!nameMatch && !catMatch && !idMatch && !descMatch && !tagMatch) {
                return false;
            }
        }

        return true;
    });

    els.catalog.summaryText.textContent = `Showing ${filtered.length} of ${state.catalog.length} wallpapers`;

    if (filtered.length === 0) {
        const emptyDiv = document.createElement('div');
        emptyDiv.style.gridColumn = '1 / -1';
        emptyDiv.style.textAlign = 'center';
        emptyDiv.style.padding = '60px 20px';
        emptyDiv.style.color = 'var(--text-secondary)';

        const emptyIcon = document.createElement('div');
        emptyIcon.textContent = '🖼️';
        emptyIcon.style.fontSize = '48px';
        emptyIcon.style.marginBottom = '12px';

        const emptyText = document.createElement('h3');
        emptyText.textContent = state.catalog.length === 0
            ? 'No wallpapers found in database.'
            : 'No wallpapers matched your search/filters.';

        emptyDiv.append(emptyIcon, emptyText);
        grid.appendChild(emptyDiv);
        return;
    }

    const fragment = document.createDocumentFragment();

    filtered.forEach((item) => {
        const card = document.createElement('div');
        card.className = 'catalog-card';

        // Thumb wrapper
        const thumbWrapper = document.createElement('div');
        thumbWrapper.className = 'catalog-thumb-wrapper';

        const isVideo = item.type === 'video' || item.type === 'animated' || (item.url && item.url.match(/\.(mp4|webm|ogg|mov)$/i));

        if (isVideo) {
            const videoEl = document.createElement('video');
            videoEl.className = 'catalog-video-player';
            videoEl.muted = true;
            videoEl.loop = true;
            videoEl.playsInline = true;
            videoEl.preload = 'metadata';
            if (item.thumbnailUrl) {
                videoEl.poster = item.thumbnailUrl;
            }
            videoEl.src = item.url;
            videoEl.onerror = () => {
                videoEl.style.display = 'none';
                const fallbackThumb = document.createElement('div');
                fallbackThumb.className = 'catalog-thumb-fallback';
                fallbackThumb.style.cssText = 'height:100%;display:flex;align-items:center;justify-content:center;color:#64748b;font-size:12px;background:#0f172a;';
                fallbackThumb.textContent = '🎬 Preview unavailable';
                thumbWrapper.appendChild(fallbackThumb);
            };

            // Subtle video play on card hover
            card.addEventListener('mouseenter', () => {
                videoEl.play().catch(() => {});
            });
            card.addEventListener('mouseleave', () => {
                videoEl.pause();
                videoEl.currentTime = 0;
            });

            thumbWrapper.appendChild(videoEl);
        } else {
            const img = document.createElement('img');
            img.className = 'catalog-thumb';
            img.loading = 'lazy';
            img.src = item.thumbnailUrl || item.url;
            img.alt = item.name;
            img.onerror = () => {
                img.onerror = null;
                img.src = 'data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" width="300" height="200" viewBox="0 0 300 200"><rect fill="%231e293b" width="300" height="200"/><text fill="%2364748b" font-family="sans-serif" font-size="13" font-weight="bold" x="50%" y="50%" text-anchor="middle">Image Unavailable</text></svg>';
            };
            thumbWrapper.appendChild(img);
        }

        // Type badge
        const typeBadge = document.createElement('span');
        const badgeType = isVideo ? (item.type === 'animated' ? 'animated' : 'video') : 'static';
        typeBadge.className = `catalog-badge-type ${badgeType}`;
        typeBadge.textContent = badgeType === 'video' ? '🎬 Live Video' : (badgeType === 'animated' ? '✨ Animated' : '🖼️ Static');
        thumbWrapper.appendChild(typeBadge);

        // PRO badge
        if (item.isPro || item.pro) {
            const proBadge = document.createElement('span');
            proBadge.className = 'catalog-badge-pro';
            proBadge.textContent = '👑 PRO';
            thumbWrapper.appendChild(proBadge);
        }

        // Category badge
        const catBadge = document.createElement('span');
        catBadge.className = 'catalog-badge-category';
        catBadge.textContent = item.category || 'General';
        thumbWrapper.appendChild(catBadge);

        // Card body
        const body = document.createElement('div');
        body.className = 'catalog-card-body';

        const title = document.createElement('h4');
        title.className = 'catalog-card-title';
        title.textContent = item.name;
        title.title = item.name;
        body.appendChild(title);

        if (item.description) {
            const desc = document.createElement('p');
            desc.className = 'catalog-card-desc';
            desc.textContent = item.description;
            body.appendChild(desc);
        }

        if (Array.isArray(item.tags) && item.tags.length > 0) {
            const tagsContainer = document.createElement('div');
            tagsContainer.className = 'catalog-card-tags';
            item.tags.slice(0, 4).forEach((tag) => {
                const pill = document.createElement('span');
                pill.className = 'tag-pill';
                pill.textContent = `#${tag}`;
                tagsContainer.appendChild(pill);
            });
            body.appendChild(tagsContainer);
        }

        const idBadge = document.createElement('span');
        idBadge.className = 'catalog-card-id';
        idBadge.textContent = `ID: ${item.id}`;
        body.appendChild(idBadge);

        // Actions
        const actions = document.createElement('div');
        actions.className = 'catalog-card-actions';

        const previewBtn = document.createElement('button');
        previewBtn.type = 'button';
        previewBtn.className = 'btn primary-btn';
        previewBtn.textContent = 'Preview';
        previewBtn.addEventListener('click', () => openPreviewModal(item));

        const editBtn = document.createElement('button');
        editBtn.type = 'button';
        editBtn.className = 'btn secondary-btn btn-edit';
        editBtn.textContent = 'Edit';
        editBtn.title = 'Edit wallpaper details & update RTDB';
        editBtn.addEventListener('click', () => openEditModal(item));

        const linkBtn = document.createElement('button');
        linkBtn.type = 'button';
        linkBtn.className = 'btn secondary-btn';
        linkBtn.textContent = 'Link ↗';
        linkBtn.title = 'Open direct asset URL in new tab';
        linkBtn.addEventListener('click', () => window.open(item.url, '_blank'));

        const deleteBtn = document.createElement('button');
        deleteBtn.type = 'button';
        deleteBtn.className = 'btn btn-danger';
        deleteBtn.textContent = 'Delete';
        deleteBtn.title = 'Remove wallpaper from catalog';
        deleteBtn.addEventListener('click', async () => {
            const confirmed = window.confirm(`Remove wallpaper "${item.name}" from database?`);
            if (!confirmed) return;

            deleteBtn.disabled = true;
            deleteBtn.textContent = 'Deleting...';
            try {
                const res = await fetch('/api/database/delete', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ id: item.id }),
                });
                if (res.ok) {
                    showToast(`Removed "${item.name}" from database.`);
                    state.catalog = state.catalog.filter((w) => w.id !== item.id);
                    els.nav.catalogCount.textContent = String(state.catalog.length);
                    renderCatalog();
                } else {
                    showToast('Failed to delete wallpaper.', 'error');
                    deleteBtn.disabled = false;
                    deleteBtn.textContent = 'Delete';
                }
            } catch (err) {
                showToast(err.message || 'Delete failed.', 'error');
                deleteBtn.disabled = false;
                deleteBtn.textContent = 'Delete';
            }
        });

        actions.append(previewBtn, editBtn, linkBtn, deleteBtn);
        body.appendChild(actions);

        card.append(thumbWrapper, body);
        fragment.appendChild(card);
    });

    grid.appendChild(fragment);
}

// ─────────────────────────────────────────────────────────────
// PREVIEW MODAL
// ─────────────────────────────────────────────────────────────

function openPreviewModal(item) {
    els.catalog.modalTitle.textContent = item.name;
    els.catalog.modalMedia.replaceChildren();

    const isVideo = item.type === 'video' || item.type === 'animated' || (item.url && item.url.match(/\.(mp4|webm|ogg|mov)$/i));

    if (isVideo) {
        const video = document.createElement('video');
        video.controls = true;
        video.autoplay = true;
        video.loop = true;
        video.src = item.url;
        els.catalog.modalMedia.appendChild(video);
    } else {
        const img = document.createElement('img');
        img.src = item.url;
        img.alt = item.name;
        els.catalog.modalMedia.appendChild(img);
    }

    // Details rows
    const details = els.catalog.modalDetails;
    details.replaceChildren();

    function addDetail(label, value, isLink = false) {
        if (!value) return;
        const row = document.createElement('div');
        row.className = 'modal-detail-row';

        const lbl = document.createElement('span');
        lbl.className = 'modal-detail-label';
        lbl.textContent = label;

        const val = document.createElement('span');
        val.className = 'modal-detail-value';
        if (isLink) {
            const a = document.createElement('a');
            a.href = value;
            a.target = '_blank';
            a.rel = 'noopener noreferrer';
            a.textContent = value;
            val.appendChild(a);
        } else {
            val.textContent = value;
        }

        row.append(lbl, val);
        details.appendChild(row);
    }

    addDetail('Database Key', item.id);
    addDetail('Category', item.category);
    addDetail('Type', item.type);
    if (item.description) addDetail('Description', item.description);
    if (Array.isArray(item.tags) && item.tags.length > 0) {
        addDetail('Tags', item.tags.join(', '));
    }
    addDetail('Remote URL', item.url, true);
    if (item.thumbnailUrl) addDetail('Thumbnail URL', item.thumbnailUrl, true);

    const modalEditBtn = document.createElement('button');
    modalEditBtn.type = 'button';
    modalEditBtn.className = 'btn secondary-btn btn-edit';
    modalEditBtn.textContent = '✎ Edit Wallpaper';
    modalEditBtn.style.marginTop = '12px';
    modalEditBtn.addEventListener('click', () => {
        closePreviewModal();
        openEditModal(item);
    });
    details.appendChild(modalEditBtn);

    els.catalog.modal.classList.remove('hidden');
}

function closePreviewModal() {
    const video = els.catalog.modalMedia.querySelector('video');
    if (video) {
        video.pause();
        video.src = '';
    }
    els.catalog.modal.classList.add('hidden');
    els.catalog.modalMedia.replaceChildren();
}

els.catalog.modalClose.addEventListener('click', closePreviewModal);
els.catalog.modal.addEventListener('click', (e) => {
    if (e.target === els.catalog.modal) {
        closePreviewModal();
    }
});

// ─────────────────────────────────────────────────────────────
// EDIT WALLPAPER MODAL
// ─────────────────────────────────────────────────────────────

function updateEditPreview(thumbUrl, fallbackUrl) {
    const url = thumbUrl || fallbackUrl;
    if (url) {
        els.catalog.editPreviewImage.src = url;
        els.catalog.editPreviewImage.classList.remove('hidden');
        els.catalog.editPreviewPlaceholder.classList.add('hidden');
    } else {
        els.catalog.editPreviewImage.src = '';
        els.catalog.editPreviewImage.classList.add('hidden');
        els.catalog.editPreviewPlaceholder.classList.remove('hidden');
    }
}

function openEditModal(item) {
    if (!item) return;

    els.catalog.editWallpaperId.value = item.id;
    els.catalog.editIdDisplay.textContent = `ID: ${item.id}`;
    els.catalog.editTitleInput.value = item.name || '';
    els.catalog.editCategoryInput.value = item.category || 'General';
    els.catalog.editTypeSelect.value = (item.type === 'video' || item.type === 'animated') ? 'video' : 'static';
    els.catalog.editUrlInput.value = item.url || '';
    els.catalog.editThumbnailInput.value = item.thumbnailUrl || '';
    els.catalog.editTagsInput.value = Array.isArray(item.tags) ? item.tags.join(', ') : (item.tags || '');
    els.catalog.editDescriptionInput.value = item.description || '';
    if (els.catalog.editIsProInput) {
        els.catalog.editIsProInput.checked = Boolean(item.isPro || item.pro);
    }

    updateEditPreview(item.thumbnailUrl, item.url);

    els.catalog.btnSaveEdit.disabled = false;
    els.catalog.btnSaveEdit.textContent = 'Save Changes to RTDB';

    els.catalog.editModal.classList.remove('hidden');
}

function closeEditModal() {
    els.catalog.editModal.classList.add('hidden');
    els.catalog.editPreviewImage.src = '';
    els.catalog.editPreviewImage.classList.add('hidden');
    els.catalog.editPreviewPlaceholder.classList.remove('hidden');
}

els.catalog.btnCloseEditModal.addEventListener('click', closeEditModal);
els.catalog.btnCancelEdit.addEventListener('click', closeEditModal);
els.catalog.editModal.addEventListener('click', (e) => {
    if (e.target === els.catalog.editModal) {
        closeEditModal();
    }
});

// Dynamic preview when changing URL or thumbnail
els.catalog.editThumbnailInput.addEventListener('input', () => {
    const thumb = els.catalog.editThumbnailInput.value.trim();
    const fallback = els.catalog.editUrlInput.value.trim();
    updateEditPreview(thumb, fallback);
});

els.catalog.editUrlInput.addEventListener('input', () => {
    const thumb = els.catalog.editThumbnailInput.value.trim();
    const fallback = els.catalog.editUrlInput.value.trim();
    if (!thumb) {
        updateEditPreview('', fallback);
    }
});

// Form submission to update wallpaper in RTDB
els.catalog.formEditWallpaper.addEventListener('submit', async (e) => {
    e.preventDefault();

    const id = els.catalog.editWallpaperId.value.trim();
    const name = els.catalog.editTitleInput.value.trim();
    const category = els.catalog.editCategoryInput.value.trim() || 'General';
    const type = els.catalog.editTypeSelect.value;
    const url = els.catalog.editUrlInput.value.trim();
    const thumbnailUrl = els.catalog.editThumbnailInput.value.trim() || null;
    const description = els.catalog.editDescriptionInput.value.trim() || null;
    const rawTags = els.catalog.editTagsInput.value.trim();
    const tags = rawTags ? rawTags.split(',').map((t) => t.trim()).filter(Boolean) : null;
    const isPro = Boolean(els.catalog.editIsProInput && els.catalog.editIsProInput.checked);

    if (!id || !name || !url) {
        showToast('Wallpaper Title and URL are required.', 'error');
        return;
    }

    els.catalog.btnSaveEdit.disabled = true;
    els.catalog.btnSaveEdit.textContent = 'Saving to RTDB...';

    const payload = {
        id,
        name,
        category,
        type,
        url,
        thumbnailUrl,
        description,
        tags,
        isPro,
    };

    try {
        let saved = false;

        if (state.isLocalServer) {
            const res = await fetch('/api/database/update', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload),
            });
            const data = await res.json().catch(() => ({}));
            if (!res.ok) {
                throw new Error(data.error || `Update failed (${res.status}).`);
            }
            saved = true;
        }

        // Direct RTDB write if not in local server mode or as direct sync
        if (!saved) {
            const rtdbUrl = `https://wallsync-e043c-default-rtdb.firebaseio.com/wallpapers/${encodeURIComponent(id)}.json`;
            const fbRes = await fetch(rtdbUrl, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload),
            });
            if (!fbRes.ok) {
                throw new Error(`Firebase RTDB update failed: ${fbRes.statusText}`);
            }
        }

        showToast(`Successfully updated "${name}" in Realtime Database!`);

        // Update local state catalog
        const idx = state.catalog.findIndex((w) => w.id === id);
        if (idx >= 0) {
            state.catalog[idx] = {
                ...state.catalog[idx],
                ...payload,
            };
        } else {
            state.catalog.unshift(payload);
        }

        renderCatalog();
        closeEditModal();
    } catch (err) {
        showToast(err.message || 'Failed to update wallpaper.', 'error');
    } finally {
        els.catalog.btnSaveEdit.disabled = false;
        els.catalog.btnSaveEdit.textContent = 'Save Changes to RTDB';
    }
});

// Catalog Toolbar Listeners
els.catalog.typeAll.addEventListener('click', () => {
    state.catalogFilterType = 'all';
    els.catalog.typeAll.classList.add('active');
    els.catalog.typeImages.classList.remove('active');
    els.catalog.typeVideos.classList.remove('active');
    renderCatalog();
});

els.catalog.typeImages.addEventListener('click', () => {
    state.catalogFilterType = 'images';
    els.catalog.typeImages.classList.add('active');
    els.catalog.typeAll.classList.remove('active');
    els.catalog.typeVideos.classList.remove('active');
    renderCatalog();
});

els.catalog.typeVideos.addEventListener('click', () => {
    state.catalogFilterType = 'videos';
    els.catalog.typeVideos.classList.add('active');
    els.catalog.typeAll.classList.remove('active');
    els.catalog.typeImages.classList.remove('active');
    renderCatalog();
});

els.catalog.searchInput.addEventListener('input', (e) => {
    state.catalogSearchQuery = e.target.value;
    renderCatalog();
});

els.catalog.categorySelect.addEventListener('change', (e) => {
    state.catalogFilterCategory = e.target.value;
    renderCatalog();
});

els.catalog.refresh.addEventListener('click', () => {
    fetchCatalogWallpapers(true);
});

// ─────────────────────────────────────────────────────────────
// REALTIME SSE EVENT LISTENERS & BOOTSTRAP
// ─────────────────────────────────────────────────────────────

function updateConnectedClientsTable(clients) {
    const list = Array.isArray(clients) ? clients : [];
    if (!els.overview.clientsList) return;

    if (list.length === 0) {
        els.overview.clientsList.replaceChildren();
        if (els.overview.clientsEmpty) els.overview.clientsEmpty.classList.remove('hidden');
        return;
    }

    if (els.overview.clientsEmpty) els.overview.clientsEmpty.classList.add('hidden');
    const fragment = document.createDocumentFragment();

    list.forEach((client) => {
        const row = document.createElement('tr');

        // Client / Hostname & Device ID
        const hostTd = document.createElement('td');
        const hostSpan = document.createElement('span');
        hostSpan.className = 'client-id-code';
        hostSpan.textContent = client.hostname || client.deviceId || client.clientId || 'Client Device';
        hostTd.appendChild(hostSpan);

        if (client.deviceId) {
            const devSub = document.createElement('div');
            devSub.style.fontSize = '10px';
            devSub.style.color = 'var(--text-tertiary, #888)';
            devSub.style.fontFamily = 'monospace';
            devSub.style.marginTop = '2px';
            devSub.textContent = client.deviceId;
            hostTd.appendChild(devSub);
        }

        // Platform
        const platTd = document.createElement('td');
        platTd.textContent = (client.platform || 'windows').toUpperCase();

        // App Version
        const verTd = document.createElement('td');
        verTd.textContent = client.appVersion || '1.0.1';

        // Active Wallpaper
        const wpTd = document.createElement('td');
        wpTd.textContent = client.activeWallpaper || 'None';

        // Last Ping
        const pingTd = document.createElement('td');
        const diffSec = client.lastSeen ? Math.max(0, Math.round((Date.now() - client.lastSeen) / 1000)) : 0;
        pingTd.textContent = `${diffSec}s ago`;

        // Status
        const statusTd = document.createElement('td');
        const statusBadge = document.createElement('span');
        statusBadge.className = 'client-status-badge';
        statusBadge.textContent = '● Live';
        statusTd.appendChild(statusBadge);

        row.append(hostTd, platTd, verTd, wpTd, pingTd, statusTd);
        fragment.appendChild(row);
    });

    els.overview.clientsList.replaceChildren(fragment);
}

function updateLiveMetrics(data) {
    if (!data) return;
    const live = typeof data.liveDevices === 'number' ? data.liveDevices : (typeof data.liveUsers === 'number' ? data.liveUsers : 0);
    const total = typeof data.totalDevices === 'number' ? data.totalDevices : (typeof data.totalUsers === 'number' ? data.totalUsers : 0);

    if (els.liveSync.liveCount) els.liveSync.liveCount.textContent = String(live);
    if (els.liveSync.totalCount) els.liveSync.totalCount.textContent = String(total);
    if (els.liveSync.cardLiveCount) els.liveSync.cardLiveCount.textContent = String(live);
    if (els.liveSync.cardTotalCount) els.liveSync.cardTotalCount.textContent = String(total);
    if (els.liveSync.dot) {
        els.liveSync.dot.className = live > 0 ? 'dot pulse-dot connected' : 'dot pulse-dot disconnected';
    }

    if (els.overview.liveUsers) els.overview.liveUsers.textContent = String(live);
    if (els.overview.totalDevices) els.overview.totalDevices.textContent = String(total);

    if (Array.isArray(data.activeClients)) {
        updateConnectedClientsTable(data.activeClients);
    }
}

// Handler for clearing all registered devices
const btnClearDevices = document.getElementById('btn-clear-registered-devices');
if (btnClearDevices) {
    btnClearDevices.addEventListener('click', async () => {
        if (!confirm('Are you sure you want to clear all registered devices? Total registered devices count will be reset to 0.')) {
            return;
        }
        btnClearDevices.disabled = true;
        try {
            const res = await fetch('/api/devices/clear', { method: 'POST' });
            const data = await res.json();
            if (data.success) {
                updateLiveMetrics({
                    totalDevices: 0,
                    liveDevices: 0,
                    totalUsers: 0,
                    liveUsers: 0,
                    activeClients: [],
                });
                showToast('All registered devices cleared successfully. Count reset to 0.', 'success');
            } else {
                showToast('Failed to clear devices: ' + (data.error || 'Server error'), 'error');
            }
        } catch (err) {
            showToast('Error clearing registered devices: ' + err.message, 'error');
        } finally {
            btnClearDevices.disabled = false;
        }
    });
}

async function updateServerStatusMetric() {
    try {
        const res = await fetch('/api/status');
        if (res.ok) {
            const data = await res.json();
            if (els.overview.serverStatus) {
                els.overview.serverStatus.textContent = data.status === 'online' ? 'Online' : 'Offline';
            }
            if (els.overview.serverUptime && typeof data.uptime === 'number') {
                const mins = Math.floor(data.uptime / 60);
                const hrs = Math.floor(mins / 60);
                const remMins = mins % 60;
                const uptimeText = hrs > 0 ? `${hrs}h ${remMins}m` : `${mins}m`;
                els.overview.serverUptime.textContent = `Uptime: ${uptimeText} (Port ${data.port || 3000})`;
            }
        }
    } catch (_) {}
}

function initLiveSync() {
    let eventSource = null;

    function connectSSE() {
        try {
            eventSource = new EventSource('/api/events');

            eventSource.addEventListener('stats', (event) => {
                try {
                    const data = JSON.parse(event.data);
                    updateLiveMetrics(data);
                    els.liveSync.serverDot.className = 'dot connected';
                    els.liveSync.serverText.textContent = 'Backend Node Server: Connected (Live)';
                } catch (_) {}
            });

            eventSource.addEventListener('wallpapers_updated', () => {
                fetchCatalogWallpapers(false);
            });

            eventSource.addEventListener('push_notification', (event) => {
                try {
                    const notif = JSON.parse(event.data);
                    showToast(`📢 Broadcast sent: ${notif.title}`);
                } catch (_) {}
                fetchNotificationsHistory();
            });

            eventSource.onopen = () => {
                els.liveSync.serverDot.className = 'dot connected';
                els.liveSync.serverText.textContent = 'Backend Node Server: Online';
            };

            eventSource.onerror = () => {
                els.liveSync.serverDot.className = 'dot disconnected';
                els.liveSync.serverText.textContent = 'Backend Node Server: Reconnecting...';
                if (eventSource) {
                    eventSource.close();
                    eventSource = null;
                }
                setTimeout(connectSSE, 4000);
            };
        } catch (_) {
            pollStats();
        }
    }

    async function pollStats() {
        try {
            const res = await fetch('/api/users/stats');
            if (res.ok) {
                const data = await res.json();
                updateLiveMetrics(data);
                els.liveSync.serverDot.className = 'dot connected';
                els.liveSync.serverText.textContent = 'Backend Node Server: Online';
            } else {
                els.liveSync.serverDot.className = 'dot disconnected';
                els.liveSync.serverText.textContent = 'Backend Node Server: Disconnected';
            }
        } catch (_) {
            els.liveSync.serverDot.className = 'dot disconnected';
            els.liveSync.serverText.textContent = 'Backend Node Server: Disconnected';
        }
        updateServerStatusMetric();
    }

    connectSSE();
    setInterval(pollStats, 8000);
}

async function loadCloudinaryConfig() {
    if (!els.cloudinary || !els.cloudinary.cloudName) return;
    try {
        const res = await fetch('/api/cloudinary-config');
        if (res.ok) {
            const data = await res.json();
            if (data.cloudName && els.cloudinary.cloudName) {
                els.cloudinary.cloudName.value = data.cloudName;
            }
            if (data.uploadPreset && els.cloudinary.uploadPreset) {
                els.cloudinary.uploadPreset.value = data.uploadPreset;
            }
        }
    } catch (_) {}
}

if (els.cloudinary && els.cloudinary.form) {
    els.cloudinary.form.addEventListener('submit', async (e) => {
        e.preventDefault();
        const cloudName = els.cloudinary.cloudName.value.trim();
        const uploadPreset = els.cloudinary.uploadPreset.value.trim();
        if (!cloudName) {
            showToast('Cloudinary Cloud Name is required.', 'error');
            return;
        }
        els.cloudinary.saveBtn.disabled = true;
        els.cloudinary.saveBtn.textContent = 'Saving...';
        try {
            const res = await fetch('/api/cloudinary-config', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ cloudName, uploadPreset }),
            });
            const data = await res.json().catch(() => ({}));
            if (!res.ok) throw new Error(data.error || 'Failed to save settings.');
            els.cloudinary.status.className = 'status-message success';
            els.cloudinary.status.textContent = 'Cloudinary settings saved! Direct file picker uploads are enabled.';
            els.cloudinary.status.style.display = 'block';
            showToast('Cloudinary settings saved successfully!');
        } catch (err) {
            els.cloudinary.status.className = 'status-message error';
            els.cloudinary.status.textContent = err.message || 'Failed to save settings.';
            els.cloudinary.status.style.display = 'block';
            showToast(err.message, 'error');
        } finally {
            els.cloudinary.saveBtn.disabled = false;
            els.cloudinary.saveBtn.textContent = 'Save Cloudinary Settings';
        }
    });
}

// ── Push Notifications Module ──────────────────────────────
const notifEls = {
    form: document.getElementById('push-notification-form'),
    title: document.getElementById('notif-title'),
    message: document.getElementById('notif-message'),
    type: document.getElementById('notif-type'),
    version: document.getElementById('notif-version'),
    sendBtn: document.getElementById('btn-send-notification'),
    status: document.getElementById('notif-status-indicator'),
    historyList: document.getElementById('notifications-history-list'),
    countBadge: document.getElementById('notif-count-badge'),
    clearBtn: document.getElementById('btn-clear-notifications'),
    emptyNotice: document.getElementById('notifs-empty-notice'),
    presetBtns: document.querySelectorAll('.notif-preset-btn'),
};

const notifPresets = {
    update: {
        title: '🚀 WallSync Update Available',
        message: 'A new version of WallSync is ready with performance improvements and new features. Restart to apply!',
        type: 'update',
        version: '1.0.32.0',
    },
    wallpaper: {
        title: '🎨 New Wallpapers Added',
        message: 'Fresh curated live and 4K static wallpapers are now available in the catalog. Check them out now!',
        type: 'wallpaper',
        version: '',
    },
    announcement: {
        title: '📢 WallSync Maintenance Notice',
        message: 'Cloud sync server maintenance complete. All services and wallpaper live streaming are active.',
        type: 'announcement',
        version: '',
    },
};

if (notifEls.presetBtns) {
    notifEls.presetBtns.forEach((btn) => {
        btn.addEventListener('click', () => {
            const key = btn.dataset.preset;
            const preset = notifPresets[key];
            if (preset) {
                if (notifEls.title) notifEls.title.value = preset.title;
                if (notifEls.message) notifEls.message.value = preset.message;
                if (notifEls.type) notifEls.type.value = preset.type;
                if (notifEls.version) notifEls.version.value = preset.version;
                if (notifEls.title) notifEls.title.focus();
            }
        });
    });
}

async function fetchNotificationsHistory() {
    try {
        const res = await fetch('/api/notifications');
        if (res.ok) {
            const data = await res.json();
            renderNotificationsHistory(data.notifications || []);
        }
    } catch (_) {}
}

function renderNotificationsHistory(list) {
    if (!notifEls.historyList) return;
    if (notifEls.countBadge) notifEls.countBadge.textContent = list.length;

    notifEls.historyList.replaceChildren();

    if (!list || list.length === 0) {
        const emptyDiv = document.createElement('div');
        emptyDiv.className = 'clients-empty-notice';
        emptyDiv.id = 'notifs-empty-notice';
        const span = document.createElement('span');
        span.textContent = 'No broadcast notifications sent yet. Use the form above to send desktop alerts to all devices.';
        emptyDiv.appendChild(span);
        notifEls.historyList.appendChild(emptyDiv);
        return;
    }

    const typeIcons = {
        update: '🚀',
        wallpaper: '🎨',
        announcement: '📢',
        info: 'ℹ️',
    };

    list.forEach((item) => {
        const itemDiv = document.createElement('div');
        itemDiv.style.cssText = 'background: rgba(15, 17, 26, 0.6); border: 1px solid rgba(255, 255, 255, 0.08); border-radius: 8px; padding: 12px 14px; display: flex; flex-direction: column; gap: 4px;';

        const topRow = document.createElement('div');
        topRow.style.cssText = 'display: flex; justify-content: space-between; align-items: center;';

        const leftGroup = document.createElement('div');
        leftGroup.style.cssText = 'display: flex; align-items: center; gap: 8px;';

        const iconSpan = document.createElement('span');
        iconSpan.textContent = typeIcons[item.type] || '🔔';
        leftGroup.appendChild(iconSpan);

        const titleStrong = document.createElement('strong');
        titleStrong.style.cssText = 'color: #fff; font-size: 13px;';
        titleStrong.textContent = item.title || '';
        leftGroup.appendChild(titleStrong);

        const typeBadge = document.createElement('span');
        typeBadge.style.cssText = 'font-size: 11px; padding: 2px 8px; border-radius: 12px; background: rgba(59, 130, 246, 0.15); color: #60a5fa; border: 1px solid rgba(59, 130, 246, 0.3); text-transform: uppercase;';
        typeBadge.textContent = item.type || 'update';
        leftGroup.appendChild(typeBadge);

        if (item.version) {
            const verBadge = document.createElement('span');
            verBadge.style.cssText = 'font-size: 11px; color: var(--text-secondary); background: rgba(255, 255, 255, 0.05); padding: 2px 6px; border-radius: 4px;';
            verBadge.textContent = `v${item.version}`;
            leftGroup.appendChild(verBadge);
        }
        topRow.appendChild(leftGroup);

        const dateSpan = document.createElement('span');
        dateSpan.style.cssText = 'font-size: 11px; color: var(--text-secondary);';
        dateSpan.textContent = item.timestamp ? new Date(item.timestamp).toLocaleTimeString() + ' ' + new Date(item.timestamp).toLocaleDateString() : '';
        topRow.appendChild(dateSpan);

        itemDiv.appendChild(topRow);

        const p = document.createElement('p');
        p.style.cssText = 'margin: 4px 0 0; font-size: 12px; color: var(--text-secondary); line-height: 1.4;';
        p.textContent = item.message || '';
        itemDiv.appendChild(p);

        notifEls.historyList.appendChild(itemDiv);
    });
}

if (notifEls.form) {
    notifEls.form.addEventListener('submit', async (e) => {
        e.preventDefault();
        const title = notifEls.title.value.trim();
        const message = notifEls.message.value.trim();
        const type = notifEls.type.value;
        const version = notifEls.version ? notifEls.version.value.trim() : '';

        if (!title || !message) {
            showToast('Title and message are required.', 'error');
            return;
        }

        notifEls.sendBtn.disabled = true;
        notifEls.sendBtn.textContent = '⏳ Broadcasting...';
        if (notifEls.status) notifEls.status.textContent = 'Sending desktop alert to connected devices...';

        try {
            const res = await fetch('/api/notifications/send', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ title, message, type, version }),
            });
            const data = await res.json().catch(() => ({}));
            if (!res.ok) throw new Error(data.error || 'Failed to send notification.');

            showToast('✅ Desktop notification broadcasted to all active WallSync devices!');
            if (notifEls.title) notifEls.title.value = '';
            if (notifEls.message) notifEls.message.value = '';
            if (notifEls.version) notifEls.version.value = '';
            if (notifEls.status) notifEls.status.textContent = 'Last sent: Just now';
            fetchNotificationsHistory();
        } catch (err) {
            showToast(err.message, 'error');
            if (notifEls.status) notifEls.status.textContent = 'Failed to broadcast.';
        } finally {
            notifEls.sendBtn.disabled = false;
            notifEls.sendBtn.textContent = '📡 Broadcast Desktop Notification';
        }
    });
}

if (notifEls.clearBtn) {
    notifEls.clearBtn.addEventListener('click', async () => {
        if (!confirm('Are you sure you want to clear all notification history?')) return;
        try {
            const res = await fetch('/api/notifications/clear', { method: 'POST' });
            if (res.ok) {
                showToast('All notifications cleared successfully.');
                fetchNotificationsHistory();
            }
        } catch (err) {
            showToast('Failed to clear notifications.', 'error');
        }
    });
}

renderQueue();
configureFirebaseAuth();
initLiveSync();
fetchCatalogWallpapers();
updateServerStatusMetric();
loadCloudinaryConfig();
fetchNotificationsHistory();

// ==========================================================================
// Promotional Launch Popup Management
// ==========================================================================
async function fetchPopupConfig() {
    try {
        const res = await fetch('/api/popup');
        if (res.ok) {
            const data = await res.json();
            if (data && data.popup) {
                applyPopupConfigToForm(data.popup);
            }
        }
    } catch (_) {}
}

function applyPopupConfigToForm(config) {
    if (!els.popup.form) return;
    const isEnabled = Boolean(config.enabled);
    if (els.popup.toggle) els.popup.toggle.checked = isEnabled;
    if (els.popup.imageUrl) els.popup.imageUrl.value = config.imageUrl || '';
    if (els.popup.actionText) els.popup.actionText.value = config.actionText || 'Continue';
    if (els.popup.actionUrl) els.popup.actionUrl.value = config.actionUrl || '';
    updatePopupPreview();
}

function updatePopupPreview() {
    if (!els.popup.form) return;
    const isEnabled = els.popup.toggle ? els.popup.toggle.checked : false;
    const imageUrl = els.popup.imageUrl ? els.popup.imageUrl.value.trim() : '';
    const actionText = (els.popup.actionText && els.popup.actionText.value.trim()) ? els.popup.actionText.value.trim() : 'Continue';

    // Update status badge
    if (els.popup.badge) {
        els.popup.badge.textContent = isEnabled ? 'ACTIVE / LIVE' : 'DISABLED';
        els.popup.badge.className = isEnabled ? 'badge-status badge-enabled' : 'badge-status badge-disabled';
    }

    // Update action button text
    if (els.popup.previewActionText) {
        els.popup.previewActionText.textContent = actionText;
    }

    // Update image
    if (imageUrl) {
        if (els.popup.previewPosterImg) {
            els.popup.previewPosterImg.src = imageUrl;
            els.popup.previewPosterImg.style.display = 'block';
        }
        if (els.popup.previewPlaceholder) {
            els.popup.previewPlaceholder.style.display = 'none';
        }
    } else {
        if (els.popup.previewPosterImg) {
            els.popup.previewPosterImg.style.display = 'none';
            els.popup.previewPosterImg.src = '';
        }
        if (els.popup.previewPlaceholder) {
            els.popup.previewPlaceholder.style.display = 'flex';
        }
    }
}

if (els.popup.toggle) {
    els.popup.toggle.addEventListener('change', updatePopupPreview);
}
if (els.popup.imageUrl) {
    els.popup.imageUrl.addEventListener('input', updatePopupPreview);
}
if (els.popup.actionText) {
    els.popup.actionText.addEventListener('input', updatePopupPreview);
}
if (els.popup.previewCloseBtn) {
    els.popup.previewCloseBtn.addEventListener('click', () => {
        showToast('Preview close button clicked. In the desktop app, this dismisses the popup.');
    });
}
if (els.popup.previewActionBtn) {
    els.popup.previewActionBtn.addEventListener('click', () => {
        const url = els.popup.actionUrl ? els.popup.actionUrl.value.trim() : '';
        if (url) {
            showToast(`Preview action clicked! Would open: ${url}`);
        } else {
            showToast('Preview action clicked! (No redirect URL configured yet)');
        }
    });
}

if (els.popup.form) {
    els.popup.form.addEventListener('submit', async (e) => {
        e.preventDefault();
        const enabled = els.popup.toggle ? els.popup.toggle.checked : false;
        const imageUrl = els.popup.imageUrl ? els.popup.imageUrl.value.trim() : '';
        const actionText = els.popup.actionText ? els.popup.actionText.value.trim() : 'Continue';
        const actionUrl = els.popup.actionUrl ? els.popup.actionUrl.value.trim() : '';

        if (els.popup.saveBtn) {
            els.popup.saveBtn.disabled = true;
            els.popup.saveBtn.textContent = 'Saving Settings...';
        }
        if (els.popup.saveStatus) {
            els.popup.saveStatus.textContent = 'Saving configuration to server...';
        }

        try {
            const res = await fetch('/api/popup', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ enabled, imageUrl, actionText, actionUrl }),
            });
            const data = await res.json().catch(() => ({}));
            if (!res.ok) throw new Error(data.error || 'Failed to save popup configuration.');

            showToast('✅ Launch popup settings saved and synced successfully!');
            if (els.popup.saveStatus) {
                els.popup.saveStatus.textContent = 'Saved just now';
            }
            updatePopupPreview();
        } catch (err) {
            showToast(err.message, 'error');
            if (els.popup.saveStatus) {
                els.popup.saveStatus.textContent = 'Failed to save.';
            }
        } finally {
            if (els.popup.saveBtn) {
                els.popup.saveBtn.disabled = false;
                els.popup.saveBtn.textContent = 'Save Popup Settings';
            }
        }
    });
}

fetchPopupConfig();

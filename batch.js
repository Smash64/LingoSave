const RECENT_FOLDERS_KEY = 'lingosave-recent-folders-v1';
const DOWNLOAD_OPTIONS_KEY = 'lingosave-download-options-v1';
const downloadOptionSelectors = {
  quality: '#batch-quality', container: '#batch-container'
};
const downloadCheckGroups = {
  audioFormats: '#batch-audio-formats input',
  subtitleFormats: '#batch-subtitle-format input',
  audioLanguages: '#batch-audio-box .batch-language-choices input',
  subtitleLanguages: '#batch-subtitle-languages input'
};

function rememberDownloadOptions() {
  const options = { parts: selectedParts() };
  for (const [key, selector] of Object.entries(downloadOptionSelectors)) options[key] = $(selector).value;
  for (const [key, selector] of Object.entries(downloadCheckGroups)) {
    options[key] = $$(selector).filter((input) => input.checked).map((input) => input.value);
  }
  const path = $('#batch-path').value.trim();
  if (isAbsolutePath(path)) options.path = path;
  try { localStorage.setItem(DOWNLOAD_OPTIONS_KEY, JSON.stringify(options)); } catch { /* Keep current in-memory selections. */ }
}

function restoreDownloadOptions() {
  let options;
  try { options = JSON.parse(localStorage.getItem(DOWNLOAD_OPTIONS_KEY) || 'null'); } catch { return; }
  if (!options || typeof options !== 'object') return;
  const names = Object.keys(batchState.defaultParts);
  if (names.every((name) => typeof options.parts?.[name] === 'boolean')) {
    for (const name of names) $('#batch-part-' + name).checked = options.parts[name];
    batchState.partsDirty = true;
  }
  for (const [key, selector] of Object.entries(downloadOptionSelectors)) {
    const select = $(selector);
    if ([...select.querySelectorAll('option')].some((option) => option.value === options[key])) select.value = options[key];
  }
  for (const [key, selector] of Object.entries(downloadCheckGroups)) {
    const values = options[key] ?? (key === 'subtitleFormats' && options.subtitleFormat ? [options.subtitleFormat] : null);
    if (!Array.isArray(values)) continue;
    for (const input of $$(selector)) input.checked = values.includes(input.value);
  }
  if (typeof options.path === 'string' && isAbsolutePath(options.path)) {
    $('#batch-path').value = options.path;
    batchState.pathDirty = true;
  }
}

function loadRecentFolders() {
  try {
    const paths = JSON.parse(localStorage.getItem(RECENT_FOLDERS_KEY) || '[]');
    return Array.isArray(paths) ? paths.filter((path) => typeof path === 'string' && path.length < 1024 && isAbsolutePath(path)).slice(0, 5) : [];
  } catch { return []; }
}

const batchState = {
  defaultParts: { video: true, audio: false, subtitles: true }, partsDirty: false, savingDefaultParts: false,
  online: false, urls: [], preview: null, previewing: false, submitting: false,
  folderBusy: false, healthPending: false, jobsPending: false, pathDirty: false, requestId: 0,
  historyJobSnapshot: '',
  jobsRevision: 0, clearJobsPending: false, deletingJobs: new Set(),
  maxConcurrentDownloads: 3, concurrencyPending: false,
  lastJobs: [], taskCards: new Map(), jobActions: new Set(), inspectionCache: new Map(),
  videoChoices: new Map(), sourceSelections: new Map(), sourceOwners: new Map(), inspectionViews: new Map(), inspectionsPending: new Set(),
  cookieSites: {}, cookieLoaded: false, cookieStatusPending: false, cookieAction: null,
  cookieActionKind: null, cookieError: null, recentFolders: loadRecentFolders(),
  recentLinks: [], failedLinks: [], historyLoaded: false, historyPending: false,
  historyActions: new Set(), historyError: '', revealActions: new Set()
};
const COOKIE_SITES = { youtube: 'YouTube', bilibili: 'Bilibili', arte: 'ARTE', radiofrance: 'Radio France' };

const SITE_NOTES = {};

function applySupportedSites(sites) {
  if (!Array.isArray(sites)) return;
  const entries = sites.filter((site) => site && /^[a-z][a-z0-9-]{0,31}$/.test(site.id) && typeof site.label === 'string' && site.label.length > 0 && site.label.length <= 80);
  if (!entries.length || entries.length > 100) return;
  for (const key of Object.keys(COOKIE_SITES)) delete COOKIE_SITES[key];
  for (const key of Object.keys(SITE_NOTES)) delete SITE_NOTES[key];
  for (const site of entries) {
    COOKIE_SITES[site.id] = site.label;
    if (typeof site.note === 'string' && site.note.length <= 400) SITE_NOTES[site.id] = site.note;
  }
  const hint = $('#supported-site-list');
  if (hint) hint.textContent = `支持：${entries.map((site) => site.label).join('、')}。部分视频需在设置中导入对应网站的 Cookie。`;
}

function renderRecentFolders() {
  const box = $('#recent-folders');
  const list = $('#recent-folder-list');
  list.replaceChildren();
  box.hidden = batchState.recentFolders.length === 0;
  for (const path of batchState.recentFolders) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'recent-folder';
    button.textContent = path;
    button.title = path;
    button.setAttribute('aria-label', `使用最近目录 ${path}`);
    button.addEventListener('click', () => {
      $('#batch-path').value = path;
      $('#batch-path').dispatchEvent(new Event('input', { bubbles: true }));
    });
    list.append(button);
  }
}

function recordRecentFolder(path) {
  if (!isAbsolutePath(path)) return;
  const key = (value) => value.replace(/[\\/]+$/, '').toLowerCase();
  batchState.recentFolders = [path, ...batchState.recentFolders.filter((entry) => key(entry) !== key(path))].slice(0, 5);
  try { localStorage.setItem(RECENT_FOLDERS_KEY, JSON.stringify(batchState.recentFolders)); } catch { /* recent list remains available during this session */ }
  renderRecentFolders();
}

function batchLinks() {
  const input = $('#batch-urls').value.replace(/[,，;；、](?=https?:\/\/)/gi, '\n');
  const matches = input.match(/https?:\/\/[^\s<>"']+/gi) || [];
  return [...new Set(matches.map((value) => value.replace(/[，。；、\]),.;!?]+$/g, '')))];
}

function batchError(selector, message) {
  const element = $(selector);
  element.textContent = message;
  element.hidden = !message;
}

function linksAreSubmittable() {
  return batchState.urls.length >= 1 && batchState.urls.length <= 200;
}

function selectedParts() {
  return {
    video: $('#batch-part-video').checked,
    audio: $('#batch-part-audio').checked,
    subtitles: $('#batch-part-subtitles').checked
  };
}

function applyDefaultParts(parts) {
  for (const name of Object.keys(batchState.defaultParts)) {
    if (typeof parts?.[name] === 'boolean') batchState.defaultParts[name] = parts[name];
    $('#default-part-' + name).checked = batchState.defaultParts[name];
    if (!batchState.partsDirty) $('#batch-part-' + name).checked = batchState.defaultParts[name];
  }
  refreshBatchControls();
}

window.lingoSaveDefaultParts = async () => {
  if (batchState.savingDefaultParts) return;
  const names = Object.keys(batchState.defaultParts);
  const parts = Object.fromEntries(names.map((name) => [name, $('#default-part-' + name).checked]));
  if (names.every((name) => parts[name] === batchState.defaultParts[name])) return;
  const result = $('#default-parts-result');
  batchState.savingDefaultParts = true;
  for (const name of names) $('#default-part-' + name).disabled = true;
  result.classList.remove('is-error');
  result.textContent = '正在保存…';
  refreshBatchControls();
  try {
    if (!batchState.online) throw new Error('本机服务未连接，请连接后再次离开设置页。');
    if (!Object.values(parts).some(Boolean)) throw new Error('请至少选择一种默认下载内容。');
    const settings = await batchApi('/api/settings', { method: 'POST', body: JSON.stringify({ defaultDownloadParts: parts }) });
    batchState.partsDirty = false;
    applyDefaultParts(settings.defaultDownloadParts || parts);
    rememberDownloadOptions();
    result.classList.remove('is-error');
    result.textContent = '已保存';
  } catch (error) {
    result.classList.add('is-error');
    result.textContent = error.message;
    showToast('默认下载内容未保存：' + error.message);
  } finally {
    batchState.savingDefaultParts = false;
    for (const name of names) $('#default-part-' + name).disabled = false;
    refreshBatchControls();
  }
};

function refreshBatchControls() {
  const choices = $$('.video-choice input');
  const toggle = $('#toggle-video-choices');
  if (toggle) {
    toggle.textContent = choices.length && choices.every((input) => input.checked) ? '取消全选' : '全选';
    toggle.disabled = batchState.submitting || !choices.length;
  }
  for (const input of choices) input.disabled = batchState.submitting;
  const parts = selectedParts();
  if (batchState.preview) {
    const selected = chosenPreviewSources();
    const count = (batchState.preview.items || []).reduce((sum, item) => {
      if (!selected.urls.includes(item.url)) return sum;
      return sum + (item.kind === 'playlist' ? (selected.selectedVideos[item.url]?.length ?? item.entries?.length ?? 0) : 1);
    }, 0);
    $('#batch-action-summary').textContent = '已勾选 ' + count + ' 个资源';
  }
  $('#batch-preview-button').disabled = batchState.previewing || batchState.submitting || !batchState.online || !linksAreSubmittable();
  $('#batch-preview-button').textContent = batchState.previewing ? '正在解析…' : '解析链接';
  $('#batch-start-button').disabled = batchState.savingDefaultParts || batchState.submitting || !batchState.online || !linksAreSubmittable() || !Object.values(parts).some(Boolean) || batchState.inspectionsPending.size > 0 || !chosenPreviewSources().urls.length;
  $('#batch-start-button').textContent = batchState.submitting ? '正在提交…' : '下载';
  $('#batch-urls').disabled = batchState.submitting;
  $$('.media-part input').forEach((input) => { input.disabled = batchState.submitting; });
  $('#batch-quality').disabled = batchState.submitting || !parts.video;
  $('#batch-container').disabled = batchState.submitting || !parts.video;
  $$('#batch-audio-formats input').forEach((input) => { input.disabled = batchState.submitting || !parts.audio; });
  $('#batch-audio-formats').classList.toggle('is-disabled', !parts.audio);
  $$('#batch-subtitle-format input').forEach((input) => { input.disabled = batchState.submitting || !parts.subtitles; });
  $('#batch-path').disabled = batchState.submitting;
  $('#batch-folder-button').disabled = batchState.submitting || batchState.folderBusy || !batchState.online;
  $$('#batch-audio-box input[type="checkbox"]').forEach((input) => { input.disabled = batchState.submitting || !parts.audio; });
  $$('#batch-subtitle-box input[type="checkbox"]').forEach((input) => { input.disabled = batchState.submitting || !parts.subtitles; });
  $$('.inspection-choice input').forEach((input) => { input.disabled = batchState.submitting || !parts[input.dataset.part]; });
  $$('.inspection-trigger').forEach((button) => { button.disabled = batchState.submitting || !batchState.online || batchState.inspectionsPending.has(button.dataset.pendingKey); });
  $('#batch-quality-field').classList.toggle('is-disabled', !parts.video);
  $('#batch-container-field').classList.toggle('is-disabled', !parts.video);
  $('#batch-audio-box').classList.toggle('is-disabled', !parts.audio);
  $('#batch-subtitle-box').classList.toggle('is-disabled', !parts.subtitles);
  $('#default-folder-button').disabled = batchState.folderBusy || !batchState.online;
}

async function batchApi(path, options = {}) {
  const response = await fetch(path, {
    cache: 'no-store',
    ...options,
    headers: { ...(options.body ? { 'Content-Type': 'application/json' } : {}), ...(options.headers || {}) }
  });
  let data;
  try { data = await response.json(); }
  catch { throw new Error(`本机服务返回无效响应（HTTP ${response.status}）。`); }
  if (!response.ok) throw new Error(data.error || data.message || `请求失败（HTTP ${response.status}）。`);
  return data;
}

window.lingoServiceReady = () => batchState.online;
window.lingoSaveSettings = (path) => batchApi('/api/settings', {
  method: 'POST', body: JSON.stringify({ defaultDownloadPath: path })
});

async function chooseNativeFolder(currentPath) {
  if (!batchState.online) throw new Error('请先启动本机下载服务，再选择文件夹。');
  if (batchState.folderBusy) return null;
  batchState.folderBusy = true;
  refreshBatchControls();
  try {
    const result = await batchApi('/api/select-folder', { method: 'POST', body: JSON.stringify({ currentPath: currentPath || null }) });
    return result.cancelled ? null : result.path;
  } finally {
    batchState.folderBusy = false;
    refreshBatchControls();
  }
}

async function chooseFolderInto(input, button) {
  const originalLabel = button.textContent;
  button.textContent = '正在选择…';
  try {
    const path = await chooseNativeFolder(input.value.trim());
    if (path) {
      input.value = path;
      input.dispatchEvent(new Event('input', { bubbles: true }));
    }
  } catch (error) { showToast(error.message); }
  finally { button.textContent = originalLabel; }
}

function setServiceStatus(online, message) {
  const changed = batchState.online !== online;
  batchState.online = online;
  if (!online) batchState.cookieError = null;
  $('#batch-service-message').textContent = message;
  $('#sidebar-service-label').textContent = online ? '本机下载服务已连接' : '本机下载服务未连接';
  $('.status-dot').classList.toggle('is-offline', !online);
  $('#batch-service-notice').hidden = online;
  refreshBatchControls();
  renderRealJobs();
  renderLinkHistory();
  if (changed) renderCookieSettings();
}

async function checkBatchService() {
  if (batchState.healthPending) return;
  batchState.healthPending = true;
  try {
    const data = await batchApi('/api/health');
    if (!data.ready) throw new Error(data.error || '下载依赖尚未就绪');
    const wasOffline = !batchState.online;
    const warning = Array.isArray(data.warnings) && data.warnings.length ? ` ${data.warnings.join(' ')}` : '';
    setServiceStatus(true, `本机下载服务已连接。播放列表支持勾选需要的条目。${warning}`);
    if (wasOffline) {
      try {
        const settings = await batchApi('/api/settings');
        window.lingoApplyServerDefaultPath(settings.defaultDownloadPath);
        applyConcurrencySetting(settings.maxConcurrentDownloads);
        applyDefaultParts(settings.defaultDownloadParts ?? batchState.defaultParts);
      } catch {
        if (typeof data.defaultDownloadPath === 'string') window.lingoApplyServerDefaultPath(data.defaultDownloadPath);
      }
    }
    if (!batchState.pathDirty && !$('#batch-path').value.trim()) $('#batch-path').value = window.lingoGetDefaultPath();
    if (wasOffline) {
      await refreshRealJobs();
      await refreshCookieSettings();
      await refreshLinkHistory();
    }
  } catch (error) {
    setServiceStatus(false, `下载服务未就绪：${error.message}。请重新启动 LingoSave，页面会自动重连。`);
  } finally { batchState.healthPending = false; }
}

function renderCookieSettings() {
  const box = $('#cookie-sites');
  box.replaceChildren();
  const message = $('#cookie-settings-message');
  if (batchState.cookieError) message.textContent = batchState.cookieError;
  else if (!batchState.online) message.textContent = '本机服务未连接，启动后可查看和管理网站 Cookie。';
  else if (batchState.cookieStatusPending) message.textContent = '正在读取导入状态…';
  else if (!batchState.cookieLoaded && !batchState.cookieStatusPending) message.textContent = '尚未读取导入状态。';
  else if (batchState.cookieLoaded) message.textContent = '';
  for (const [site, label] of Object.entries(COOKIE_SITES)) {
    const metadata = batchState.cookieSites[site] || null;
    const card = document.createElement('article');
    card.className = 'cookie-site';
    const heading = document.createElement('div');
    heading.className = 'cookie-site-heading';
    const title = document.createElement('strong');
    title.textContent = label;
    const status = document.createElement('span');
    status.className = `cookie-status${metadata ? ' is-imported' : ''}`;
    status.textContent = metadata ? '已导入，待验证' : '未导入';
    heading.append(title, status);
    const detail = document.createElement('p');
    detail.className = 'cookie-detail';
    detail.textContent = metadata ?
      `${metadata.importedAt || '导入时间未知'} · ${Number(metadata.cookieCount) || 0} 条 Cookie${Number(metadata.ignoredCount) ? ` · 忽略 ${Number(metadata.ignoredCount)} 条不相关记录` : ''}` :
      '尚未为此网站导入 Cookie 文件。';
    const actions = document.createElement('div');
    actions.className = 'cookie-actions';
    const importButton = document.createElement('button');
    importButton.type = 'button';
    importButton.className = 'button button-secondary';
    importButton.textContent = batchState.cookieAction === site && batchState.cookieActionKind === 'import' ? '正在导入…' : metadata ? '重新导入' : '导入 Cookie 文件';
    importButton.disabled = !batchState.online || batchState.cookieStatusPending || !!batchState.cookieAction;
    importButton.addEventListener('click', () => changeCookie(site, 'import'));
    actions.append(importButton);
    if (metadata) {
      const removeButton = document.createElement('button');
      removeButton.type = 'button';
      removeButton.className = 'button button-secondary cookie-remove';
      removeButton.textContent = batchState.cookieAction === site && batchState.cookieActionKind === 'remove' ? '正在移除…' : '移除';
      removeButton.disabled = !batchState.online || batchState.cookieStatusPending || !!batchState.cookieAction;
      removeButton.addEventListener('click', () => changeCookie(site, 'remove'));
      actions.append(removeButton);
    }
    card.append(heading, detail);
    if (SITE_NOTES[site]) {
      const note = document.createElement('p');
      note.className = 'helper-text';
      note.textContent = SITE_NOTES[site];
      card.append(note);
    }
    card.append(actions);
    box.append(card);
  }
}

async function refreshCookieSettings() {
  if (!batchState.online || batchState.cookieStatusPending || batchState.cookieAction) return;
  batchState.cookieStatusPending = true;
  batchState.cookieError = null;
  renderCookieSettings();
  try {
    const data = await batchApi('/api/cookies');
    applySupportedSites(data.supportedSites);
    batchState.cookieSites = data.sites || {};
    batchState.cookieLoaded = true;
  } catch (error) {
    batchState.cookieError = `读取 Cookie 状态失败：${error.message}`;
  } finally { batchState.cookieStatusPending = false; renderCookieSettings(); }
}

async function changeCookie(site, action) {
  if (!batchState.online || batchState.cookieAction || !COOKIE_SITES[site]) return;
  batchState.cookieAction = site;
  batchState.cookieActionKind = action;
  batchState.cookieError = null;
  renderCookieSettings();
  try {
    const data = await batchApi(`/api/cookies/${site}/${action}`, { method: 'POST', body: '{}' });
    if (action === 'import') {
      if (data.cancelled) showToast('已取消选择，原有 Cookie 保持不变');
      else {
        batchState.cookieSites[site] = data.credential || null;
        showToast(`${COOKIE_SITES[site]} Cookie 已导入，待验证`);
      }
    } else {
      batchState.cookieSites[site] = null;
      showToast(`${COOKIE_SITES[site]} Cookie 已移除`);
    }
    renderCookieSettings();
  } catch (error) {
    batchState.cookieError = `${COOKIE_SITES[site]}：${error.message}`;
  } finally {
    batchState.cookieAction = null;
    batchState.cookieActionKind = null;
    renderCookieSettings();
  }
}

function updateBatchInput() {
  batchState.requestId++;
  batchState.urls = batchLinks();
  batchState.preview = null;
  batchState.videoChoices.clear();
  for (const [url] of batchState.sourceSelections) {
    if (!batchState.urls.includes(batchState.sourceOwners.get(url) || url)) {
      batchState.sourceSelections.delete(url);
      batchState.sourceOwners.delete(url);
    }
  }
  batchState.inspectionViews.clear();
  batchState.inspectionsPending.clear();
  $('#batch-preview-panel').hidden = true;
  $('#batch-input-count').textContent = `已识别 ${batchState.urls.length} 条不同链接`;
  $('#batch-action-summary').textContent = batchState.urls.length ? '可直接加入队列，也可先解析链接查看范围' : '粘贴链接后选择下载设置';
  batchError('#batch-input-error', batchState.urls.length > 200 ? '一次最多处理 200 条不同链接。' : '');
  batchError('#batch-start-error', '');
  refreshBatchControls();
}

function inspectionSourceLabel(source) {
  return source === 'auto' || source === 'platform_asr' ? '平台自动字幕' : '网站提供字幕';
}

const trackCollator = new Intl.Collator('en', { sensitivity: 'base', numeric: true });
const englishLanguages = typeof Intl.DisplayNames === 'function' ? new Intl.DisplayNames(['en'], { type: 'language' }) : null;
const languageFallbacks = { ar: 'Arabic', zh: 'Chinese', en: 'English', fr: 'French', de: 'German', it: 'Italian', ja: 'Japanese', ko: 'Korean', pt: 'Portuguese', es: 'Spanish', und: 'Unknown' };

function englishLanguageName(track) {
  if (track.englishLanguageName) return String(track.englishLanguageName);
  const raw = String(track.language || track.rawKey || 'und').replace(/_/g, '-');
  const code = raw.replace(/-(orig|acc)(?:-.*)?$/i, '');
  if (!code || code.toLowerCase() === 'und') return 'Unknown';
  if (code.toLowerCase() === 'mul') return 'Multilingual';
  try {
    const name = englishLanguages?.of(code);
    if (name && name !== code) return name;
  } catch { /* extractor keys may include non-language suffixes */ }
  return languageFallbacks[trackLanguage(code)] || 'Unknown';
}

function sortedTracks(tracks, subtitles = false) {
  return [...tracks].sort((a, b) =>
    trackCollator.compare(englishLanguageName(a), englishLanguageName(b)) ||
    (!subtitles && Number(a.role === 'description') - Number(b.role === 'description')) ||
    trackCollator.compare(a.name || a.note || '', b.name || b.note || '') ||
    (Number(b.bitrate) || 0) - (Number(a.bitrate) || 0) ||
    trackCollator.compare(subtitles ? subtitleKey(a) : String(a.formatId || ''), subtitles ? subtitleKey(b) : String(b.formatId || '')));
}

function durationLabel(seconds) {
  const value = Number(seconds);
  if (!Number.isFinite(value) || value < 0) return '时长未知';
  const whole = Math.floor(value);
  const minutes = Math.floor(whole / 60);
  const remaining = String(whole % 60).padStart(2, '0');
  return `${minutes}:${remaining}`;
}

function trackLanguage(value) {
  return String(value || 'und').toLowerCase().split(/[-_]/)[0];
}

function preferredLanguages(part) {
  const selector = part === 'subtitle' ? downloadCheckGroups.subtitleLanguages : downloadCheckGroups.audioLanguages;
  return $$(selector + ':checked').map((input) => input.value);
}

function subtitleRecord(track) {
  return {
    rawKey: String(track.rawKey || track.language || ''),
    source: track.source === 'auto' || track.source === 'platform_asr' ? 'auto' : 'provided'
  };
}

function subtitleKey(track) {
  const value = subtitleRecord(track);
  return `${value.source}:${value.rawKey}`;
}

function chooseDefaultAudio(tracks) {
  const preferences = preferredLanguages('audio');
  if (!preferences.length) return [];
  const available = tracks.filter((track) => track.formatId);
  const chooseBest = (candidates) => candidates.sort((a, b) =>
    Number(a.role === 'description') - Number(b.role === 'description') ||
    Number(b.audioOnly) - Number(a.audioOnly) || (Number(b.bitrate) || 0) - (Number(a.bitrate) || 0))[0];
  const chosen = preferences.map((language) => chooseBest(available.filter((track) => trackLanguage(track.language) === language))).filter(Boolean);
  return [...new Set(chosen.map((track) => String(track.formatId)))];
}

function chooseDefaultSubtitles(tracks) {
  const preferences = preferredLanguages('subtitle');
  if (!preferences.length) return [];
  const available = tracks.filter((track) => subtitleRecord(track).rawKey);
  const chosen = [];
  for (const language of preferences) {
    const matches = available.filter((track) => trackLanguage(track.rawKey || track.language) === language && !/-acc(?:$|[-_])/i.test(track.rawKey || ''));
    const exact = matches.find((track) => String(track.rawKey).toLowerCase() === language && subtitleRecord(track).source === 'provided');
    const selected = exact || matches.find((track) => subtitleRecord(track).source === 'provided') || matches[0];
    if (selected) chosen.push(selected);
  }
  return chosen.map(subtitleRecord).filter((record, index, all) => all.findIndex((other) => subtitleKey(other) === subtitleKey(record)) === index);
}

function inspectionSection(heading, items, part, selected, describe, onChange, notice = '') {
  const section = document.createElement('section');
  section.className = 'inspection-section';
  const title = document.createElement('h3');
  title.textContent = heading.includes('（') ? heading : `${heading}（${items.length}）`;
  section.append(title);
  if (!items.length) {
    const empty = document.createElement('p');
    empty.className = 'helper-text';
    empty.textContent = notice || (part === 'audio' ? '没有识别到可单独选择的音轨；完整视频仍会保留自身声音。' : '没有识别到可下载的外部字幕；完整视频仍可下载。');
    if (notice) { empty.classList.add('inspection-subtitle-notice'); empty.setAttribute('role', 'status'); }
    section.append(empty);
    return section;
  }
  const list = document.createElement('div');
  list.className = 'inspection-list';
  if (notice) { const message = document.createElement('p'); message.className = 'helper-text inspection-subtitle-notice'; message.textContent = notice; message.setAttribute('role', 'status'); section.append(message); }

  for (const item of items) {
    const row = document.createElement('label');
    row.className = 'inspection-choice';
    const input = document.createElement('input');
    input.type = 'checkbox';
    input.dataset.part = part === 'audio' ? 'audio' : 'subtitles';
    input.checked = selected(item);
    input.disabled = batchState.submitting || !selectedParts()[input.dataset.part];
    input.addEventListener('change', () => onChange(item, input.checked));
    const content = document.createElement('span');
    const strong = document.createElement('strong');
    const details = document.createElement('small');
    const text = describe(item);
    strong.textContent = text.title;
    details.textContent = text.detail;
    content.append(strong, details);
    row.append(input, content);
    list.append(row);
  }
  section.append(list);
  return section;
}

function updateInspectionSelectionStatus(container, selection, data) {
  const intro = container.querySelector('.inspection-intro');
  const status = container.querySelector('.inspection-selection-status');
  if (!intro || !status) return;
  intro.textContent = '音轨和字幕按英文语言名称 A–Z 排序。默认勾选随语言偏好更新；手动勾选后保留您的选择。仅选音轨或字幕时，只下载所选资源；不存在则提示并跳过。';
  const missing = [];
  const parts = selectedParts();
  if (parts.audio && Array.isArray(data.audioTracks) && data.audioTracks.length && !selection.audioFormatIds.length) {
    missing.push(selection.explicitAudio ? '当前视频未选择独立音轨；可以在下方重新勾选' : '音轨语言偏好没有匹配项，当前视频不会另存音轨；可以在下方手动勾选');
  }
  if (parts.subtitles && Array.isArray(data.subtitles) && data.subtitles.length && !selection.subtitleTracks.length) {
    missing.push(selection.explicitSubtitles ? '当前视频未选择外部字幕；可以在下方重新勾选' : '字幕语言偏好没有匹配项，当前视频不会另存字幕；可以在下方手动勾选');
  }
  status.textContent = missing.join('。');
  status.hidden = !status.textContent;
}

function renderInspection(container, data, url) {
  container.replaceChildren();
  batchState.inspectionViews.set(url, { container, data });
  const audioTracks = sortedTracks(Array.isArray(data.audioTracks) ? data.audioTracks : []);
  const subtitles = sortedTracks(Array.isArray(data.subtitles) ? data.subtitles : [], true);
  const subtitleAvailability = data.subtitleAvailability === 'needs-login' ? 'login-required' : data.subtitleAvailability;
  const subtitleNotice = String(data.subtitleNotice || ({ 'login-required': '该视频字幕需要登录，请在设置中导入 Bilibili Cookie 后重新解析。', failed: '字幕解析未完成，请重新解析或检查网站 Cookie。' })[subtitleAvailability] || '');
  const subtitleHeading = !subtitles.length && subtitleAvailability === 'login-required' ? '外部字幕（需登录）' :
    !subtitles.length && subtitleAvailability === 'failed' ? '外部字幕（解析未完成）' : '外部字幕';
  const mediaId = String(data.mediaId || data.id || '');
  let selection = batchState.sourceSelections.get(url);
  if (!selection || selection.mediaId !== mediaId) {
    selection = {
      mediaId,
      audioFormatIds: chooseDefaultAudio(audioTracks),
      subtitleTracks: chooseDefaultSubtitles(subtitles),
      explicitAudio: false,
      explicitSubtitles: false
    };
    batchState.sourceSelections.set(url, selection);
  }
  const intro = document.createElement('p');
  intro.className = 'inspection-intro';
  const meta = document.createElement('p');
  meta.className = 'inspection-meta';
  const formats = Array.isArray(data.formats) ? data.formats : [];
  meta.textContent = `${data.platform || '视频'} · ${durationLabel(data.duration)} · ${formats.length} 种媒体格式${Number.isFinite(Number(data.audioIdentityCount)) && data.audioIdentityCount != null ? ` · ${data.audioIdentityCount} 种音轨身份` : ''}${data.isLive ? ' · 直播资源' : ''}${data.availability ? ` · ${data.availability}` : ''}`;
  const selectionStatus = document.createElement('p');
  selectionStatus.className = 'inspection-selection-status';
  container.append(intro, meta, selectionStatus);
  updateInspectionSelectionStatus(container, selection, data);
  container.append(inspectionSection('独立音轨', audioTracks, 'audio',
    (track) => selection.audioFormatIds.includes(String(track.formatId)),
    (track) => ({
      title: `${track.displayName || englishLanguageName(track)} (${track.language || 'und'}) · 格式 ${track.formatId || '未知'}`,
      detail: [track.name || track.note, track.codec, track.bitrate ? `${track.bitrate} kbps` : '', track.channels ? `${track.channels} 声道` : '', track.audioOnly ? '独立音频' : '含画面的音频'].filter(Boolean).join(' · ') || '无更多格式信息'
    }),
    (track, checked) => {
      const id = String(track.formatId);
      selection.audioFormatIds = checked ? [...new Set([...selection.audioFormatIds, id])] : selection.audioFormatIds.filter((value) => value !== id);
      selection.explicitAudio = true;
      updateInspectionSelectionStatus(container, selection, data);
    }));
  container.append(inspectionSection(subtitleHeading, subtitles, 'subtitle',
    (track) => selection.subtitleTracks.some((chosen) => subtitleKey(chosen) === subtitleKey(track)),
    (track) => ({
      title: `${englishLanguageName(track)} (${track.rawKey || track.language || 'und'}) · ${inspectionSourceLabel(track.source)}`,
      detail: Array.isArray(track.formats) && track.formats.length ? `格式：${track.formats.join('、')}` : '字幕格式未标明'
    }),
    (track, checked) => {
      const key = subtitleKey(track);
      selection.subtitleTracks = checked ? [...selection.subtitleTracks, subtitleRecord(track)] : selection.subtitleTracks.filter((chosen) => subtitleKey(chosen) !== key);
      selection.explicitSubtitles = true;
      updateInspectionSelectionStatus(container, selection, data);
    }, subtitleNotice));
  const oneAudioIdentity = data.audioIdentityCount != null ? Number(data.audioIdentityCount) === 1 : audioTracks.length === 1;
  const subtitleUnresolved = ['login-required', 'failed'].includes(subtitleAvailability);
  if (oneAudioIdentity || (subtitles.length === 0 && !subtitleUnresolved)) {
    const note = document.createElement('p');
    note.className = 'inspection-note';
    note.textContent = oneAudioIdentity && !subtitles.length && !subtitleUnresolved ? '此视频只有一种可识别音轨身份，且没有外部字幕。' :
      oneAudioIdentity ? '此视频只有一种可识别音轨身份；不同编码或码率仍会列在上方供精确选择。' : '此视频没有可下载的外部字幕。';
    container.append(note);
  }
  if (data.truncated) {
    const notice = document.createElement('p');
    notice.className = 'field-error';
    notice.textContent = '资源条目较多，轨道列表已截断；未列出的轨道无法精确选择。';
    container.append(notice);
  }
}

async function inspectSource(url, content, trigger, requestId, force = false) {
  const pendingKey = `${requestId}:${url}`;
  if (batchState.inspectionsPending.has(pendingKey)) return;
  batchState.inspectionsPending.add(pendingKey);
  if (trigger) { trigger.dataset.pendingKey = pendingKey; trigger.disabled = true; trigger.textContent = '解析中…'; }
  content.textContent = '正在读取实际音轨与字幕…';
  refreshBatchControls();
  try {
    let data = force ? null : batchState.inspectionCache.get(url);
    if (!data) {
      let response = await batchApi('/api/inspect', { method: 'POST', body: JSON.stringify({ url }) });
      if (response.inspectionId) {
        for (let attempt = 0; attempt < 180 && response.status !== 'completed' && response.status !== 'failed'; attempt++) {
          if (requestId !== batchState.requestId) return;
          content.textContent = response.status === 'queued' ? '等待读取轨道…' : '正在读取实际音轨与字幕…';
          await new Promise((resolve) => setTimeout(resolve, 500));
          response = await batchApi(`/api/inspect/${encodeURIComponent(response.inspectionId)}`);
        }
        if (response.status === 'failed') throw new Error(response.error || '轨道读取失败。');
        if (response.status !== 'completed') throw new Error('轨道读取超时，请重试。');
        data = response.result;
      } else data = response;
      if (!data || typeof data !== 'object') throw new Error('轨道信息为空。');
      batchState.inspectionCache.set(url, data);
      if (batchState.inspectionCache.size > 100) batchState.inspectionCache.delete(batchState.inspectionCache.keys().next().value);
    }
    if (requestId !== batchState.requestId) return;
    renderInspection(content, data, url);
    if (trigger) { trigger.dataset.parsed = 'true'; trigger.textContent = '重新解析音轨与字幕'; }
  } catch (error) {
    if (requestId !== batchState.requestId) return;
    content.textContent = `读取轨道失败：${error.message}。可重新尝试，或使用下方语言偏好入队。`;
    if (trigger) { trigger.textContent = '重试解析音轨与字幕'; trigger.dataset.parsed = 'true'; }
  } finally {
    batchState.inspectionsPending.delete(pendingKey);
    refreshBatchControls();
  }
}

function addInspectionPicker(card, url, requestId, ownerUrl = url) {
  batchState.sourceOwners.set(url, ownerUrl);
  const panel = document.createElement('div');
  panel.className = 'inspection-panel';
  const trigger = document.createElement('button');
  trigger.className = 'button button-secondary inspection-trigger';
  trigger.type = 'button';
  trigger.textContent = batchState.inspectionCache.has(url) ? '显示已缓存音轨与字幕' : '解析音轨与字幕';
  const content = document.createElement('div');
  content.className = 'inspection-content';
  trigger.addEventListener('click', () => inspectSource(url, content, trigger, requestId, trigger.dataset.parsed === 'true'));
  panel.append(trigger, content);
  card.append(panel);
}

function previewEntryUrl(entry, source) {
  const url = entry.webpageUrl || entry.webpage_url || entry.url;
  if (/^https?:\/\//i.test(String(url || ''))) return String(url);
  const id = String(entry.id || url || '');
  if (/youtube/i.test(String(source.platform || source.url || '')) && /^[A-Za-z0-9_-]{11}$/.test(id)) return `https://www.youtube.com/watch?v=${id}`;
  if (/bilibili/i.test(String(source.platform || source.url || '')) && /^BV[A-Za-z0-9]+$/.test(id)) return `https://www.bilibili.com/video/${id}`;
  return null;
}

function videoChoiceKey(source, entry) { return JSON.stringify([source.url, entry ? String(entry.id || previewEntryUrl(entry, source) || '') : source.url]); }
function addVideoChoice(parent, source, entry, title) {
  const key = videoChoiceKey(source, entry);
  const label = document.createElement('label'); label.className = 'video-choice';
  const input = document.createElement('input'); input.type = 'checkbox';
  input.dataset.choiceKey = key;
  input.checked = batchState.videoChoices.get(key) !== false;
  input.addEventListener('change', () => { batchState.videoChoices.set(key, input.checked); refreshBatchControls(); });
  label.append(input, title); parent.append(label);
}
function chosenPreviewSources() {
  const selectedVideos = {};
  const urls = batchState.urls.filter((url) => {
    const item = batchState.preview?.items?.find((source) => source.url === url);
    if (!item) return true;
    if (item.kind !== 'playlist' || !item.entries?.length) return batchState.videoChoices.get(videoChoiceKey(item)) !== false;
    const entries = Array.isArray(item.entries) ? item.entries : [];
    const chosen = entries.filter((entry) => batchState.videoChoices.get(videoChoiceKey(item, entry)) !== false);
    if (entries.length && !chosen.length) return false;
    if (chosen.length !== entries.length) selectedVideos[url] = chosen.map((entry) => String(entry.id || previewEntryUrl(entry, item)));
    return true;
  });
  return {urls, selectedVideos};
}
function renderBatchPreview() {
  const data = batchState.preview;
  const requestId = batchState.requestId;
  const list = $('#batch-preview-list');
  list.replaceChildren();
  const items = data.items || [];
  const bad = items.filter((item) => item.error);
  const playlistCount = items.filter((item) => item.kind === 'playlist').length;
  const hasEstimatedCount = items.some((item) => item.countIsEstimate);
  const total = Number(data.totalVideos) || 0;
  $('#batch-preview-summary').textContent = `${items.length} 条来源 · ${playlistCount} 个播放列表 · ${hasEstimatedCount ? '已预览至少' : '预计'} ${total} 个资源${bad.length ? ` · ${bad.length} 条解析失败` : ''}`;
  const toolbar = document.createElement('div'); toolbar.className = 'video-choice-toolbar';
  const toggle = document.createElement('button');
  toggle.id = 'toggle-video-choices';
  toggle.type = 'button';
  toggle.className = 'button button-secondary';
  toggle.addEventListener('click', () => {
    const choices = list.querySelectorAll('.video-choice input');
    const checked = !Array.from(choices).every((input) => input.checked);
    for (const input of choices) {
      input.checked = checked;
      batchState.videoChoices.set(input.dataset.choiceKey, checked);
    }
    refreshBatchControls();
  });
  toolbar.append(toggle);
  list.append(toolbar);
  for (const item of items) {
    const card = document.createElement('article');
    card.className = `batch-source${item.error ? ' has-error' : ''}`;
    const title = document.createElement('strong');
    title.textContent = item.title || item.url || '未知资源';
    const meta = document.createElement('div');
    meta.className = 'batch-source-meta';
    meta.textContent = item.error ? `解析失败 · ${item.error}` : item.kind === 'playlist' ?
      `${item.platform || '播放列表'} · ${item.countIsEstimate ? `已预览 ${item.count ?? 20} 项，完整数量未知` : `全部 ${item.count ?? '未知数量'} 个资源`}` :
      `${item.platform || '资源'} · ${item.mediaType === 'audio' ? '单集音频' : '单个视频'}`;
    const url = document.createElement('code');
    url.textContent = item.url || '';
    if (item.kind === 'playlist' && item.entries?.length) card.append(title); else addVideoChoice(card, item, null, title);
    card.append(meta, url);
    if (!item.error && ['video', 'audio'].includes(item.kind)) addInspectionPicker(card, item.url, requestId);
    if (!item.error && item.kind === 'playlist') {
      const note = document.createElement('p');
      note.className = 'batch-more';
      note.textContent = item.mediaType === 'audio' ? `${item.platform || '播客'}系列自动按音频下载，以系列名建文件夹、分集标题命名。` : '点击具体视频后才解析音轨与字幕。未解析的条目在下载时按语言偏好匹配；仅下载勾选的条目。';
      if (item.platform === 'Radio France') note.textContent += '勾选外部字幕和 French 可保存有官方转录的分集字幕。';
      card.append(note);
    }
    if (Array.isArray(item.entries) && item.entries.length) {
      const preview = document.createElement('ol');
      preview.className = 'batch-entry-list';
      preview.tabIndex = 0;
      preview.setAttribute('aria-label', '播放列表预览，可上下滚动查看');
      for (const entry of item.entries) {
        const li = document.createElement('li');
        const entryTitle = document.createElement('strong');
        entryTitle.textContent = entry.title || entry.id || '未命名视频';
        addVideoChoice(li, item, entry, entryTitle);
        const entryUrl = previewEntryUrl(entry, item);
        if (entryUrl && !item.error) addInspectionPicker(li, entryUrl, requestId, item.url);
        preview.append(li);
      }
      card.append(preview);
      if (item.countIsEstimate || Number(item.count) > item.entries.length) {
        const more = document.createElement('p');
        more.className = 'batch-more';
        more.textContent = `当前解析出 ${item.entries.length} 项，可勾选需要的条目。`;
        card.append(more);
      }
    }
    list.append(card);
  }
  $('#batch-preview-panel').hidden = false;
  $('#batch-action-summary').textContent = bad.length ? `${bad.length} 条未能预览；入队后仍会尝试下载` : total ? `${hasEstimatedCount ? '已预览至少' : '准备下载约'} ${total} 个资源` : '预览未发现视频；仍可入队尝试';
  refreshBatchControls();
}

async function previewBatch() {
  if (batchState.previewing || batchState.submitting) return;
  updateBatchInput();
  if (!batchState.online) { batchError('#batch-input-error', '本机下载服务尚未连接。'); return; }
  if (!batchState.urls.length) { batchError('#batch-input-error', '请粘贴至少一条 HTTP 或 HTTPS 链接。'); return; }
  if (!linksAreSubmittable()) { batchError('#batch-input-error', '一次最多处理 200 条不同链接。'); return; }
  const requestId = batchState.requestId;
  const urls = [...batchState.urls];
  batchState.previewing = true;
  refreshBatchControls();
  try {
    await recordRecentLinks(urls);
    let preview = await batchApi('/api/preview', { method: 'POST', body: JSON.stringify({ urls }) });
    if (preview.previewId) {
      while (preview.status !== 'completed' && preview.status !== 'failed') {
        if (requestId !== batchState.requestId) return;
        $('#batch-preview-button').textContent = preview.status === 'queued' ? '等待解析…' :
          `正在解析 ${Number(preview.processed) || 0}/${Number(preview.totalSources) || urls.length}`;
        await new Promise((resolve) => setTimeout(resolve, 500));
        preview = await batchApi(`/api/preview/${encodeURIComponent(preview.previewId)}`);
      }
      if (preview.status === 'failed') throw new Error(preview.error || '资源预览失败。');
      preview = preview.result;
    }
    if (requestId !== batchState.requestId) return;
    batchState.preview = preview;
    renderBatchPreview();
  } catch (error) {
    if (requestId === batchState.requestId) batchError('#batch-input-error', error.message);
  } finally {
    batchState.previewing = false;
    refreshBatchControls();
  }
}

async function startBatch() {
  if (batchState.savingDefaultParts || batchState.submitting || !batchState.online || !linksAreSubmittable()) return;
  batchError('#batch-start-error', '');
  const parts = selectedParts();
  if (!Object.values(parts).some(Boolean)) { batchError('#batch-start-error', '请至少选择视频、独立音轨或外部字幕中的一项。'); return; }
  if (batchState.inspectionsPending.size) { batchError('#batch-start-error', '正在读取轨道，请完成后再加入队列。'); return; }
  const path = $('#batch-path').value.trim();
  if (!isAbsolutePath(path)) { batchError('#batch-start-error', '请输入 Windows 绝对路径，或点击“选择文件夹”。'); return; }
  const subtitleLanguages = $$('#batch-subtitle-languages input:checked').map((input) => input.value);
  const audioLanguages = $$('#batch-audio-box input[type="checkbox"]:checked').map((input) => input.value);
  const audioOutputFormats = $$('#batch-audio-formats input:checked').map((input) => input.value);
  if (!audioOutputFormats.length && parts.audio) { batchError('#batch-start-error', '请至少选择一种音频格式。'); return; }
  const videoSelection = chosenPreviewSources();
  if (!videoSelection.urls.length) { batchError('#batch-start-error', '请至少勾选一个视频或音频节目。'); return; }
  const subtitleFormats = $$('#batch-subtitle-format input:checked').map((input) => input.value);
  if (parts.subtitles && !subtitleFormats.length) { batchError('#batch-start-error', '请至少选择一种字幕格式。'); return; }
  const payload = {
    urls: videoSelection.urls, selectedVideos: videoSelection.selectedVideos, path, parts, autoSimplify: false,
    quality: $('#batch-quality').value, container: $('#batch-container').value,
    audioOutputFormats: audioOutputFormats.length ? audioOutputFormats : ['original'], audioLanguages, subtitleLanguages, subtitleFormats: subtitleFormats.length ? subtitleFormats : ['srt'],
    sourceSelections: Object.fromEntries([...batchState.sourceSelections].filter(([url]) => videoSelection.urls.includes(batchState.sourceOwners.get(url) || url)).map(([url, selection]) => [url, {
      mediaId: selection.mediaId,
      audioFormatIds: selection.audioFormatIds,
      subtitleTracks: selection.subtitleTracks,
      explicitAudio: selection.explicitAudio,
      explicitSubtitles: selection.explicitSubtitles
    }]))
  };
  batchState.submitting = true;
  refreshBatchControls();
  try {
    await recordRecentLinks(payload.urls);
    const result = await batchApi('/api/jobs', { method: 'POST', body: JSON.stringify(payload) });
    showToast(result.settingsWarning || '下载任务已加入队列');
    if (result.defaultDownloadPath) window.lingoApplyServerDefaultPath(result.defaultDownloadPath);
    recordRecentFolder(result.job?.path || path);
    $('#batch-urls').value = '';
    updateBatchInput();
    batchState.pathDirty = false;
    $('#batch-path').value = window.lingoGetDefaultPath();
    setPage('tasks');
    if (result.job) batchState.lastJobs = [result.job, ...batchState.lastJobs.filter((job) => job.id !== result.job.id)];
    renderRealJobs();
    await refreshRealJobs();
  } catch (error) { batchError('#batch-start-error', error.message); }
  finally { batchState.submitting = false; refreshBatchControls(); }
}

function statusLabel(value) {
  return ({ queued: '排队中', running: '下载中', waiting_network: '等待网络恢复', pausing: '暂停中', paused: '已暂停', completed: '已完成', partial: '部分完成', failed: '失败', unavailable: '不可用', cancelled: '已取消', skipped: '已跳过' })[value] || value || '处理中';
}

function bytesLabel(value) {
  const number = Number(value);
  if (!Number.isFinite(number) || number < 0) return '未知';
  if (number < 1024) return `${Math.round(number)} B`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let size = number / 1024;
  let index = 0;
  while (size >= 1024 && index < units.length - 1) { size /= 1024; index++; }
  return `${size >= 100 ? size.toFixed(0) : size.toFixed(1)} ${units[index]}`;
}

function assetLabel(value) {
  if (!value) return '';
  const raw = typeof value === 'object' ? String(value.label || value.type || value.kind || '') : String(value);
  return ({ video: '视频', audio: '独立音轨', subtitle: '外部字幕', subtitles: '外部字幕', source: '来源解析', inspect: '读取资源', download: '下载', merge: '合并', verify: '校验', convert: '转换', conversion: '转换', processing: '媒体处理', waiting_capacity: '等待空闲名额' })[raw] || raw;
}

function isProcessingAsset(value) {
  return /^(inspect|merge|verify|convert|conversion|processing|waiting_capacity)$/.test(String(value || ''));
}

function downloadPercent(value) {
  if (value == null || value === '' || !Number.isFinite(Number(value))) return null;
  // The API reports a fraction in [0, 1] for the current media file.
  return Math.max(0, Math.min(1, Number(value))) * 100;
}

function progressPercentLabel(percent) {
  return `${Math.round(percent * 10) / 10}%`;
}

function transferLabel(value) {
  const phase = value.phase || value.stage;
  if (isProcessingAsset(phase)) value = { ...value, currentAsset: phase };
  const details = [];
  if (value.currentAsset) details.push(`${isProcessingAsset(value.currentAsset) ? '当前阶段' : '当前文件'}：${assetLabel(value.currentAsset)}`);
  const percent = downloadPercent(value.progress);
  if (!isProcessingAsset(value.currentAsset) && percent != null) {
    details.push(`进度 ${progressPercentLabel(percent)}`);
  } else if (value.status === 'running' && !isProcessingAsset(value.currentAsset)) details.push('进度未知');
  const downloaded = Number(value.downloadedBytes);
  const total = Number(value.totalBytes);
  if (!isProcessingAsset(value.currentAsset) && value.downloadedBytes != null && Number.isFinite(downloaded) && downloaded >= 0) {
    details.push(`已传输 ${bytesLabel(downloaded)}${value.totalBytes != null && Number.isFinite(total) && total > 0 ? ` / ${bytesLabel(total)}` : ''}`);
  }
  const speed = Number(value.speedBytesPerSecond);
  if (value.status === 'running' && !isProcessingAsset(value.currentAsset) && value.speedBytesPerSecond != null && Number.isFinite(speed) && speed > 0) details.push(`速度 ${bytesLabel(speed)}/s`);
  else if (value.status === 'running' && !isProcessingAsset(value.currentAsset)) details.push('速度未知');
  const eta = Number(value.etaSeconds);
  if (value.status === 'running' && !isProcessingAsset(value.currentAsset) && value.etaSeconds != null && Number.isFinite(eta) && eta >= 0) {
    details.push(`预计剩余 ${eta < 60 ? `${Math.ceil(eta)} 秒` : `${Math.ceil(eta / 60)} 分钟`}`);
  }
  return details.join(' · ');
}

function createTaskCard(id) {
  const card = document.createElement('article');
  card.className = 'task-card real-task';
  card.dataset.jobId = id;
  card.innerHTML = '<div class="task-main"><div><h2 class="task-title"></h2><p class="task-subtitle"></p></div><span class="task-status"></span></div><div class="real-task-detail"></div><p class="job-transfer" hidden></p><progress class="progress-track" max="100" hidden></progress><p class="job-message" hidden></p><div class="task-actions"><button class="details-button job-pause" type="button" hidden>暂停</button><button class="details-button job-resume" type="button" hidden>继续下载</button><button class="details-button job-cancel" type="button" hidden>取消下载</button><button class="details-button job-retry" type="button" hidden>重试任务</button><button class="details-button job-delete" type="button" title="清除这条任务记录，保留已下载的文件">清除记录</button></div><div class="job-completed-files" hidden></div><details class="job-items" hidden><summary></summary><div class="job-item-list" tabindex="0" aria-label="资源明细，可上下滚动查看"></div></details>';
  card.querySelector('.job-pause').addEventListener('click', () => actOnJob(id, 'pause'));
  card.querySelector('.job-resume').addEventListener('click', () => actOnJob(id, 'resume'));
  card.querySelector('.job-cancel').addEventListener('click', () => actOnJob(id, 'cancel'));
  card.querySelector('.job-retry').addEventListener('click', () => actOnJob(id, 'retry'));
  card.querySelector('.job-delete').addEventListener('click', () => clearJobRecords(id));
  card.querySelector('.job-items').addEventListener('toggle', (event) => {
    if (event.currentTarget.open) renderJobItems(card, batchState.lastJobs.find((job) => job.id === id));
  });
  return card;
}

function completedFilePaths(item) {
  const paths = (Array.isArray(item.assets) ? item.assets : [])
    .filter((asset) => asset.status === 'completed' && asset.path)
    .map((asset) => asset.path);
  if (!paths.length && item.status === 'completed' && item.path) paths.push(item.path);
  return [...new Set(paths)];
}

function folderButton(jobId, path) {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'folder-open-button';
  button.dataset.jobId = String(jobId);
  button.dataset.path = String(path);
  button.title = `在文件夹中查看：${path}`;
  button.setAttribute('aria-label', `在文件夹中查看：${path}`);
  button.innerHTML = '<svg viewBox="0 0 24 24" width="17" height="17" aria-hidden="true"><path d="M3 7a2 2 0 0 1 2-2h5l2 2h7a2 2 0 0 1 2 2v10H3V7Z" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linejoin="round"/></svg>';
  const key = `${jobId}:${path}`;
  button.disabled = !batchState.online || batchState.revealActions.has(key);
  button.addEventListener('click', async () => {
    if (!batchState.online || batchState.revealActions.has(key)) return;
    batchState.revealActions.add(key);
    button.disabled = true;
    try {
      const data = await batchApi('/api/reveal-file', { method: 'POST', body: JSON.stringify({ jobId, path }) });
      if (data.message) showToast(data.message);
    } catch (error) { showToast(error.message); }
    finally { batchState.revealActions.delete(key); button.disabled = !batchState.online; }
  });
  return button;
}

function renderCompletedFiles(card, job) {
  const box = card.querySelector('.job-completed-files');
  const files = (Array.isArray(job.items) ? job.items : []).flatMap((item) =>
    completedFilePaths(item).map((path) => ({ path, title: item.title || item.id || path.split(/[\\/]/).pop() })));
  const fingerprint = JSON.stringify([job.id, files, batchState.online]);
  if (box.dataset.fingerprint === fingerprint) return;
  const scrollTop = box.scrollTop || 0;
  box.replaceChildren();
  box.hidden = !files.length;
  box.tabIndex = 0;
  box.setAttribute('aria-label', '已完成文件，可上下滚动查看');
  for (const file of files) {
    const row = document.createElement('div');
    row.className = 'completed-video';
    const title = document.createElement('span');
    title.textContent = file.title;
    row.append(title, folderButton(job.id, file.path));
    box.append(row);
  }
  box.dataset.fingerprint = fingerprint;
  box.scrollTop = scrollTop;
}

function renderJobItems(card, job) {
  if (!job || !Array.isArray(job.items)) return;
  const box = card.querySelector('.job-item-list');
  const fingerprint = JSON.stringify([job.id, job.items, batchState.online]);
  if (box.dataset.fingerprint === fingerprint) return;
  const scrollTop = box.scrollTop || 0;
  box.replaceChildren();
  for (const item of job.items) {
    const row = document.createElement('div');
    row.className = 'job-item';
    const heading = document.createElement('div');
    const title = document.createElement('strong');
    title.textContent = item.title || item.id || item.url || '未命名视频';
    const status = document.createElement('span');
    status.className = `job-item-status status-${item.status || 'queued'}`;
    status.textContent = statusLabel(item.status);
    const actions = document.createElement('span');
    actions.className = 'job-item-heading-actions';
    actions.append(status);
    for (const path of completedFilePaths(item)) actions.append(folderButton(job.id, path));
    heading.append(title, actions);
    row.append(heading);
    const transfer = transferLabel(item);
    if (transfer && ['running', 'waiting_network', 'pausing', 'paused'].includes(item.status)) { const metrics = document.createElement('p'); metrics.className = 'job-item-transfer'; metrics.textContent = transfer; row.append(metrics); }
    if (Array.isArray(item.assets) && item.assets.length) {
      const assets = document.createElement('div');
      assets.className = 'job-asset-list';
      for (const asset of item.assets) {
        const assetRow = document.createElement('div');
        assetRow.className = 'job-asset';
        const heading = document.createElement('div');
        const name = document.createElement('strong');
        const kind = asset.type === 'audio' && asset.outputFormat ? `独立音轨（${asset.outputFormat === 'original' ? '原始音频' : 'MP3'}）` : assetLabel(asset.type || asset.kind || asset.assetType) || '文件';
        const detail = [asset.language, asset.type === 'subtitle' && asset.source ? inspectionSourceLabel(asset.source) : asset.source, asset.trackId].filter(Boolean).join(' · ');
        name.textContent = detail ? `${kind} · ${detail}` : kind;
        const state = document.createElement('span');
        state.className = `job-item-status status-${asset.status || 'queued'}`;
        state.textContent = statusLabel(asset.status);
        heading.append(name, state);
        if (asset.status === 'completed' && asset.path) heading.append(folderButton(job.id, asset.path));
        assetRow.append(heading);
        const assetTransfer = transferLabel(asset);
        if (assetTransfer && asset.status === 'running') { const metrics = document.createElement('p'); metrics.className = 'job-item-transfer'; metrics.textContent = assetTransfer; assetRow.append(metrics); }
        const notice = asset.recoveryMessage || asset.message;
        if (notice) { const message = document.createElement('p'); message.className = 'helper-text'; message.textContent = notice; assetRow.append(message); }
        if (asset.error) { const error = document.createElement('p'); error.className = 'field-error'; error.textContent = asset.error; assetRow.append(error); }
        if (asset.path) { const path = document.createElement('code'); path.textContent = asset.path; assetRow.append(path); }
        assets.append(assetRow);
      }
      row.append(assets);
    }
    if (item.error) { const error = document.createElement('p'); error.className = 'field-error'; error.textContent = item.error; row.append(error); }
    const notice = item.recoveryMessage || item.message || item.reason;
    if (notice) { const message = document.createElement('p'); message.className = 'helper-text'; message.textContent = notice; row.append(message); }
    if (item.path) { const path = document.createElement('code'); path.textContent = item.path; row.append(path); }
    box.append(row);
  }
  box.dataset.fingerprint = fingerprint;
  box.scrollTop = scrollTop;
}

function jobDownloadLabel(job) {
  const types = new Set();
  if (job.parts) {
    if (job.parts.video) types.add('video');
    if (job.parts.audio) types.add('audio');
    if (job.parts.subtitles) types.add('subtitle');
  } else {
    for (const item of job.items || []) {
      for (const asset of item.assets || []) {
        if (['video', 'audio', 'subtitle'].includes(asset.type)) types.add(asset.type);
      }
    }
    if (!types.size && job.mode === 'audio') types.add('audio');
    if (!types.size && ['video', 'audio', 'subtitle'].includes(job.currentAsset)) types.add(job.currentAsset);
  }
  const labels = [['video', '视频'], ['audio', '音轨'], ['subtitle', '字幕']]
    .filter(([type]) => types.has(type)).map(([, label]) => label);
  return `${labels.join('、') || '资源'}下载`;
}

function updateTaskCard(card, job) {
  const sourceCount = job.sourceCount || job.urls?.length || 1;
  card.querySelector('.task-title').textContent = sourceCount === 1 ? `单条来源的${jobDownloadLabel(job)}` : `${sourceCount} 条来源的批量${jobDownloadLabel(job)}`;
  card.querySelector('.task-subtitle').textContent = `${job.createdAt || ''} · ${job.path || ''}`;
  const status = card.querySelector('.task-status');
  const allSkipped = job.status === 'completed' && Number(job.completed) === 0 && Number(job.skipped) > 0 && !Number(job.failed);
  status.textContent = allSkipped ? '已跳过' : statusLabel(job.status);
  status.className = `task-status status-${allSkipped ? 'skipped' : job.status || 'queued'}`;
  const total = job.total ?? '?';
  const completed = Number(job.completed) || 0;
  const skipped = Number(job.skipped) || 0;
  const failed = Number(job.failed) || 0;
  const current = job.currentTitle ? ` · 当前：${job.currentTitle}` : '';
  card.querySelector('.real-task-detail').textContent = `已完成 ${completed} / ${total} 个资源${skipped ? ` · 跳过 ${skipped}` : ''}${failed ? ` · 失败 ${failed}` : ''}${current}`;
  const transfer = card.querySelector('.job-transfer');
  transfer.textContent = ['running', 'waiting_network', 'pausing', 'paused'].includes(job.status) ? transferLabel(job) : '';
  transfer.hidden = !transfer.textContent;
  const progress = card.querySelector('.progress-track');
  const percent = downloadPercent(job.progress);
  const showProgress = ['running', 'waiting_network', 'pausing', 'paused'].includes(job.status) && !isProcessingAsset(job.phase) && !isProcessingAsset(job.currentAsset) && percent != null;
  progress.hidden = !showProgress;
  if (showProgress) {
    progress.value = percent;
    progress.setAttribute('aria-label', `当前文件下载进度 ${progressPercentLabel(percent)}`);
  }
  const message = card.querySelector('.job-message');
  message.textContent = job.error || job.message || '';
  message.hidden = !message.textContent;
  message.classList.toggle('field-error', !!job.error);
  const waiting = batchState.jobActions.has(job.id) || batchState.deletingJobs.has(job.id) || batchState.clearJobsPending;
  const pause = card.querySelector('.job-pause');
  pause.hidden = !['queued', 'running', 'waiting_network', 'pausing'].includes(job.status);
  pause.textContent = job.status === 'pausing' ? '暂停中…' : '暂停';
  pause.disabled = waiting || job.status === 'pausing' || !batchState.online;
  const resume = card.querySelector('.job-resume');
  resume.hidden = job.status !== 'paused';
  resume.disabled = waiting || !batchState.online;
  const cancel = card.querySelector('.job-cancel');
  cancel.hidden = !['queued', 'running', 'waiting_network', 'pausing', 'paused'].includes(job.status);
  cancel.disabled = waiting || !batchState.online;
  const retry = card.querySelector('.job-retry');
  retry.hidden = !['failed', 'partial', 'cancelled'].includes(job.status);
  retry.disabled = waiting || !batchState.online;
  const remove = card.querySelector('.job-delete');
  const canClear = canClearJob(job);
  remove.disabled = waiting || !canClear || !batchState.online;
  remove.textContent = batchState.deletingJobs.has(job.id) ? '正在清除…' : '清除记录';
  remove.title = canClear ? '清除这条任务记录，保留已下载的文件' : '请先取消任务，待取消完成后可清除记录';
  renderCompletedFiles(card, job);
  const details = card.querySelector('.job-items');
  const itemCount = Array.isArray(job.items) ? job.items.length : 0;
  details.hidden = itemCount === 0;
  details.querySelector('summary').textContent = `查看资源明细（${itemCount} 项）`;
  if (details.open) renderJobItems(card, job);
}

function renderRealJobs() {
  const list = $('#real-tasks-list');
  const jobs = batchState.lastJobs;
  const active = jobs.filter((job) => ['queued', 'running', 'waiting_network', 'pausing'].includes(job.status)).length;
  const paused = jobs.filter((job) => job.status === 'paused').length;
  const clear = $('#clear-task-records');
  clear.disabled = !batchState.online || batchState.clearJobsPending || batchState.deletingJobs.size > 0 || batchState.jobActions.size > 0 || !jobs.some(canClearJob);
  clear.textContent = batchState.clearJobsPending ? '正在清空…' : '清空任务记录';
  const concurrency = $('#task-concurrency');
  concurrency.disabled = !batchState.online || batchState.concurrencyPending;
  if (!batchState.concurrencyPending) concurrency.value = String(batchState.maxConcurrentDownloads);
  const summary = $('#tasks-summary');
  summary.textContent = batchState.online ? `${jobs.length} 个任务 · ${active} 个进行中${paused ? ` · ${paused} 个已暂停` : ''}` :
    jobs.length ? `本机服务未连接，显示上次获取的 ${jobs.length} 个任务状态。` : '本机服务未连接。';
  const badge = $('#nav-count');
  badge.textContent = active;
  badge.hidden = active === 0;
  if (!jobs.length) {
    batchState.taskCards.clear();
    list.replaceChildren();
    const box = document.createElement('div');
    box.className = 'empty-state';
    box.innerHTML = batchState.online ? '<div class="empty-symbol">▤</div><h2>还没有下载任务</h2><p>粘贴一个或多个链接后即可加入队列。</p><button class="button button-primary" type="button">新建下载</button>' :
      '<div class="empty-symbol">⌁</div><h2>本机服务未连接</h2><p>启动 run.ps1 后，页面会自动重连并显示任务。</p>';
    const button = box.querySelector('button');
    if (button) button.addEventListener('click', () => setPage('batch'));
    list.append(box);
    return;
  }
  const validIds = new Set(jobs.map((job) => job.id));
  for (const [id, card] of batchState.taskCards) {
    if (!validIds.has(id)) { card.remove(); batchState.taskCards.delete(id); }
  }
  for (const job of jobs) {
    let card = batchState.taskCards.get(job.id);
    if (!card) { card = createTaskCard(job.id); batchState.taskCards.set(job.id, card); }
    updateTaskCard(card, job);
  }
  for (let index = 0; index < jobs.length; index++) {
    const card = batchState.taskCards.get(jobs[index].id);
    if (list.children[index] !== card) list.insertBefore(card, list.children[index] || null);
  }
  while (list.children.length > jobs.length) list.lastElementChild.remove();
}

async function refreshRealJobs() {
  if (!batchState.online || batchState.jobsPending || batchState.clearJobsPending || batchState.deletingJobs.size) return;
  batchState.jobsPending = true;
  const revision = batchState.jobsRevision;
  try {
    const signal = typeof AbortSignal !== 'undefined' && typeof AbortSignal.timeout === 'function' ? AbortSignal.timeout(5000) : undefined;
    const data = await batchApi('/api/jobs', signal ? { signal } : {});
    if (revision !== batchState.jobsRevision) return;
    batchState.lastJobs = Array.isArray(data.jobs) ? data.jobs : [];
    renderRealJobs();
    const historySnapshot = JSON.stringify(batchState.lastJobs.filter((job) => ['completed', 'partial', 'failed'].includes(job.status)).map((job) => [job.id, job.status, job.attempt]));
    if (historySnapshot !== batchState.historyJobSnapshot && !batchState.historyPending && !batchState.historyActions.size) {
      batchState.historyJobSnapshot = historySnapshot;
      // History I/O must not hold the progress polling lock or delay the next snapshot.
      void refreshLinkHistory();
    }
  } catch (error) {
    if (revision !== batchState.jobsRevision) return;
    setServiceStatus(false, `本机服务连接中断：${error.message}。页面会自动重连。`);
  } finally { batchState.jobsPending = false; }
}

function canClearJob(job) {
  return ['completed', 'partial', 'failed', 'cancelled'].includes(job?.status);
}

async function clearJobRecords(id = null) {
  if (!batchState.online || batchState.clearJobsPending || batchState.deletingJobs.size || batchState.jobActions.size) return;
  if (id && !canClearJob(batchState.lastJobs.find((job) => job.id === id))) {
    showToast('请先取消任务，待取消完成后可清除记录');
    return;
  }
  if (id) batchState.deletingJobs.add(id);
  else batchState.clearJobsPending = true;
  // An older polling response must not bring cleared cards back into view.
  batchState.jobsRevision++;
  renderRealJobs();
  try {
    const data = await batchApi(id ? `/api/jobs/${encodeURIComponent(id)}` : '/api/jobs/clear', {
      method: id ? 'DELETE' : 'POST', ...(id ? {} : { body: '{}' })
    });
    if (Array.isArray(data.jobs)) batchState.lastJobs = data.jobs;
    else {
      const removed = new Set(data.removedIds || (id ? [id] : []));
      batchState.lastJobs = batchState.lastJobs.filter((job) => !removed.has(job.id));
    }
    batchState.jobsRevision++;
    renderRealJobs();
    const retained = Array.isArray(data.retainedActive) ? data.retainedActive.length : 0;
    showToast(id ? '已清除任务记录，下载文件保留' : `已清除 ${Number(data.removedCount) || 0} 条任务记录，下载文件保留${retained ? `；保留 ${retained} 个未结束任务` : ''}`);
  } catch (error) { showToast(error.message); }
  finally {
    if (id) batchState.deletingJobs.delete(id);
    else batchState.clearJobsPending = false;
    renderRealJobs();
    void refreshRealJobs();
  }
}

function applyConcurrencySetting(value) {
  const count = Number(value);
  batchState.maxConcurrentDownloads = Number.isInteger(count) && count >= 1 && count <= 5 ? count : 3;
  $('#task-concurrency').value = String(batchState.maxConcurrentDownloads);
}

async function saveConcurrencySetting() {
  if (!batchState.online || batchState.concurrencyPending) return;
  const count = Number($('#task-concurrency').value);
  if (!Number.isInteger(count) || count < 1 || count > 5) { applyConcurrencySetting(batchState.maxConcurrentDownloads); return; }
  batchState.concurrencyPending = true;
  renderRealJobs();
  try {
    const data = await batchApi('/api/settings', { method: 'POST', body: JSON.stringify({ maxConcurrentDownloads: count }) });
    applyConcurrencySetting(data.maxConcurrentDownloads ?? count);
    showToast(`已设置最多同时下载 ${batchState.maxConcurrentDownloads} 个任务`);
  } catch (error) { showToast(error.message); }
  finally { batchState.concurrencyPending = false; renderRealJobs(); }
}

async function actOnJob(id, action) {
  if (batchState.jobActions.has(id) || !batchState.online) return;
  batchState.jobActions.add(id);
  renderRealJobs();
  try {
    const data = await batchApi(`/api/jobs/${encodeURIComponent(id)}/${action}`, { method: 'POST', body: '{}' });
    if (data.job) batchState.lastJobs = batchState.lastJobs.map((job) => job.id === id ? data.job : job);
    showToast(({ cancel: '已取消任务', retry: '任务已重新加入队列', pause: '已请求暂停，正在保存下载进度', resume: '已继续下载，保留原任务与下载数据' })[action] || '任务已更新');
    await refreshRealJobs();
  } catch (error) { showToast(error.message); }
  finally { batchState.jobActions.delete(id); renderRealJobs(); }
}

function fillHistoryLink(url) {
  if (batchState.submitting) return;
  const links = batchLinks();
  if (!links.includes(url)) links.push(url);
  $('#batch-urls').value = links.join('\n');
  updateBatchInput();
  setPage('batch');
  $('#batch-urls').focus();
  showToast('链接已回填，可修改下载设置后再次解析或下载');
}

async function copyHistoryLink(url) {
  try {
    if (navigator.clipboard?.writeText) await navigator.clipboard.writeText(url);
    else {
      const field = document.createElement('textarea');
      field.value = url;
      field.className = 'clipboard-helper';
      document.body.append(field);
      field.select();
      const copied = document.execCommand('copy');
      field.remove();
      if (!copied) throw new Error('无法访问剪贴板，请手动复制链接。');
    }
    showToast('链接已复制');
  } catch (error) { showToast(error.message || '复制失败，请手动复制链接。'); }
}

function historyButton(label, handler, disabled = false, extraClass = '') {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = `history-button ${extraClass}`.trim();
  button.textContent = label;
  button.disabled = disabled;
  button.addEventListener('click', handler);
  return button;
}

function historyEmpty(box, message) {
  const paragraph = document.createElement('p');
  paragraph.className = 'helper-text history-empty';
  paragraph.textContent = message;
  box.append(paragraph);
}

function renderRecentLinkList(box) {
  const fingerprint = JSON.stringify([batchState.recentLinks, batchState.online, batchState.historyLoaded, [...batchState.historyActions], batchState.submitting]);
  if (box.dataset.fingerprint === fingerprint) return;
  box.replaceChildren();
  for (const entry of batchState.recentLinks.slice(0, 10)) {
    const row = document.createElement('article');
    row.className = 'history-link';
    const title = document.createElement('strong');
    title.textContent = entry.title || entry.platform || '视频或播放列表';
    const url = document.createElement('code');
    url.textContent = entry.url;
    const meta = document.createElement('p');
    meta.className = 'history-meta';
    meta.textContent = [entry.platform, entry.lastUsedAt].filter(Boolean).join(' · ');
    const actions = document.createElement('div');
    actions.className = 'history-actions';
    actions.append(
      historyButton('回填链接', () => fillHistoryLink(entry.url), batchState.submitting),
      historyButton('复制', () => copyHistoryLink(entry.url)),
      historyButton('删除', () => actOnHistory(`recent:${entry.url}`, '/api/history/recent/delete', { url: entry.url }), !batchState.online || batchState.historyActions.has(`recent:${entry.url}`), 'history-delete')
    );
    row.append(title, url, meta, actions);
    box.append(row);
  }
  if (!batchState.recentLinks.length) historyEmpty(box, batchState.historyLoaded ? '暂无链接输入历史。点击解析或加入下载队列后自动记录，去重保留最近 10 条。' : '连接本机服务后读取最近链接。');
  box.dataset.fingerprint = fingerprint;
}

function renderFailedLinkList() {
  const box = $('#failed-link-list');
  const unresolvedOnly = $('#failed-unresolved-only').checked;
  const entries = batchState.failedLinks.filter((entry) => !unresolvedOnly || entry.status !== 'resolved');
  const fingerprint = JSON.stringify([entries, batchState.online, batchState.historyLoaded, [...batchState.historyActions], batchState.submitting]);
  if (box.dataset.fingerprint === fingerprint) return;
  box.replaceChildren();
  for (const entry of entries) {
    const row = document.createElement('article');
    row.className = `history-link failed-history-link${entry.status === 'resolved' ? ' is-resolved' : ''}`;
    const heading = document.createElement('div');
    heading.className = 'history-link-heading';
    const title = document.createElement('strong');
    title.textContent = entry.title || entry.platform || '下载失败的资源';
    const status = document.createElement('span');
    status.className = 'history-failure-status';
    status.textContent = entry.status === 'resolved' ? '已解决' : '未解决';
    heading.append(title, status);
    const url = document.createElement('code');
    url.textContent = entry.url;
    const meta = document.createElement('p');
    meta.className = 'history-meta';
    meta.textContent = [entry.platform, entry.lastFailedAt, `失败 ${Number(entry.failureCount) || 1} 次`, entry.stage ? `阶段：${assetLabel(entry.stage)}` : '', entry.resolvedAt ? `解决于 ${entry.resolvedAt}` : ''].filter(Boolean).join(' · ');
    const error = document.createElement('p');
    error.className = 'history-failure-error';
    error.textContent = entry.error || '未提供详细失败原因';
    row.append(heading, url, meta, error);
    if (Array.isArray(entry.failedResources) && entry.failedResources.length) {
      const resources = document.createElement('p');
      resources.className = 'history-meta';
      resources.textContent = `资源记录：${entry.failedResources.map((resource) => typeof resource === 'string' ? assetLabel(resource) : [assetLabel(resource.type || resource.kind), resource.language, resource.status === 'resolved' ? '已恢复' : '待重试', resource.error].filter(Boolean).join(' · ')).join('；')}`;
      row.append(resources);
    }
    const actions = document.createElement('div');
    actions.className = 'history-actions';
    actions.append(
      historyButton('复制链接', () => copyHistoryLink(entry.url)),
      historyButton('回填链接', () => fillHistoryLink(entry.url), batchState.submitting),
      historyButton(batchState.historyActions.has(`retry:${entry.id}`) ? '正在重试…' : entry.status === 'resolved' ? '已恢复' : '重试失败资源', () => actOnHistory(`retry:${entry.id}`, `/api/history/failed/${encodeURIComponent(entry.id)}/retry`, {}), entry.status === 'resolved' || !batchState.online || batchState.historyActions.has(`retry:${entry.id}`)),
      historyButton('删除记录', () => actOnHistory(`failed:${entry.id}`, '/api/history/failed/delete', { id: entry.id }), !batchState.online || batchState.historyActions.has(`failed:${entry.id}`), 'history-delete')
    );
    row.append(actions);
    box.append(row);
  }
  if (!entries.length) historyEmpty(box, batchState.historyLoaded ? unresolvedOnly ? '没有未解决的失败记录。' : '暂无下载失败记录。缺失资源跳过、手动取消和断网等待不会记为下载失败。' : '连接本机服务后读取失败记录。');
  box.dataset.fingerprint = fingerprint;
}

function renderLinkHistory() {
  renderRecentLinkList($('#recent-link-list'));
  renderRecentLinkList($('#history-recent-link-list'));
  renderFailedLinkList();
  $('#recent-link-count').textContent = `${batchState.recentLinks.length} / 10`;
  const unresolved = batchState.failedLinks.filter((entry) => entry.status !== 'resolved').length;
  $('#failed-link-summary').textContent = `${batchState.failedLinks.length} 条记录 · ${unresolved} 条未解决`;
  $('#history-message').textContent = batchState.historyError || (batchState.historyPending && !batchState.historyLoaded ? '正在读取历史记录…' : !batchState.online ? '本机服务未连接，显示上次读取的历史记录。' : '');
  $('#history-message').classList.toggle('field-error', !!batchState.historyError);
  $$('.clear-recent-links').forEach((button) => { button.disabled = !batchState.online || !batchState.recentLinks.length || batchState.historyActions.has('clear-recent'); });
  $('#clear-failed-links').disabled = !batchState.online || !batchState.failedLinks.length || batchState.historyActions.has('clear-failed');
  $('#refresh-link-history').disabled = !batchState.online || batchState.historyPending;
}

async function refreshLinkHistory() {
  if (!batchState.online || batchState.historyPending || batchState.historyActions.size) return;
  batchState.historyPending = true;
  renderLinkHistory();
  try {
    const data = await batchApi('/api/history');
    batchState.recentLinks = Array.isArray(data.recentLinks) ? data.recentLinks : [];
    batchState.failedLinks = Array.isArray(data.failedLinks) ? data.failedLinks : [];
    batchState.historyLoaded = true;
    batchState.historyError = '';
  } catch (error) { batchState.historyError = `历史记录读取失败：${error.message}`; }
  finally { batchState.historyPending = false; renderLinkHistory(); }
}

async function recordRecentLinks(urls) {
  try {
    const data = await batchApi('/api/history/recent', { method: 'POST', body: JSON.stringify({ urls }) });
    if (Array.isArray(data.recentLinks)) batchState.recentLinks = data.recentLinks;
    else await refreshLinkHistory();
    batchState.historyError = '';
    renderLinkHistory();
  } catch (error) {
    batchState.historyError = `链接历史保存失败：${error.message}`;
    renderLinkHistory();
  }
}

async function actOnHistory(key, path, body, method = 'POST') {
  if (!batchState.online || batchState.historyActions.has(key)) return;
  batchState.historyActions.add(key);
  renderLinkHistory();
  try {
    const data = await batchApi(path, { method, ...(method === 'DELETE' ? {} : { body: JSON.stringify(body) }) });
    if (key.startsWith('retry:')) {
      showToast(data.message || '已重试失败资源，原有完整文件和下载数据将保留');
      setPage('tasks');
      if (data.job) batchState.lastJobs = [data.job, ...batchState.lastJobs.filter((job) => job.id !== data.job.id)];
      await refreshRealJobs();
    } else showToast(key.startsWith('clear-') ? '历史记录已清空' : '历史记录已删除');
    batchState.historyError = '';
  } catch (error) { batchState.historyError = error.message; showToast(error.message); }
  finally {
    batchState.historyActions.delete(key);
    await refreshLinkHistory();
    renderLinkHistory();
  }
}

$('#batch-urls').addEventListener('input', updateBatchInput);
$('#clear-recent-folders').addEventListener('click', () => {
  batchState.recentFolders = [];
  try { localStorage.removeItem(RECENT_FOLDERS_KEY); } catch { /* session list is already cleared */ }
  renderRecentFolders();
});
$('#batch-path').addEventListener('input', () => { batchState.pathDirty = true; });
window.addEventListener('lingosave:default-path-changed', (event) => {
  if (!batchState.pathDirty && !batchState.submitting) $('#batch-path').value = event.detail.path;
});
$('#batch-preview-button').addEventListener('click', previewBatch);
$('#batch-start-button').addEventListener('click', startBatch);
$('#clear-task-records').addEventListener('click', () => clearJobRecords());
$('#task-concurrency').addEventListener('change', saveConcurrencySetting);
$('#batch-folder-button').addEventListener('click', () => chooseFolderInto($('#batch-path'), $('#batch-folder-button')));
$('#default-folder-button').addEventListener('click', () => chooseFolderInto($('#default-path-input'), $('#default-folder-button')));
function refreshInspectedLanguageDefaults(part) {
  for (const [url, view] of batchState.inspectionViews) {
    const selection = batchState.sourceSelections.get(url);
    if (!selection) continue;
    if (part === 'audio') {
      if (selection.explicitAudio) continue;
      selection.audioFormatIds = chooseDefaultAudio(Array.isArray(view.data.audioTracks) ? view.data.audioTracks : []);
    } else {
      if (selection.explicitSubtitles) continue;
      selection.subtitleTracks = chooseDefaultSubtitles(Array.isArray(view.data.subtitles) ? view.data.subtitles : []);
    }
    renderInspection(view.container, view.data, url);
  }
  refreshBatchControls();
}
$$('#batch-audio-box .batch-language-choices input').forEach((input) => input.addEventListener('change', () => refreshInspectedLanguageDefaults('audio')));
$$('#batch-subtitle-languages input').forEach((input) => input.addEventListener('change', () => refreshInspectedLanguageDefaults('subtitles')));
$$('.media-part input').forEach((input) => input.addEventListener('change', () => {
  batchState.partsDirty = true;
  for (const [url, view] of batchState.inspectionViews) {
    const selection = batchState.sourceSelections.get(url);
    if (!selection) continue;
    renderInspection(view.container, view.data, url);
  }
  refreshBatchControls();
}));
$$('[data-page="tasks"]').forEach((button) => button.addEventListener('click', refreshRealJobs));
$$('[data-page="settings"]').forEach((button) => button.addEventListener('click', refreshCookieSettings));
$$('[data-page="history"]').forEach((button) => button.addEventListener('click', refreshLinkHistory));
$$('.clear-recent-links').forEach((button) => button.addEventListener('click', () => actOnHistory('clear-recent', '/api/history/recent', {}, 'DELETE')));
$('#clear-failed-links').addEventListener('click', () => actOnHistory('clear-failed', '/api/history/failed/clear', {}));
$('#refresh-link-history').addEventListener('click', refreshLinkHistory);
$('#failed-unresolved-only').addEventListener('change', renderLinkHistory);
updateBatchInput();
if (window.lingoGetDefaultPath()) $('#batch-path').value = window.lingoGetDefaultPath();
restoreDownloadOptions();
refreshBatchControls();
window.lingoRememberDownloadOptions = rememberDownloadOptions;
window.addEventListener('pagehide', () => {
  if (currentPage === 'batch') rememberDownloadOptions();
});
renderRealJobs();
renderCookieSettings();
renderRecentFolders();
renderLinkHistory();
checkBatchService();
setInterval(checkBatchService, 5000);
setInterval(refreshRealJobs, 500);

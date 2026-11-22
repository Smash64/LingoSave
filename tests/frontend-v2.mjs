import fs from 'node:fs/promises';
import vm from 'node:vm';
import assert from 'node:assert/strict';

// A small DOM adapter exercises the real event handlers and generated controls
// without navigating the user's running desktop app or requiring a browser.
class Element {
  constructor(tag = 'div') { this.tagName = tag.toLowerCase(); this.children = []; this.parentElement = null; this.dataset = {}; this.attributes = {}; this.listeners = {}; this._text = ''; this._value = ''; this.disabled = false; this.hidden = false; this.checked = false; this.open = false; this.className = ''; }
  get classList() { return { contains: (name) => this.className.split(/\s+/).includes(name), add: (...names) => { this.className = [...new Set([...this.className.split(/\s+/), ...names])].filter(Boolean).join(' '); }, remove: (...names) => { this.className = this.className.split(/\s+/).filter((name) => !names.includes(name)).join(' '); }, toggle: (name, force) => { const add = force ?? !this.className.split(/\s+/).includes(name); add ? this.classList.add(name) : this.classList.remove(name); return add; } }; }
  setAttribute(key, value) { this.attributes[key] = String(value); if (key === 'class') this.className = String(value); if (key === 'id') this.id = String(value); if (key.startsWith('data-')) this.dataset[key.slice(5).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = String(value); if (key === 'value') this._value = String(value); if (['checked', 'hidden', 'disabled', 'open'].includes(key)) this[key] = true; if (key === 'type') this.type = value; }
  removeAttribute(key) { delete this.attributes[key]; }
  get value() { if (this.tagName === 'select' && !this._value) return this.children.find((item) => item.tagName === 'option')?.value || ''; return this._value; }
  set value(value) { this._value = String(value); }
  set textContent(value) { this._text = String(value); this.children.forEach((item) => { item.parentElement = null; }); this.children = []; }
  get textContent() { return this._text + this.children.map((item) => item.textContent).join(''); }
  set innerHTML(value) { this.replaceChildren(); parseHtml(value, this); }
  append(...items) { for (const item of items) { item.remove(); item.parentElement = this; this.children.push(item); } }
  replaceChildren(...items) { for (const item of this.children) item.parentElement = null; this.children = []; this._text = ''; this.append(...items); }
  remove() { if (this.parentElement) { this.parentElement.children = this.parentElement.children.filter((item) => item !== this); this.parentElement = null; } }
  insertBefore(item, before) { item.remove(); item.parentElement = this; const index = this.children.indexOf(before); index < 0 ? this.children.push(item) : this.children.splice(index, 0, item); }
  get lastElementChild() { return this.children.at(-1); }
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
  async dispatchEvent(event) { event.currentTarget = this; event.target = this; await Promise.all((this.listeners[event.type] || []).map((fn) => fn(event))); }
  focus() { this.focused = true; }
  select() { this.selected = true; }
  querySelectorAll(selector) {
    const parts = selector.trim().split(/\s+/);
    const results = [];
    const visit = (element) => { for (const child of element.children) { if (matches(child, parts.at(-1))) { let ancestor = child.parentElement; let part = parts.length - 2; while (part >= 0 && ancestor) { if (matches(ancestor, parts[part])) part--; ancestor = ancestor.parentElement; } if (part < 0) results.push(child); } visit(child); } };
    visit(this); return results;
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
}
function matches(element, selector) {
  if (selector.includes(':checked') && !element.checked) return false;
  selector = selector.replace(':checked', '');
  const tag = selector.match(/^[a-z][\w-]*/i)?.[0];
  if (tag && element.tagName !== tag.toLowerCase()) return false;
  const id = selector.match(/#([\w-]+)/)?.[1];
  if (id && element.id !== id) return false;
  const classes = [...selector.matchAll(/\.([\w-]+)/g)].map((match) => match[1]);
  if (classes.some((name) => !element.classList.contains(name))) return false;
  for (const match of selector.matchAll(/\[([\w-]+)(?:="([^"]*)")?\]/g)) {
    const value = match[1].startsWith('data-') ? element.dataset[match[1].slice(5).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] : element.attributes[match[1]];
    if (value == null || (match[2] != null && value !== match[2])) return false;
  }
  return true;
}
function parseHtml(html, root) {
  const stack = [root];
  for (const match of html.matchAll(/<!--[\s\S]*?-->|<![^>]*>|<\/?[a-z][^>]*>|[^<]+/gi)) {
    const token = match[0];
    if (token.startsWith('<!')) continue;
    if (token.startsWith('</')) { if (stack.length > 1) stack.pop(); continue; }
    if (token.startsWith('<')) {
      const tag = token.match(/^<([a-z][\w-]*)/i)[1].toLowerCase();
      const element = new Element(tag);
      const attributes = token.slice(tag.length + 1, token.endsWith('/>') ? -2 : -1);
      for (const attribute of attributes.matchAll(/([\w-]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/g)) element.setAttribute(attribute[1], attribute[2] ?? attribute[3] ?? attribute[4] ?? '');
      stack.at(-1).append(element);
      if (!['meta', 'link', 'img', 'input', 'br', 'hr'].includes(tag) && !token.endsWith('/>')) stack.push(element);
    } else stack.at(-1)._text += token;
  }
}

export async function runFrontendTests(rootPath) {
  const siteCatalog = JSON.parse(await fs.readFile(`${rootPath}/sites.json`, 'utf8'));
  const document = new Element('document');
  parseHtml(await fs.readFile(`${rootPath}/index.html`, 'utf8'), document);
  document.body = document.querySelector('body');
  document.createElement = (tag) => new Element(tag);
  document.execCommand = () => true;
  const calls = [];
  const copied = [];
  const intervals = [];
  let historyGate = null;
  let jobsGate = null;
  let concurrency = 3;
  let failConcurrency = false;
  let recent = [];
  let failed = [];
  let jobs = [];
  let preview = { items: [{ kind: 'video', title: 'Video', url: 'https://example.test/video' }], totalVideos: 1 };
  let inspection = {
    mediaId: 'video1', autoSimplifyCandidate: true,
    audioTracks: [{ formatId: 'es', language: 'es', note: 'Track 1' }, { formatId: 'en10', language: 'en', note: 'Track 10' }, { formatId: 'en2', language: 'en', note: 'Track 2' }, { formatId: 'fr', language: 'fr', note: 'Track 1' }],
    subtitles: [{ rawKey: 'fr', language: 'fr', source: 'provided' }, { rawKey: 'en', language: 'en', source: 'auto' }, { rawKey: 'en', language: 'en', source: 'provided' }]
  };
  const storage = new Map();
  const fetch = async (path, options = {}) => {
    const body = options.body ? JSON.parse(options.body) : null;
    calls.push({ path, method: options.method || 'GET', body });
    let data = {};
    if (path === '/api/health') data = { ready: true };
    else if (path === '/api/settings') {
      if (body?.maxConcurrentDownloads != null) {
        if (failConcurrency) return { ok: false, status: 400, json: async () => ({ error: 'Could not save setting' }) };
        concurrency = body.maxConcurrentDownloads;
      }
      data = { defaultDownloadPath: 'C:\\Downloads', maxConcurrentDownloads: concurrency };
    }
    else if (path === '/api/cookies') data = { sites: {}, supportedSites: siteCatalog };
    else if (path === '/api/history') { if (historyGate) await historyGate; data = { recentLinks: recent, failedLinks: failed }; }
    else if (path === '/api/history/recent' && options.method === 'POST') { recent = body.urls.map((url) => ({ url })); data = { recentLinks: recent }; }
    else if (path === '/api/history/recent/delete') recent = recent.filter((entry) => entry.url !== body.url);
    else if (path === '/api/history/recent' && options.method === 'DELETE') recent = [];
    else if (path === '/api/history/failed/delete') failed = failed.filter((entry) => entry.id !== body.id);
    else if (path === '/api/history/failed/clear') failed = [];
    else if (/\/api\/history\/failed\/.+\/retry/.test(path)) { data = { job: { id: 'retryjob', status: 'queued' } }; jobs = [data.job]; }
    else if (path === '/api/preview') data = preview;
    else if (path === '/api/inspect') data = inspection;
    else if (path === '/api/jobs' && options.method === 'POST') { data = { defaultDownloadPath: body.path, job: { id: 'createdjob', status: 'queued', path: body.path } }; jobs = [data.job]; }
    else if (path === '/api/jobs/clear' || (/^\/api\/jobs\/[^/]+$/.test(path) && options.method === 'DELETE')) {
      const id = path === '/api/jobs/clear' ? null : decodeURIComponent(path.split('/').at(-1));
      const removedIds = jobs.filter((job) => ['completed', 'partial', 'failed', 'cancelled'].includes(job.status) && (!id || job.id === id)).map((job) => job.id);
      jobs = jobs.filter((job) => !removedIds.includes(job.id));
      const retainedActive = jobs.filter((job) => !['completed', 'partial', 'failed', 'cancelled'].includes(job.status)).map((job) => job.id);
      data = { jobs, removedIds, retainedActive, removedCount: removedIds.length, remainingCount: jobs.length };
    }
    else if (path === '/api/jobs') { data = JSON.parse(JSON.stringify({ jobs })); if (jobsGate) await jobsGate; }
    else if (/\/api\/jobs\/j1\/(pause|resume)/.test(path)) { jobs = [{ ...jobs[0], status: path.endsWith('/pause') ? 'paused' : 'queued' }]; data = { job: jobs[0] }; }
    else if (path === '/api/reveal-file') data = { opened: true };
    return { ok: true, status: 200, json: async () => JSON.parse(JSON.stringify(data)) };
  };
  const context = vm.createContext({ document, console, Intl, fetch, Event: class { constructor(type, options = {}) { this.type = type; Object.assign(this, options); } }, CustomEvent: class { constructor(type, options) { this.type = type; Object.assign(this, options); } }, navigator: { clipboard: { writeText: async (url) => copied.push(url) } }, localStorage: { getItem: (key) => storage.get(key), setItem: (key, value) => storage.set(key, value), removeItem: (key) => storage.delete(key) }, setInterval: (callback, ms) => { intervals.push({ callback, ms }); return 0; }, setTimeout: () => 0, clearTimeout: () => {}, window: { addEventListener: () => {}, dispatchEvent: () => {}, scrollTo: () => {} } });
  vm.runInContext(await fs.readFile(`${rootPath}/app.js`, 'utf8'), context);
  vm.runInContext(await fs.readFile(`${rootPath}/batch.js`, 'utf8'), context);
  const run = (code) => vm.runInContext(code, context);
  for (let i = 0; i < 30; i++) await Promise.resolve();
  assert.equal(run('batchState.online'), true);
  assert.equal(intervals.find((interval) => interval.callback.name === 'refreshRealJobs').ms, 500, 'live progress polls every half second');
  assert.equal(calls.some((call) => call.path === '/api/inspect'), false);

  document.querySelector('#batch-urls').value = 'https://example.test/video';
  await run('previewBatch()');
  assert.equal(calls.some((call) => call.path === '/api/inspect'), false, 'basic preview must not inspect tracks');
  let trigger = document.querySelector('.inspection-trigger');
  await trigger.dispatchEvent({ type: 'click' });
  assert.equal(calls.filter((call) => call.path === '/api/inspect').length, 1);
  const audioNames = document.querySelectorAll('.inspection-section')[0].querySelectorAll('strong').map((element) => element.textContent);
  assert.deepEqual(audioNames.map((name) => name.match(/格式 (.+)$/)[1]), ['en2', 'en10', 'fr', 'es'], 'English natural order must sort Track 2 before Track 10');
  assert.equal(run("batchState.sourceSelections.get('https://example.test/video').audioFormatIds.includes('fr')"), true, 'one-track/no-subtitle hint must not clear a valid preference');
  const en2 = document.querySelectorAll('.inspection-section')[0].querySelectorAll('input')[0];
  en2.checked = true;
  await en2.dispatchEvent({ type: 'change' });
  await trigger.dispatchEvent({ type: 'click' });
  assert.equal(calls.filter((call) => call.path === '/api/inspect').length, 2, 'reparse button must bypass cache');
  assert.equal(run("batchState.sourceSelections.get('https://example.test/video').audioFormatIds.includes('en2')"), true, 'refresh must retain exact selected format identity');
  run('renderBatchPreview()');
  trigger = document.querySelector('.inspection-trigger');
  await trigger.dispatchEvent({ type: 'click' });
  assert.equal(calls.filter((call) => call.path === '/api/inspect').length, 2, 'repeat display must use valid cache');

  const arteUrl = 'https://www.arte.tv/fr/videos/115508-001-A/le-monde-des-croyances/';
  const arteAudio = {
    mediaId: '115508-001-A', platform: 'ARTE', audioIdentityCount: 5, subtitles: [],
    audioTracks: [
      { formatId: 'VF-STF-audio_0-allemand', language: 'de', englishLanguageName: 'German', role: 'main', displayName: 'German', name: 'allemand', note: 'Français [VF]', audioOnly: true, bitrate: 128 },
      { formatId: 'VF-STF-audio_0-allemand__confort_audio_', language: 'de', englishLanguageName: 'German', role: 'description', displayName: 'German — Audio description', name: 'allemand (confort audio)', note: 'Français [VF]', audioOnly: true, bitrate: 256 },
      { formatId: 'VF-STF-audio_0-français__confort_audio_', language: 'fr', englishLanguageName: 'French', role: 'description', displayName: 'French — Audio description', name: 'français (confort audio)', note: 'Français [VF]', audioOnly: true, bitrate: 256 },
      { formatId: 'VF-STF-audio_0-multilingue', language: 'mul', englishLanguageName: 'Multilingual', role: 'main', displayName: 'Multilingual', name: 'multilingue', note: 'Français [VF]', audioOnly: true, bitrate: 128 },
      { formatId: 'VF-STF-audio_0-français', language: 'fr', englishLanguageName: 'French', role: 'main', displayName: 'French', name: 'français', note: 'Français [VF]', audioOnly: true, bitrate: 128 }
    ]
  };
  context.arteAudio = arteAudio;
  context.arteUrl = arteUrl;
  run("var arteContainer = document.createElement('div'); renderInspection(arteContainer, arteAudio, arteUrl)");
  const arteContainer = run('arteContainer');
  const arteSection = arteContainer.querySelectorAll('.inspection-section')[0];
  const arteNames = arteSection.querySelectorAll('strong').map((element) => element.textContent);
  assert.deepEqual(arteNames.map((name) => name.split(' (')[0]), ['French', 'French — Audio description', 'German', 'German — Audio description', 'Multilingual'], 'ARTE must display all five distinct audio identities in English language order');
  assert.equal(arteSection.querySelector('h3').textContent, '独立音轨（5）');
  assert.deepEqual(JSON.parse(run('JSON.stringify(batchState.sourceSelections.get(arteUrl).audioFormatIds)')), ['VF-STF-audio_0-français'], 'French defaults must choose the main track even when audio description has higher bitrate');
  assert.equal(arteSection.querySelectorAll('small').some((element) => element.textContent.includes('Français [VF]')), false, 'the video version note must not mislabel German or multilingual audio');
  assert.equal(run("englishLanguageName({language:'mul'})"), 'Multilingual');
  const germanPreference = document.querySelector('#batch-audio-box input[value="de"]');
  germanPreference.checked = true;
  await germanPreference.dispatchEvent({ type: 'change' });
  assert.deepEqual(JSON.parse(run('JSON.stringify(batchState.sourceSelections.get(arteUrl).audioFormatIds)')), ['VF-STF-audio_0-français', 'VF-STF-audio_0-allemand'], 'German defaults must also select the normal audio track');
  germanPreference.checked = false;
  await germanPreference.dispatchEvent({ type: 'change' });
  const arteInputs = arteContainer.querySelectorAll('.inspection-section')[0].querySelectorAll('input');
  arteInputs[1].checked = true;
  await arteInputs[1].dispatchEvent({ type: 'change' });
  arteInputs[4].checked = true;
  await arteInputs[4].dispatchEvent({ type: 'change' });
  const exactArteChoices = ['VF-STF-audio_0-français', 'VF-STF-audio_0-français__confort_audio_', 'VF-STF-audio_0-multilingue'];
  assert.deepEqual(JSON.parse(run('JSON.stringify(batchState.sourceSelections.get(arteUrl).audioFormatIds)')), exactArteChoices, 'manual description and multilingual selections must keep exact source format identities');
  run('renderInspection(arteContainer, arteAudio, arteUrl); refreshInspectedLanguageDefaults("audio")');
  assert.deepEqual(JSON.parse(run('JSON.stringify(batchState.sourceSelections.get(arteUrl).audioFormatIds)')), exactArteChoices, 'reparse and preference refresh must preserve manual audio choices');
  context.onlyDescription = [arteAudio.audioTracks[2]];
  assert.deepEqual(JSON.parse(run('JSON.stringify(chooseDefaultAudio(onlyDescription))')), ['VF-STF-audio_0-français__confort_audio_'], 'a sole available description track can still match a language preference');
  preview = { items: [{ kind: 'playlist', url: 'https://example.test/playlist', title: 'Playlist', entries: [{ id: 'entry1', title: 'Entry', url: 'https://example.test/entry1' }] }], totalVideos: 1 };
  document.querySelector('#batch-urls').value = 'https://example.test/playlist';
  await run('previewBatch()');
  assert.equal(calls.filter((call) => call.path === '/api/inspect').length, 2, 'playlist entries must remain uninspected');
  const choices = document.querySelectorAll('.video-choice input');
  assert.equal(choices.length, 1); assert.equal(choices[0].checked, true);
  const toolbar = document.querySelector('.video-choice-toolbar');
  assert.equal(toolbar.querySelectorAll('button').length, 1);
  const toggle = toolbar.querySelector('button');
  assert.equal(toggle.textContent, '取消全选');
  await toggle.dispatchEvent({type:'click'});
  assert.equal(toggle.textContent, '全选');
  assert.equal(document.querySelector('.video-choice input').checked, false);
  assert.equal(run('chosenPreviewSources().urls.length'), 0);
  await toggle.dispatchEvent({type:'click'});
  assert.equal(toggle.textContent, '取消全选');
  assert.equal(run('chosenPreviewSources().urls.length'), 1);
  run("batchState.preview.items[0].entries.push({id:'entry2',title:'Second',url:'https://example.test/entry2'}); renderBatchPreview()");
  const secondChoice = document.querySelectorAll('.video-choice input')[1]; secondChoice.checked=false; await secondChoice.dispatchEvent({type:'change'});
  assert.deepEqual(JSON.parse(run('JSON.stringify(chosenPreviewSources().selectedVideos)')), {'https://example.test/playlist':['entry1']});
  await document.querySelector('.inspection-trigger').dispatchEvent({ type: 'click' });
  document.querySelector('#batch-path').value = 'C:\\Recently used';
  await run('startBatch()');
  const submitted = calls.findLast((call) => call.path === '/api/jobs' && call.method === 'POST').body;
  assert.equal(submitted.autoSimplify, false);
  assert.equal(submitted.parts.audio, false);
  assert.equal(document.querySelector('#batch-path').value, submitted.path, 'the next job defaults to the folder just used');
  assert.deepEqual(submitted.audioOutputFormats, ['original']);
  const originalOption = document.querySelector('#batch-audio-formats input[value="original"]');
  const mp3Option = document.querySelector('#batch-audio-formats input[value="mp3"]');
  for (const formats of [[], ['mp3'], ['original', 'mp3']]) {
    document.querySelector('#batch-part-audio').checked = true;
    originalOption.checked = formats.includes('original'); mp3Option.checked = formats.includes('mp3');
    document.querySelector('#batch-urls').value = 'https://example.test/formats'; run('updateBatchInput()');
    document.querySelector('#batch-path').value = 'C:\\Downloads';
    const before = calls.filter((call) => call.path === '/api/jobs').length;
    await run('startBatch()');
    if (!formats.length) { assert.equal(calls.filter((call) => call.path === '/api/jobs').length, before); assert.ok(document.querySelector('#batch-start-error').textContent.includes('音频格式')); }
    else assert.deepEqual(calls.findLast((call) => call.path === '/api/jobs' && call.method === 'POST').body.audioOutputFormats, formats);
  }
  originalOption.checked = true; mp3Option.checked = false;
  const defaultAudio = document.querySelector('#default-part-audio');
  run("setPage('settings')");
  const settingsWrites = () => calls.filter((call) => call.path === '/api/settings' && call.method === 'POST').length;
  const beforeLeave = settingsWrites();
  defaultAudio.checked = true;
  await run("setPage('settings')");
  assert.equal(settingsWrites(), beforeLeave, 'staying on settings does not save');
  await run("setPage('batch')");
  assert.equal(settingsWrites(), beforeLeave + 1);
  assert.equal(calls.findLast((call) => call.path === '/api/settings' && call.method === 'POST').body.defaultDownloadParts.audio, true);
  assert.equal(document.querySelector('#batch-part-audio').checked, true);
  run("setPage('settings')");
  defaultAudio.checked = false;
  await run("setPage('batch')");
  run("setPage('settings')");
  await run("setPage('tasks')");
  assert.equal(settingsWrites(), beforeLeave + 2, 'leaving unchanged settings does not send a request');

  run("setPage('batch')");
  const rememberedPath = document.querySelector('#batch-path');
  const quality = document.querySelector('#batch-quality');
  const container = document.querySelector('#batch-container');
  const subtitleFormat = document.querySelector('#batch-subtitle-format input[value="docx"]');
  const englishAudio = document.querySelector('#batch-audio-box input[value="en"]');
  const englishSubtitles = document.querySelector('#batch-subtitle-box input[value="en"]');
  document.querySelector('#batch-part-audio').checked = true;
  quality.value = '720p'; container.value = 'mp4'; subtitleFormat.checked = true;
  englishAudio.checked = true; englishSubtitles.checked = true; mp3Option.checked = true;
  rememberedPath.value = 'D:\\Remembered';
  run("setPage('tasks')");
  quality.value = '1080p'; container.value = 'mkv'; subtitleFormat.checked = false;
  englishAudio.checked = false; englishSubtitles.checked = false; mp3Option.checked = false;
  document.querySelector('#batch-part-audio').checked = false;
  rememberedPath.value = '';
  run('restoreDownloadOptions()');
  assert.equal(document.querySelector('#batch-part-audio').checked, true);
  assert.equal(quality.value, '720p'); assert.equal(container.value, 'mp4'); assert.equal(subtitleFormat.checked, true);
  assert.ok(englishAudio.checked && englishSubtitles.checked && mp3Option.checked);
  assert.equal(rememberedPath.value, 'D:\\Remembered');
  quality.value = '1080p'; container.value = 'mkv'; subtitleFormat.checked = false;
  englishAudio.checked = false; englishSubtitles.checked = false; mp3Option.checked = false;
  document.querySelector('#batch-part-audio').checked = false;

  assert.equal(document.querySelector('#batch-part-audio').checked, false);

  assert.ok(submitted.sourceSelections['https://example.test/entry1'], 'playlist entry selections must reach the backend');

  for (const part of ['audio', 'subtitles']) {
    for (const name of ['video', 'audio', 'subtitles']) document.querySelector(`#batch-part-${name}`).checked = name === part;
    document.querySelector('#batch-urls').value = `https://www.bilibili.com/video/BV1sample?part=${part}`;
    run('updateBatchInput()');
    document.querySelector('#batch-path').value = 'C:\\Downloads';
    await run('startBatch()');
    const singlePart = calls.findLast((call) => call.path === '/api/jobs' && call.method === 'POST').body;
    assert.deepEqual(singlePart.parts, { video: false, audio: part === 'audio', subtitles: part === 'subtitles' }, 'unchecked video must stay unchecked without requiring track inspection');
  }
  for (const name of ['video', 'audio', 'subtitles']) document.querySelector(`#batch-part-${name}`).checked = true;

  const limit = document.querySelector('#task-concurrency');
  assert.equal(limit.value, '3', 'default parallel task count loads from the server');
  limit.value = '5';
  await limit.dispatchEvent({ type: 'change' });
  assert.equal(limit.value, '5');
  assert.deepEqual(calls.findLast((call) => call.path === '/api/settings' && call.method === 'POST').body, { maxConcurrentDownloads: 5 });
  assert.equal(run('batchState.maxConcurrentDownloads'), 5);
  failConcurrency = true;
  limit.value = '2';
  await limit.dispatchEvent({ type: 'change' });
  assert.equal(limit.value, '5', 'failed setting changes restore the last saved parallel count');
  failConcurrency = false;

  const progressSnapshot = (fraction) => [{ id: 'j1', status: 'running', createdAt: '2026-10-03 00:00:00', path: 'C:\\Downloads', total: 1, completed: 0, failed: 0, skipped: 0, phase: 'download', progress: fraction, currentAsset: 'video', currentTitle: 'Progress sample', downloadedBytes: Math.round(8388608 * fraction), totalBytes: 8388608, speedBytesPerSecond: 2097152, etaSeconds: Math.ceil((1 - fraction) * 4), items: [{ title: 'Progress sample', url: 'https://www.youtube.com/watch?v=sample', status: 'running', currentAsset: 'video', phase: 'download', progress: fraction, downloadedBytes: Math.round(8388608 * fraction), totalBytes: 8388608, speedBytesPerSecond: 2097152, assets: [{ type: 'video', status: 'running', phase: 'download', progress: fraction, downloadedBytes: Math.round(8388608 * fraction), totalBytes: 8388608, speedBytesPerSecond: 2097152 }] }] }];
  let liveCard;
  for (const fraction of [0.0025, 0.25, 0.5, 0.75]) {
    jobs = progressSnapshot(fraction);
    await run('refreshRealJobs()');
    const latestCard = document.querySelector('.real-task');
    if (liveCard) assert.equal(latestCard, liveCard, 'polling must update the same task card');
    liveCard = latestCard;
    const details = liveCard.querySelector('.job-items');
    if (!details.open) { details.open = true; await details.dispatchEvent({ type: 'toggle' }); }
    const expectedPercent = Math.round(fraction * 1000) / 10;
    assert.equal(liveCard.querySelector('.progress-track').hidden, false);
    assert.equal(Number(liveCard.querySelector('.progress-track').value), fraction * 100);
    assert.ok(liveCard.querySelector('.job-transfer').textContent.includes(`进度 ${expectedPercent}%`), 'each JSON snapshot must update textual percentage');
    assert.equal(liveCard.querySelector('.progress-track').attributes['aria-label'], `当前文件下载进度 ${expectedPercent}%`);
    assert.ok(liveCard.querySelector('.job-item-transfer').textContent.includes(`进度 ${expectedPercent}%`), 'expanded video details must update between polls');
    assert.ok(liveCard.querySelector('.job-asset').querySelector('.job-item-transfer').textContent.includes(`进度 ${expectedPercent}%`), 'expanded resource metrics must update between polls');
    assert.ok(liveCard.querySelector('.job-transfer').textContent.includes('速度 2.0 MB/s'));
  }
  let releaseHistory;
  historyGate = new Promise((resolve) => { releaseHistory = resolve; });
  run("batchState.historyJobSnapshot = 'force-history-refresh'");
  jobs = progressSnapshot(0.25);
  await Promise.race([run('refreshRealJobs()'), new Promise((_, reject) => setTimeout(() => reject(new Error('History request blocked progress polling')), 1000))]);
  assert.equal(run('batchState.jobsPending'), false, 'history I/O must release the jobs polling lock');
  assert.equal(run('batchState.historyPending'), true);
  jobs = progressSnapshot(0.5);
  await run('refreshRealJobs()');
  assert.equal(Number(document.querySelector('.real-task').querySelector('.progress-track').value), 50, 'next intermediate snapshot must render while history is pending');
  releaseHistory();
  historyGate = null;
  for (let i = 0; i < 15; i++) await Promise.resolve();
  jobs = [{ ...progressSnapshot(0.75)[0], phase: 'merge' }];
  await run('refreshRealJobs()');
  assert.equal(document.querySelector('.real-task').querySelector('.progress-track').hidden, true, 'processing must hide stale transfer gauge');
  assert.equal(document.querySelector('.real-task').querySelector('.job-transfer').textContent, '当前阶段：合并');
  jobs = [{ id: 'j1', status: 'waiting_network', path: 'C:\\Downloads', progress: 0.42, downloadedBytes: 4200, currentAsset: 'video', items: [] }];
  await run('refreshRealJobs()');
  const mergeTransfer = run("transferLabel({status:'running',currentAsset:'video',phase:'merge',progress:1,speedBytesPerSecond:1024})");
  assert.equal(mergeTransfer, '当前阶段：合并', 'merge phase must hide stale download speed and percentage');
  const convertTransfer = run("transferLabel({status:'pausing',currentAsset:'audio',phase:'convert',progress:1,speedBytesPerSecond:1024})");
  assert.equal(convertTransfer, '当前阶段：转换', 'safe pause during conversion must display the processing phase');
  let card = document.querySelector('.real-task');
  assert.equal(card.querySelector('.task-status').textContent, '等待网络恢复');
  assert.equal(card.querySelector('.job-pause').hidden, false);
  assert.equal(Number(card.querySelector('.progress-track').value), 42);
  await card.querySelector('.job-pause').dispatchEvent({ type: 'click' });
  card = document.querySelector('.real-task');
  assert.equal(card.querySelector('.job-resume').hidden, false);
  assert.equal(card.querySelector('.job-pause').hidden, true);
  await card.querySelector('.job-resume').dispatchEvent({ type: 'click' });
  assert.equal(calls.filter((call) => call.path === '/api/jobs/j1/resume').length, 1);
  jobs = [{ id: 'j1', status: 'completed', items: [{ title: 'Finished', status: 'completed', assets: [{ type: 'video', status: 'completed', path: 'C:\\Downloads\\Finished.mp4' }, { type: 'audio', status: 'completed', path: 'C:\\Downloads\\Finished.m4a' }] }] }];
  await run('refreshRealJobs()');
  const folder = document.querySelector('.folder-open-button');
  assert.ok(folder);
  await folder.dispatchEvent({ type: 'click' });
  assert.deepEqual(calls.findLast((call) => call.path === '/api/reveal-file').body, { jobId: 'j1', path: 'C:\\Downloads\\Finished.mp4' });
  const finishedCard = document.querySelector('.real-task');
  await run('refreshRealJobs()');
  assert.equal(document.querySelector('.real-task').querySelector('.folder-open-button'), folder, 'same completed snapshot preserves the correct folder button');
  jobs = [{ ...jobs[0], items: [{ ...jobs[0].items[0], assets: [{ type: 'video', status: 'completed', path: 'C:\\新目录\\已改名 高清.mp4' }] }] }, { id: 'j2', status: 'completed', items: [{ title: 'Other job', status: 'completed', assets: [{ type: 'video', status: 'completed', path: 'C:\\Downloads\\Finished.mp4' }] }] }];
  await run('refreshRealJobs()');
  assert.equal(document.querySelector('.real-task'), finishedCard);
  const renamedFolder = finishedCard.querySelector('.folder-open-button');
  assert.notEqual(renamedFolder, folder, 'changed final path rebuilds the button');
  assert.equal(renamedFolder.dataset.jobId, 'j1');
  assert.equal(renamedFolder.dataset.path, 'C:\\新目录\\已改名 高清.mp4');
  await renamedFolder.dispatchEvent({ type: 'click' });
  assert.deepEqual(calls.findLast((call) => call.path === '/api/reveal-file').body, { jobId: 'j1', path: 'C:\\新目录\\已改名 高清.mp4' });
  const otherFolder = document.querySelectorAll('.real-task')[1].querySelector('.folder-open-button');
  await otherFolder.dispatchEvent({ type: 'click' });
  assert.deepEqual(calls.findLast((call) => call.path === '/api/reveal-file').body, { jobId: 'j2', path: 'C:\\Downloads\\Finished.mp4' }, 'different job with an old same-named path must send its own ID');

  await finishedCard.querySelector('.job-delete').dispatchEvent({ type: 'click' });
  for (let i = 0; i < 15; i++) await Promise.resolve();
  assert.deepEqual(jobs.map((job) => job.id), ['j2'], 'single deletion removes only the selected task');
  assert.equal(run("batchState.taskCards.has('j1')"), false, 'deletion removes the matching card cache');
  assert.equal(document.querySelectorAll('.real-task').length, 1);
  assert.equal(calls.findLast((call) => call.path === '/api/jobs/j1').method, 'DELETE');
  assert.equal(calls.filter((call) => /delete.*file|file.*delete/.test(call.path)).length, 0, 'clearing task records never sends a media deletion request');

  jobs = [{ id: 'running', status: 'running', progress: 0.3, currentAsset: 'video', items: [] }, { id: 'paused', status: 'paused', items: [] }, { id: 'done', status: 'completed', items: [] }, { id: 'cancelled', status: 'cancelled', items: [] }, { id: 'failed', status: 'failed', items: [] }];
  await run('refreshRealJobs()');
  assert.equal(document.querySelectorAll('.real-task')[0].querySelector('.job-delete').disabled, true);
  assert.equal(document.querySelectorAll('.real-task')[1].querySelector('.job-delete').disabled, true, 'paused tasks retain resumable data until cancelled');
  const callsBeforeBlockedDelete = calls.length;
  await run("clearJobRecords('running')");
  assert.equal(calls.length, callsBeforeBlockedDelete, 'active jobs cannot be cleared through a direct UI action');

  let releaseJobs;
  jobsGate = new Promise((resolve) => { releaseJobs = resolve; });
  const oldPoll = run('refreshRealJobs()');
  await document.querySelector('#clear-task-records').dispatchEvent({ type: 'click' });
  assert.deepEqual(jobs.map((job) => job.id), ['running', 'paused']);
  assert.ok(document.querySelector('#toast').textContent.includes('保留 2 个未结束任务'));
  releaseJobs();
  jobsGate = null;
  await oldPoll;
  assert.deepEqual(Array.from(run('batchState.lastJobs'), (job) => job.id), ['running', 'paused'], 'in-flight old polling response cannot resurrect cleared task cards');
  assert.equal(document.querySelectorAll('.real-task').length, 2);
  assert.equal(Number(document.querySelector('.real-task').querySelector('.progress-track').value), 30, 'retained active download still exposes progress');
  assert.equal(document.querySelector('#clear-task-records').disabled, true, 'only active tasks means no records eligible for clearing');
  jobs = [];
  await run('refreshRealJobs()');
  assert.equal(document.querySelectorAll('.real-task').length, 0);
  assert.equal(run('batchState.taskCards.size'), 0);
  assert.ok(document.querySelector('.empty-state'));

  const playlistItems = Array.from({ length: 80 }, (_, index) => ({ title: `Episode ${index + 1}`, status: 'running', currentAsset: 'video', progress: 0.2, assets: [] }));
  jobs = [{ id: 'long-playlist', status: 'running', progress: 0.2, total: 80, items: playlistItems }];
  await run('refreshRealJobs()');
  const playlistCard = document.querySelector('.real-task');
  const playlistDetails = playlistCard.querySelector('.job-items');
  playlistDetails.open = true;
  await playlistDetails.dispatchEvent({ type: 'toggle' });
  const playlistList = playlistCard.querySelector('.job-item-list');
  assert.equal(playlistList.children.length, 80, 'every playlist item remains reachable in the list');
  playlistList.scrollTop = 180;
  jobs[0].items[25].progress = 0.7;
  await run('refreshRealJobs()');
  assert.equal(playlistList.scrollTop, 180, 'live polling preserves the user scroll position');
  assert.equal(playlistList.parentElement, playlistDetails, 'only item details scroll, the task progress remains outside');
  const css = await fs.readFile(`${rootPath}/styles.css`, 'utf8');
  for (const className of ['batch-entry-list', 'job-item-list', 'job-completed-files']) {
    const rule = css.match(new RegExp(`\\.${className}\\{([^}]+)`))[1];
    assert.match(rule, /max-height:/);
    assert.match(rule, /overflow-y:auto/);
  }
  jobs = [{ id: 'no-subtitle', status: 'completed', completed: 0, skipped: 1, failed: 0, total: 1, message: '没有可下载的所选字幕，已跳过', items: [{ title: 'No subtitles', status: 'skipped', message: '该视频没有所选字幕', assets: [] }] }];
  await run('refreshRealJobs()');
  const skippedCard = document.querySelector('.real-task');
  assert.equal(skippedCard.querySelector('.task-status').textContent, '已跳过');
  assert.equal(skippedCard.querySelector('.progress-track').hidden, true);
  const skippedDetails = skippedCard.querySelector('.job-items');
  skippedDetails.open = true;
  await skippedDetails.dispatchEvent({ type: 'toggle' });
  assert.ok(skippedCard.querySelector('.job-item-list').textContent.includes('该视频没有所选字幕'));
  for (let i = 0; i < 30; i++) await Promise.resolve();

  recent = [{ url: 'https://example.test/history', title: 'History' }];
  failed = [{ id: 'f1', url: 'https://example.test/failed', title: 'Failed', status: 'unresolved', failureCount: 2, error: 'Disk full', failedResources: [{ type: 'subtitle', language: 'fr' }] }, { id: 'f2', url: 'https://example.test/resolved', status: 'resolved' }];
  await run('refreshLinkHistory()');
  assert.equal(document.querySelector('#failed-link-list').children.length, 1, 'default filter must hide resolved failures');
  const failedRow = document.querySelector('#failed-link-list').children[0];
  await failedRow.querySelectorAll('button')[0].dispatchEvent({ type: 'click' });
  assert.equal(copied.at(-1), 'https://example.test/failed');
  await failedRow.querySelectorAll('button')[1].dispatchEvent({ type: 'click' });
  assert.equal(document.querySelector('#batch-urls').value, 'https://example.test/failed');
  run("fillHistoryLink('https://example.test/failed')");
  assert.equal(document.querySelector('#batch-urls').value, 'https://example.test/failed', 'history fill must avoid duplicate URLs');
  await failedRow.querySelectorAll('button')[2].dispatchEvent({ type: 'click' });
  assert.equal(calls.filter((call) => call.path === '/api/history/failed/f1/retry').length, 1);
  document.querySelector('#failed-unresolved-only').checked = false;
  run('renderLinkHistory()');
  assert.equal(document.querySelector('#failed-link-list').children.length, 2);
  await document.querySelector('#history-recent-link-list').children[0].querySelectorAll('button')[2].dispatchEvent({ type: 'click' });
  assert.equal(recent.length, 0);
  assert.equal(document.querySelector('#batch-container-field').querySelector('span').textContent, '视频格式');
  run("var loginContainer = document.createElement('div'); document.body.append(loginContainer); renderInspection(loginContainer, { mediaId: 'bili-login', audioIdentityCount: 1, audioTracks: [{formatId: '30280',language:'zh'}], subtitles: [], subtitleAvailability: 'login-required', subtitleNotice: 'Bilibili 字幕需要登录，请在设置中导入 Cookie 后重新解析。' }, 'https://www.bilibili.com/video/BVlogin')");
  assert.equal(document.querySelector('.inspection-subtitle-notice').textContent, 'Bilibili 字幕需要登录，请在设置中导入 Cookie 后重新解析。');
  assert.equal(run("loginContainer.querySelectorAll('.inspection-section')[1].querySelector('h3').textContent"), '外部字幕（需登录）');
  assert.equal(run("/没有外部字幕|没有可下载的外部字幕/.test(loginContainer.textContent)"), false, 'authentication failures must not claim the video has no subtitles');
  run("renderInspection(loginContainer, { mediaId:'bili-real-login',audioIdentityCount:1,audioTracks:[{formatId:'30280',language:'zh'}],subtitles:[],subtitleAvailability:'needs-login' }, 'https://www.bilibili.com/video/BVrealLogin')");
  assert.equal(run("loginContainer.querySelectorAll('.inspection-section')[1].querySelector('h3').textContent"), '外部字幕（需登录）');
  assert.ok(document.querySelector('.inspection-subtitle-notice').textContent.includes('导入 Bilibili Cookie'));
  assert.equal(run("/没有外部字幕|没有可下载的外部字幕/.test(loginContainer.textContent)"), false, 'the real needs-login backend status must retain the authentication notice');
  run("renderInspection(loginContainer, { mediaId:'bili-failed',audioTracks:[],subtitles:[],subtitleAvailability:'failed' }, 'https://www.bilibili.com/video/BVfailed')");
  assert.equal(run("loginContainer.querySelectorAll('.inspection-section')[1].querySelector('h3').textContent"), '外部字幕（解析未完成）');
  assert.ok(document.querySelector('.inspection-subtitle-notice').textContent.includes('字幕解析未完成'));
  assert.ok(run("document.querySelector('#supported-site-list').textContent").includes('Vimeo'));
  assert.ok(run("document.querySelector('#cookie-sites').textContent").includes('小红书'));
  assert.equal(run('Object.keys(COOKIE_SITES).length'),siteCatalog.length);
  assert.equal(run('COOKIE_SITES.tiktok'),'TikTok');
  run("applySupportedSites([{id:'../bad',label:'bad'}])");
  assert.equal(run('Object.keys(COOKIE_SITES).length'),siteCatalog.length, 'invalid site metadata cannot replace the valid catalogue');

  assert.deepEqual(JSON.parse(run(`JSON.stringify(completedFilePaths({assets:[
    {type:'video',status:'completed',path:'C:/Downloads/clip.mp4'},
    {type:'audio',status:'completed',path:'C:/Downloads/clip.mp3'},
    {type:'subtitle',status:'completed',path:'C:/Downloads/clip.docx'},
    {type:'subtitle',status:'failed',path:'C:/Downloads/clip.vtt'}
  ]}))`)), ['C:/Downloads/clip.mp4', 'C:/Downloads/clip.mp3', 'C:/Downloads/clip.docx']);
  const radioDisplay = run(`(() => {
    batchState.preview = {totalVideos:2,items:[{url:'https://www.radiofrance.fr/franceculture/podcasts/example',title:'Radio série',platform:'Radio France',kind:'playlist',mediaType:'audio',count:2,entries:[]}]};
    renderBatchPreview();
    const card=createTaskCard('radio-complete');
    updateTaskCard(card,{id:'radio-complete',status:'completed',items:[{title:'Épisode 1',status:'completed',assets:[{type:'audio',status:'completed',path:'C:/Downloads/Radio/Épisode 1.mp3'}]}]});
    return {preview:document.querySelector('#batch-preview-list').textContent,folders:card.querySelectorAll('.folder-open-button').length,title:card.querySelector('.task-title').textContent};
  })()`);
  assert.ok(radioDisplay.preview.includes('Radio France') && radioDisplay.preview.includes('自动按音频下载'));
  assert.ok(!radioDisplay.preview.includes('个视频'));
  assert.equal(radioDisplay.folders,1);
  assert.ok(radioDisplay.title.includes('音轨下载'));

  const audioDisplay = run(`(() => {
    const card = createTaskCard('audio-display');
    updateTaskCard(card, {id:'audio-display', status:'running', currentAsset:'audio', phase:'download', progress:0.3,
      items:[{title:'Audio sample', status:'running', currentAsset:'audio', assets:[{type:'audio',status:'running'}]}]});
    return {title:card.querySelector('.task-title').textContent, transfer:card.querySelector('.job-transfer').textContent};
  })()`);
  assert.ok(audioDisplay.title.includes('音轨下载') && !audioDisplay.title.includes('视频'));
  assert.ok(audioDisplay.transfer.includes('独立音轨') && !audioDisplay.transfer.includes('视频'));
  assert.equal(run("jobDownloadLabel({mode:'audio',items:[]})"), '音轨下载');
  assert.equal(run("jobDownloadLabel({parts:{subtitles:true},items:[]})"), '字幕下载');
  assert.equal(run("jobDownloadLabel({parts:{video:true,audio:true,subtitles:true},items:[]})"), '视频、音轨、字幕下载');
  assert.equal(run("jobDownloadLabel({items:[]})"), '资源下载');
  assert.ok(!run("transferLabel({status:'running',currentAsset:'processing',phase:'processing',progress:1})").includes('进度未知'));
  const pageHtml = await fs.readFile(`${rootPath}/index.html`, 'utf8');
  assert.ok(pageHtml.includes('<title>LingoSave · 媒体下载</title>'));

  return { passed: true, scenarios: ['original audio default, MP3 and dual selections, empty selection validation', 'dynamic multi-site support list and credential controls', 'Radio France series preview and audio file reveal', 'audio task type and neutral window title', 'manual inspection', 'English natural sorting', 'ARTE five audio identities and main-track defaults', 'ARTE manual description and multilingual format selections', 'stable track choices', 'cache and refresh', 'playlist entry payload', 'audio-only and subtitle-only submissions without inspection', 'parallel task setting and failed save rollback', 'sequential fractional progress JSON snapshots', 'history I/O does not block progress', 'pause/resume and network state', 'completed video folder identity after polling and rename', 'single and bulk task record clearing retains active tasks', 'stale polling response cannot restore removed tasks', 'scrollable playlist details preserve position during polling', 'unavailable selected resources display skipped reasons', 'recent and failed history controls', 'Bilibili subtitles require login or retry notices'] };
}

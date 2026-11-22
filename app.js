const SETTINGS_KEY = 'lingosave-settings-v1';
const LEGACY_KEY = 'lingosave-demo-v1';
const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];

function loadDefaultPath() {
  try {
    const current = JSON.parse(localStorage.getItem(SETTINGS_KEY) || '{}');
    if (typeof current.defaultPath === 'string') return current.defaultPath;
    const legacy = JSON.parse(localStorage.getItem(LEGACY_KEY) || '{}');
    return typeof legacy.defaultPath === 'string' ? legacy.defaultPath : '';
  } catch { return ''; }
}

let toastTimer;
let savedDefaultPath = loadDefaultPath();
let settingsDirty = false;
window.lingoGetDefaultPath = () => savedDefaultPath;
window.lingoApplyServerDefaultPath = (path) => {
  if (!isAbsolutePath(path)) return;
  savedDefaultPath = path;
  if (!settingsDirty) $('#default-path-input').value = path;
  window.dispatchEvent(new CustomEvent('lingosave:default-path-changed', { detail: { path } }));
};
function showToast(message) {
  const toast = $('#toast');
  toast.textContent = message;
  toast.classList.add('is-visible');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toast.classList.remove('is-visible'), 4000);
}

let currentPage;
function setPage(page) {
  const leavingSettings = currentPage === 'settings' && page !== 'settings';
  if (currentPage === 'batch' && page !== 'batch') window.lingoRememberDownloadOptions?.();
  currentPage = page;
  $$('.page').forEach((element) => {
    const active = element.id === `page-${page}`;
    element.classList.toggle('is-visible', active);
    element.setAttribute('aria-hidden', String(!active));
  });
  $$('[data-page]').forEach((button) => {
    const active = button.dataset.page === page;
    button.classList.toggle('is-active', active);
    if (active) button.setAttribute('aria-current', 'page');
    else button.removeAttribute('aria-current');
  });
  window.scrollTo({ top: 0, behavior: 'smooth' });
  if (leavingSettings) return window.lingoSaveDefaultParts?.();
}

function isAbsolutePath(path) { return /^[A-Za-z]:[\\/]/.test(path); }

$$('[data-page]').forEach((button) => button.addEventListener('click', () => setPage(button.dataset.page)));
$('#default-path-input').value = savedDefaultPath;
$('#default-path-input').addEventListener('input', () => {
  settingsDirty = true;
  $('#settings-saved').textContent = '';
  $('#settings-saved').classList.remove('is-error');
});
$('#save-settings-button').addEventListener('click', async () => {
  const path = $('#default-path-input').value.trim();
  const result = $('#settings-saved');
  if (!isAbsolutePath(path)) {
    result.textContent = '请输入 Windows 绝对路径，或点击“选择文件夹”。';
    result.classList.add('is-error');
    return;
  }
  if (typeof window.lingoSaveSettings !== 'function' || !window.lingoServiceReady()) {
    result.textContent = '本机服务未连接，启动服务后再保存默认目录。';
    result.classList.add('is-error');
    return;
  }
  const button = $('#save-settings-button');
  button.disabled = true;
  button.textContent = '正在保存…';
  try {
    const data = await window.lingoSaveSettings(path);
    savedDefaultPath = data.defaultDownloadPath || path;
    settingsDirty = false;
    $('#default-path-input').value = savedDefaultPath;
    try { localStorage.setItem(SETTINGS_KEY, JSON.stringify({ defaultPath: savedDefaultPath })); } catch { /* server remains source of truth */ }
    result.classList.remove('is-error');
    result.textContent = '默认目录已保存，后续新任务将使用此目录。';
    window.dispatchEvent(new CustomEvent('lingosave:default-path-changed', { detail: { path: savedDefaultPath } }));
    showToast('默认目录已保存');
  } catch (error) {
    result.textContent = error.message;
    result.classList.add('is-error');
  } finally {
    button.disabled = false;
    button.textContent = '保存默认目录';
  }
});

setPage('batch');

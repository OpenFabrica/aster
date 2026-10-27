// Hello Web 示例：演示 window.aster 的 onEnter、storage、clipboard.writeText、setHeight 与外观适配。
// 页面跑在沙箱 WebView 里：只能用插件目录里的文件，不能联网，也不能用 eval 或内联脚本。
(function () {
  'use strict';

  // window.aster 由 Aster 注入；直接用浏览器打开时不存在，页面要能正常降级。
  const aster = window.aster;
  const byId = (id) => document.getElementById(id);
  const SMALL_HEIGHT = 320;
  const LARGE_HEIGHT = 460;
  let lastInput = '';
  let expanded = false;

  // 在页面底部显示一句状态。
  function say(text) {
    byId('status').textContent = text;
  }

  // 调用失败时 Promise 拒绝为 AsterError，code 能区分原因（例如 permission_denied、rate_limited）。
  function fail(error) {
    say('失败：' + (error && error.code ? error.code + ' · ' : '') + ((error && error.message) || error));
  }

  // 进入工具：input.text 是带进来的文字（粘贴、终端选区或剪贴板），context 里有界面语言与外观。
  function onEnter(event) {
    const input = event.input || {};
    lastInput = input.text || '';
    byId('input').textContent = lastInput || '（空）';
    byId('source').textContent = input.source || '—';
    byId('locale').textContent = (event.context && event.context.locale) || '—';
  }

  // 打开次数存在插件私有存储里：每个插件 ≤ 5 MiB，值可以是任意 JSON，不需要声明权限。
  async function countVisit() {
    const visits = ((await aster.storage.get('visits')) || 0) + 1;
    await aster.storage.set('visits', visits);
    byId('visits').textContent = String(visits);
  }

  // 便签：启动时读出，停止输入 400 ms 后保存。
  async function setUpNote() {
    const note = byId('note');
    note.value = (await aster.storage.get('note')) || '';
    let timer = 0;
    note.addEventListener('input', () => {
      clearTimeout(timer);
      timer = setTimeout(() => aster.storage.set('note', note.value).catch(fail), 400);
    });
  }

  if (!aster) {
    say('不在 Aster 里，依赖 App 的功能不可用。');
    byId('copy').disabled = true;
    byId('grow').disabled = true;
    byId('note').disabled = true;
    return;
  }

  // 已经进入过时，onEnter 会立即用最近一次的事件调用回调。
  aster.onEnter(onEnter);
  // 外观变化时 Aster 已经设好 data-aster-appearance，样式自己会切换；这里只演示回调。
  aster.onThemeChange((theme) => say('外观切换为 ' + theme.appearance));
  countVisit().catch(fail);
  setUpNote().catch(fail);

  // 写剪贴板需要在清单里声明 clipboard.write，否则拒绝为 permission_denied。
  byId('copy').addEventListener('click', () => {
    aster.clipboard.writeText(lastInput || 'Hello from Aster').then(() => say('已复制'), fail);
  });

  // 调整工具区域的高度（120–800）。
  byId('grow').addEventListener('click', () => {
    expanded = !expanded;
    aster.setHeight(expanded ? LARGE_HEIGHT : SMALL_HEIGHT).then(() => {
      byId('grow').textContent = expanded ? '收起' : '展开';
    }, fail);
  });
})();

// 正则 Worker：在后台线程里跑匹配。页面超时后直接 terminate 这个线程，灾难性回溯不会卡住界面。
importScripts('regex-core.js');

// 收到 {id, pattern, flags, text, limit}，回 {id, ok, result} 或 {id, ok: false, error}。
self.onmessage = function (event) {
  const job = event.data || {};
  try {
    const result = self.RegexCore.run(job.pattern, job.flags, job.text, job.limit);
    self.postMessage({ id: job.id, ok: true, result });
  } catch (error) {
    self.postMessage({ id: job.id, ok: false, error: String((error && error.message) || error) });
  }
};

// 告诉页面 Worker 已经能用；页面据此区分「Worker 加载失败」和「某次匹配出错」。
self.postMessage({ type: 'ready' });

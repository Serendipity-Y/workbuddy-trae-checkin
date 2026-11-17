import http from 'node:http';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

export const VERSION = '2026-11-17.3';
const ROOT = path.dirname(fileURLToPath(import.meta.url));

export function createHelper({ run = () => spawn('cmd.exe', ['/d', '/c', 'run-checkin.cmd'], {
  cwd: ROOT, windowsHide: true, stdio: 'ignore',
}), timeoutMs = 210000, kill = child => {
  // Only terminate the process tree started by this request.
  if (child.exitCode == null && child.pid) {
    const killer = spawn('taskkill.exe', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore' });
    killer.on('error', () => {});
  }
} } = {}) {
  let running = false;
  return http.createServer((req, res) => {
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'POST,GET,OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'content-type');
    res.setHeader('Cache-Control', 'no-store');
    const reply = (status, body) => {
      if (res.writableEnded || res.destroyed) return;
      res.writeHead(status, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(body));
    };
    const url = new URL(req.url, 'http://localhost');
    if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }
    if (req.method === 'GET' && url.pathname === '/health') {
      reply(200, { ok: true, version: VERSION, running }); return;
    }
    if (req.method !== 'POST' || url.pathname !== '/refresh') {
      reply(404, { ok: false, error: 'not found' }); return;
    }
    if (running) { reply(409, { ok: false, error: 'AgentRouter 刷新正在运行，请稍后读取余额' }); return; }
    running = true;
    let child;
    try { child = run(); }
    catch { running = false; reply(502, { ok: false, error: '无法启动 AgentRouter 任务，请检查本机日志' }); return; }
    let timedOut = false, settled = false;
    const timer = setTimeout(() => {
      timedOut = true;
      kill(child);
      reply(504, { ok: false, error: 'AgentRouter 任务超时，请先查看任务状态和余额，不要立即重复执行' });
      // Keep running=true until the child really exits.
    }, timeoutMs);
    child.once('error', () => {
      if (settled) return; settled = true;
      clearTimeout(timer); running = false;
      reply(502, { ok: false, error: '无法启动 AgentRouter 任务，请检查本机日志' });
    });
    child.once('close', code => {
      if (settled) return; settled = true;
      clearTimeout(timer); running = false;
      if (timedOut) return;
      if (code === 0) reply(200, { ok: true });
      else if (code === 75) reply(409, { ok: false, error: 'AgentRouter 定时任务正在运行，请稍后读取余额' });
      else reply(502, { ok: false, error: 'AgentRouter 登录、余额查询或推送失败，请查看本机 checkin.log 和 console.log' });
    });
  });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const server = createHelper();
  server.on('error', error => { console.error('helper error:', error.code || 'unknown'); process.exit(1); });
  server.listen(8788, '0.0.0.0', () => console.log('agentrouter refresh helper ' + VERSION + ' on :8788'));
}

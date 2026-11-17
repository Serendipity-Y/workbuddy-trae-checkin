# Credential-free equivalent of the diagnosed installed script, for regression tests only.
"""AgentRouter daily check-in via login.

AgentRouter has no standalone check-in endpoint; the $25 daily reward is granted
on the first successful POST /api/user/login of the day (response field checked_in).
This script logs in, then reads /api/user/self to report the balance. No browser,
no CloakBrowser license. Requires CHECKIN_PROXY_URL (agentrouter.org is SNI-blocked in CN).
"""

from __future__ import annotations

import datetime
import os
import sys
import time

import httpx

BASE = 'https://agentrouter.org'
HERE = os.path.dirname(os.path.abspath(__file__))
ENV_PATH = os.path.join(HERE, '.env')
LOG_PATH = os.path.join(HERE, 'checkin.log')
QUOTA_UNIT = 500000  # NewAPI: 500000 quota == $1
ATTEMPTS = 3


def load_env(path: str) -> dict[str, str]:
	env: dict[str, str] = {}
	with open(path, encoding='utf-8', errors='replace') as fh:
		for line in fh:
			line = line.strip()
			if not line or line.startswith('#') or '=' not in line:
				continue
			key, val = line.split('=', 1)
			env[key.strip()] = val.strip()
	return env


def run_once(user: str, pwd: str, api_user: str, proxy: str | None) -> bool:
	headers = {'New-Api-User': api_user} if api_user else {}
	with httpx.Client(proxy=proxy, trust_env=False, timeout=40.0) as c:
		r = c.post(BASE + '/api/user/login', json={'username': user, 'password': pwd})
		try:
			j = r.json()
		except Exception:
			j = {}
		print_log(f'login HTTP {r.status_code}')
		if not j.get('success'):
			print_log('[FAIL] login unsuccessful: ' + str(j.get('message') or r.text[:200]))
			return False

		checked = (j.get('data') or {}).get('checked_in')
		print_log('[OK] login success, checked_in=' + str(checked))

		q = None
		try:
			s = c.get(BASE + '/api/user/self', headers=headers)
			q = (s.json().get('data') or {}).get('quota')
		except Exception:
			q = None
		if isinstance(q, int):
			print_log('balance=$%.2f (quota=%d)' % (q / QUOTA_UNIT, q))
			push_balance(user, q / QUOTA_UNIT, proxy)

		if checked is False:
			print_log('[INFO] already checked in today, no new quota')
		return True


def push_balance(label: str, balance: float, proxy: str | None) -> None:
	env = load_env(ENV_PATH)
	base = env.get('WORKER_URL', '').strip()
	tok = env.get('WORKER_ADMIN_TOKEN', '').strip()
	if not base or not tok:
		print_log('[WARN] Worker settings missing')
		return
	try:
		# Local worker: call directly (no proxy).
		with httpx.Client(timeout=15.0, trust_env=False) as c:
			r = c.post(
				base.rstrip('/') + '/agentrouter/api/balance',
				headers={'X-Admin-Token': tok},
				json={'label': label, 'balance': round(balance, 2)},
			)
			print_log('push-balance: HTTP %d' % r.status_code)
	except Exception as e:  # noqa: BLE001
		print_log('[WARN] push-balance failed: %r' % (e,))


_LOG = None


def print_log(msg: str) -> None:
	line = '[' + datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S') + '] ' + msg
	print(line)
	if _LOG:
		_LOG.write(line + '\n')
		_LOG.flush()


def main() -> int:
	global _LOG
	_LOG = open(LOG_PATH, 'a', encoding='utf-8')
	try:
		env = load_env(ENV_PATH)
		user = env.get('AGENTROUTER_USERNAME', '').strip()
		pwd = env.get('AGENTROUTER_PASSWORD', '').strip()
		api_user = env.get('AGENTROUTER_API_USER', '').strip()
		proxy = env.get('CHECKIN_PROXY_URL', '').strip() or None

		if not user or not pwd:
			print_log('[FAIL] credentials missing')
			return 1
		if not proxy:
			print_log('[WARN] CHECKIN_PROXY_URL empty; agentrouter.org is likely unreachable directly')

		last_err = None
		for attempt in range(1, ATTEMPTS + 1):
			try:
				if run_once(user, pwd, api_user, proxy):
					return 0
				print_log('[FAIL] task did not complete')
				return 1
			except Exception as e:  # noqa: BLE001
				last_err = e
				print_log('[WARN] attempt %d/%d failed: %r' % (attempt, ATTEMPTS, e))
				if attempt < ATTEMPTS:
					time.sleep(5)
		print_log('[FAIL] all attempts failed: %r' % (last_err,))
		return 1
	finally:
		_LOG.close()


if __name__ == '__main__':
	sys.exit(main())

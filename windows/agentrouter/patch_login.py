"""Patch only the diagnosed login/query/push implementation; never read .env."""
import ast
import pathlib
import re
import sys

MARKER = '# AgentRouter reliability fix 2026-11-17.1'


def patch_initial(source):
    if MARKER in source:
        compile(source, '<already-patched>', 'exec')
        return source
    tree = ast.parse(source)
    functions = {node.name: node for node in tree.body if isinstance(node, ast.FunctionDef)}
    if not {'run_once', 'push_balance', 'main', 'load_env', 'print_log'} <= functions.keys():
        raise ValueError('Unexpected login script: required functions not found')
    push = functions['push_balance']
    attempt = next(node for node in push.body if isinstance(node, ast.Try))
    post = next(node for node in ast.walk(attempt) if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == 'post')
    headers = next(kw.value for kw in post.keywords if kw.arg == 'headers')
    # Retain the installation's existing credential variable/expression verbatim.
    header_source = ast.get_source_segment(source, headers)
    if not isinstance(headers, ast.Dict) or 'X-Admin-Token' not in [getattr(k, 'value', None) for k in headers.keys]:
        raise ValueError('Unexpected Worker authentication header')
    lines = source.splitlines(keepends=True)
    prefix = ''.join(lines[push.lineno - 1:attempt.lineno - 1]).replace('-> None:', '-> bool:')
    prefix = re.sub(r'(?m)^([ \t]*)return[ \t]*$', r'\1return False', prefix)
    new_push = prefix + f'''\ttry:
\t\twith httpx.Client(timeout=15.0, trust_env=False) as c:
\t\t\tr = c.post(
\t\t\t\tbase.rstrip('/') + '/agentrouter/api/balance',
\t\t\t\theaders={header_source},
\t\t\t\tjson={{'label': label, 'balance': round(balance, 2)}},
\t\t\t)
\t\t\tif r.status_code != 200 or r.json().get('ok') is not True:
\t\t\t\tprint_log('[FAIL] balance push rejected (HTTP %d)' % r.status_code)
\t\t\t\treturn False
\t\t\tprint_log('push-balance: acknowledged HTTP 200')
\t\t\treturn True
\texcept Exception as e:
\t\tprint_log('[FAIL] balance push failed: ' + type(e).__name__)
\t\treturn False
'''
    source = ''.join(lines[:push.lineno - 1]) + new_push + ''.join(lines[push.end_lineno:])
    original = '''\t\tq = None
\t\ttry:
\t\t\ts = c.get(BASE + '/api/user/self', headers=headers)
\t\t\tq = (s.json().get('data') or {}).get('quota')
\t\texcept Exception:
\t\t\tq = None
\t\tif isinstance(q, int):
\t\t\tprint_log('balance=$%.2f (quota=%d)' % (q / QUOTA_UNIT, q))
\t\t\tpush_balance(user, q / QUOTA_UNIT, proxy)
'''
    replacement = '''\t\ttry:
\t\t\ts = c.get(BASE + '/api/user/self', headers=headers)
\t\t\tpayload = s.json()
\t\t\tq = (payload.get('data') or {}).get('quota')
\t\t\tif s.status_code != 200 or payload.get('success') is not True:
\t\t\t\tprint_log('[FAIL] balance query rejected (HTTP %d)' % s.status_code)
\t\t\t\treturn False
\t\t\tif isinstance(q, bool) or not isinstance(q, (int, float)) or not math.isfinite(q):
\t\t\t\tprint_log('[FAIL] balance query returned no valid quota')
\t\t\t\treturn False
\t\texcept Exception as e:
\t\t\tprint_log('[FAIL] balance query failed: ' + type(e).__name__)
\t\t\treturn False
\t\tprint_log('balance=$%.2f (quota=%s)' % (q / QUOTA_UNIT, q))
\t\tif not push_balance(user, q / QUOTA_UNIT, proxy):
\t\t\treturn False
'''
    if source.count(original) != 1 or source.count('import time\n') != 1:
        raise ValueError('Unexpected balance query implementation; no files replaced')
    source = source.replace(original, replacement).replace('import time\n', 'import time\nimport math\n')
    guard = "if __name__ == '__main__':\n\tsys.exit(main())"
    if source.count(guard) != 1:
        raise ValueError('Unexpected entry point; no files replaced')
    lock = '''def locked_main():
\t# The scheduled task and helper share an OS lock, released even on process exit.
\timport msvcrt
\twith open(os.path.join(HERE, 'checkin.lock'), 'a+b') as handle:
\t\tif handle.tell() == 0:
\t\t\thandle.write(b'0')
\t\t\thandle.flush()
\t\thandle.seek(0)
\t\ttry:
\t\t\tmsvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
\t\texcept OSError:
\t\t\tprint('AgentRouter task already running; skipped')
\t\t\treturn 75
\t\ttry:
\t\t\treturn main()
\t\tfinally:
\t\t\thandle.seek(0)
\t\t\tmsvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)


if __name__ == '__main__':
\tsys.exit(locked_main())'''
    source = source.replace("if not j.get('success'):", "if r.status_code != 200 or j.get('success') is not True:")
    source = MARKER + '\n' + source.replace(guard, lock)
    compile(source, '<patched-login>', 'exec')
    return source


NEW_MARKER = '# Conservative daily-once policy 2026-11-17.3'
OLD_MARKER = '# Conservative daily-once policy 2026-11-17.2'


def upgrade_from_v2(source):
    """Upgrade a 2026-11-17.2 installation without reading configuration."""
    source = source.replace(OLD_MARKER, NEW_MARKER, 1)
    if source.count('import json\n') == 0:
        if source.count('import math\n') != 1:
            raise ValueError('Unexpected v2 imports')
        source = source.replace('import math\n', 'import json\nimport math\n')
    old_signature = 'def push_balance(label: str, balance: float, proxy: str | None, checkin_confirmed=False) -> bool:'
    new_signature = 'def push_balance(label: str, balance: float, proxy: str | None, checkin_confirmed=False, balance_at=None) -> bool:'
    if source.count(old_signature) != 1:
        raise ValueError('Unexpected v2 push signature')
    source = source.replace(old_signature, new_signature)
    old_json = "json={'label': label, 'balance': round(balance, 2), 'checkin': {'confirmed': checkin_confirmed, 'date': _policy_day(), 'source': 'login_response.checked_in'}},"
    new_json = "json={'label': label, 'balance': round(balance, 2), 'balanceAt': balance_at, 'checkin': {'confirmed': checkin_confirmed, 'date': _policy_day(), 'source': 'login_response.checked_in'}},"
    if source.count(old_json) != 1:
        raise ValueError('Unexpected v2 push payload')
    source = source.replace(old_json, new_json)
    old_call = 'if not push_balance(user, q / QUOTA_UNIT, proxy, checkin_confirmed=(checked is True)):\n\t\t\treturn False'
    if source.count(old_call) != 1:
        raise ValueError('Unexpected v2 balance call')
    new_call = '''at = int(time.time() * 1000)
		LAST_RESULT.update(login=True, checkedIn=(checked is True), balance=q / QUOTA_UNIT, at=at, outcome='uncertain')
		save_local_receipt(user, checked is True, q / QUOTA_UNIT, at)
		if not push_balance(user, q / QUOTA_UNIT, proxy, checkin_confirmed=(checked is True), balance_at=at):
			LAST_RESULT.update(outcome=('success_unsynced' if checked is True else 'uncertain'))
			return False
		mark_receipt_pushed(user)
		LAST_RESULT.update(outcome=('success' if checked is True else 'uncertain'))'''
    source = source.replace(old_call, new_call)
    old_http = "\t\tprint_log(f'login HTTP {r.status_code}')\n\t\t_block_response(r, user)"
    new_http = "\t\tprint_log(f'login HTTP {r.status_code}')\n\t\tLAST_RESULT.clear()\n\t\tLAST_RESULT.update(login=(r.status_code == 200), outcome='uncertain')\n\t\t_block_response(r, user)"
    if source.count(old_http) != 1:
        raise ValueError('Unexpected v2 login response handling')
    source = source.replace(old_http, new_http)
    old_fail = "print_log('[FAIL] login unsuccessful (HTTP %d)' % r.status_code)"
    new_fail = old_fail + "\n\t\t\tLAST_RESULT.update(outcome=('blocked' if r.status_code in (401, 403, 429) else 'rejected'))"
    if source.count(old_fail) != 1:
        raise ValueError('Unexpected v2 login failure handling')
    source = source.replace(old_fail, new_fail)
    old_gate = ("\t\tpermit = request_daily_permit(user)\n"
                "\t\tif permit is None:\n"
                "\t\t\tprint_log('[FAIL] no local permit; no platform requests made')\n"
                "\t\t\treturn 1\n"
                "\t\tif not permit:\n"
                "\t\t\tprint_log('[INFO] daily workflow already processed; cache only')\n"
                "\t\t\treturn 0\n")
    new_gate = ("\t\tdecision = request_daily_action(user)\n"
                "\t\tif not decision.get('ok'):\n"
                "\t\t\tprint_log('[FAIL] no local permit; no platform requests made')\n"
                "\t\t\treturn 1\n"
                "\t\taction = decision.get('action')\n"
                "\t\tif action == 'sync':\n"
                "\t\t\tprint_log('[INFO] local receipt exists; syncing without platform login')\n"
                "\t\t\treturn sync_local_receipt(user)\n"
                "\t\tif action != 'run':\n"
                "\t\t\tprint_log('[INFO] daily workflow already processed; cache only')\n"
                "\t\t\treturn 0\n")
    if source.count(old_gate) != 1:
        raise ValueError('Unexpected v2 permission gate')
    source = source.replace(old_gate, new_gate)
    loop = re.compile(r"\t\tlast_err = None\n\t\tfor attempt in range\(1, ATTEMPTS \+ 1\):.*?\n\t\tprint_log\('\[FAIL\] all attempts failed: %r' % \(last_err,\)\)\n\t\treturn 1", re.S)
    replacement = '''\t\tlast_err = None
\t\tcode = 1
\t\tfor attempt in range(1, ATTEMPTS + 1):
\t\t\ttry:
\t\t\t\tcode = 0 if run_once(user, pwd, api_user, proxy) else 1
\t\t\t\tif code:
\t\t\t\t\tprint_log('[FAIL] task did not complete')
\t\t\texcept Exception as e:  # noqa: BLE001
\t\t\t\tlast_err = e
\t\t\t\tprint_log('[WARN] attempt %d/%d failed: %r' % (attempt, ATTEMPTS, e))
\t\t\t\tif attempt < ATTEMPTS:
\t\t\t\t\ttime.sleep(5)
\t\treport_outcome(user)
\t\tif code:
\t\t\tprint_log('[FAIL] all attempts failed: %r' % (last_err,))
\t\treturn code'''
    source, count = loop.subn(replacement, source)
    if count != 1:
        raise ValueError('Unexpected v2 retry loop')
    start = source.find('def _policy_day():')
    guard = "if __name__ == '__main__':\n\tsys.exit(reconcile_cached_receipt()"
    end = source.find(guard)
    if start < 0 or end <= start:
        raise ValueError('Unexpected v2 policy block')
    template = pathlib.Path(__file__).with_name('conservative_template.py.txt').read_text(encoding='utf-8')
    source = source[:start] + template + '\n\n' + source[end:]
    compile(source, '<upgraded-v2>', 'exec')
    return source


def patch(source):
    if NEW_MARKER in source:
        compile(source, '<already-upgraded>', 'exec')
        return source
    if OLD_MARKER in source:
        return upgrade_from_v2(source)
    source = patch_initial(source)
    if source.count('import math\n') != 1:
        raise ValueError('Unexpected imports')
    source = source.replace('import math\n', 'import json\nimport math\n')
    tree = ast.parse(source)
    functions = {n.name: n for n in tree.body if isinstance(n, ast.FunctionDef)}
    push = functions['push_balance']
    attempt = next(n for n in push.body if isinstance(n, ast.Try))
    post = next(n for n in ast.walk(attempt) if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr == 'post')
    headers = next(k.value for k in post.keywords if k.arg == 'headers')
    header_source = ast.get_source_segment(source, headers)
    lines = source.splitlines(keepends=True)
    prefix_body = ''.join(lines[push.lineno:attempt.lineno - 1])
    settings = 'def _worker_settings():\n' + prefix_body + '\treturn base, ' + header_source + '\n\n'
    template = pathlib.Path(__file__).with_name('conservative_template.py.txt').read_text(encoding='utf-8')
    # Keep the actual deployment's credential lookup, not the test fixture's key names.
    old_signature = 'def push_balance(label: str, balance: float, proxy: str | None) -> bool:'
    new_signature = 'def push_balance(label: str, balance: float, proxy: str | None, checkin_confirmed=False, balance_at=None) -> bool:'
    if source.count(old_signature) != 1:
        raise ValueError('Unexpected patched push signature')
    source = source.replace(old_signature, new_signature)
    old_json = "json={'label': label, 'balance': round(balance, 2)},"
    new_json = "json={'label': label, 'balance': round(balance, 2), 'balanceAt': balance_at, 'checkin': {'confirmed': checkin_confirmed, 'date': _policy_day(), 'source': 'login_response.checked_in'}},"
    if source.count(old_json) != 1:
        raise ValueError('Unexpected patched push payload')
    source = source.replace(old_json, new_json)
    old_call = 'if not push_balance(user, q / QUOTA_UNIT, proxy):\n\t\t\treturn False'
    if source.count(old_call) != 1:
        raise ValueError('Unexpected patched balance call')
    new_call = '''at = int(time.time() * 1000)
		LAST_RESULT.update(login=True, checkedIn=(checked is True), balance=q / QUOTA_UNIT, at=at, outcome='uncertain')
		save_local_receipt(user, checked is True, q / QUOTA_UNIT, at)
		if not push_balance(user, q / QUOTA_UNIT, proxy, checkin_confirmed=(checked is True), balance_at=at):
			LAST_RESULT.update(outcome=('success_unsynced' if checked is True else 'uncertain'))
			return False
		mark_receipt_pushed(user)
		LAST_RESULT.update(outcome=('success' if checked is True else 'uncertain'))'''
    source = source.replace(old_call, new_call)
    source = source.replace("\t\tprint_log(f'login HTTP {r.status_code}')", "\t\tprint_log(f'login HTTP {r.status_code}')\n\t\tLAST_RESULT.clear()\n\t\tLAST_RESULT.update(login=(r.status_code == 200), outcome='uncertain')\n\t\t_block_response(r, user)")
    source = source.replace("\t\t\ts = c.get(BASE + '/api/user/self', headers=headers)", "\t\t\ts = c.get(BASE + '/api/user/self', headers=headers)\n\t\t\t_block_response(s, user)")
    source = source.replace("print_log('[FAIL] login unsuccessful: ' + str(j.get('message') or r.text[:200]))", "print_log('[FAIL] login unsuccessful (HTTP %d)' % r.status_code)\n\t\t\tLAST_RESULT.update(outcome=('blocked' if r.status_code in (401, 403, 429) else 'rejected'))")

    source = source.replace('ATTEMPTS = 3', 'ATTEMPTS = 1')
    anchor = "\t\tif not proxy:\n"
    if source.count(anchor) != 1:
        raise ValueError('Unexpected main entry point')
    gate = ("\t\tdecision = request_daily_action(user)\n"
            "\t\tif not decision.get('ok'):\n"
            "\t\t\tprint_log('[FAIL] no local permit; no platform requests made')\n"
            "\t\t\treturn 1\n"
            "\t\taction = decision.get('action')\n"
            "\t\tif action == 'sync':\n"
            "\t\t\tprint_log('[INFO] local receipt exists; syncing without platform login')\n"
            "\t\t\treturn sync_local_receipt(user)\n"
            "\t\tif action != 'run':\n"
            "\t\t\tprint_log('[INFO] daily workflow already processed; cache only')\n"
            "\t\t\treturn 0\n")
    source = source.replace(anchor, gate + anchor)
    loop = re.compile(r"\t\tlast_err = None\n\t\tfor attempt in range\(1, ATTEMPTS \+ 1\):.*?\n\t\tprint_log\('\[FAIL\] all attempts failed: %r' % \(last_err,\)\)\n\t\treturn 1", re.S)
    replacement = '''\t\tlast_err = None
\t\tcode = 1
\t\tfor attempt in range(1, ATTEMPTS + 1):
\t\t\ttry:
\t\t\t\tcode = 0 if run_once(user, pwd, api_user, proxy) else 1
\t\t\t\tif code:
\t\t\t\t\tprint_log('[FAIL] task did not complete')
\t\t\texcept Exception as e:  # noqa: BLE001
\t\t\t\tlast_err = e
\t\t\t\tprint_log('[WARN] attempt %d/%d failed: %r' % (attempt, ATTEMPTS, e))
\t\t\t\tif attempt < ATTEMPTS:
\t\t\t\t\ttime.sleep(5)
\t\treport_outcome(user)
\t\tif code:
\t\t\tprint_log('[FAIL] all attempts failed: %r' % (last_err,))
\t\treturn code'''
    source, count = loop.subn(replacement, source)
    if count != 1:
        raise ValueError('Unexpected main retry loop')
    guard = "if __name__ == '__main__':\n\tsys.exit(locked_main())"
    if source.count(guard) != 1:
        raise ValueError('Unexpected locked entry point')
    new_guard = "if __name__ == '__main__':\n\tsys.exit(reconcile_cached_receipt() if '--reconcile-local' in sys.argv[1:] else locked_main())"
    source = NEW_MARKER + '\n' + source.replace(guard, settings + template + '\n\n' + new_guard)
    compile(source, '<conservative-login>', 'exec')
    return source


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('Usage: patch_login.py SOURCE OUTPUT')
    src, output = map(pathlib.Path, sys.argv[1:])
    result = patch(src.read_text(encoding='utf-8-sig'))
    output.write_text(result, encoding='utf-8', newline='\n')
    print('Python patch generated and syntax checked; configuration was not read.')

import importlib.util
import json
import pathlib
import sys
import tempfile
import types

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('patch_login', ROOT / 'windows/agentrouter/patch_login.py')
patcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patcher)
fixture = (ROOT / 'tests/fixtures/login_checkin.py').read_text()
patched = patcher.patch(pathlib.Path(sys.argv[2]).read_text(encoding='utf-8-sig') if len(sys.argv) > 2 and sys.argv[1] == '--patched' else fixture)
assert patcher.patch(patched) == patched

# A previously installed 2026-11-17.2 file must upgrade without reading configuration.
v2 = patcher.patch_initial(fixture)
v2 = v2.replace('def push_balance(label: str, balance: float, proxy: str | None) -> bool:', 'def push_balance(label: str, balance: float, proxy: str | None, checkin_confirmed=False) -> bool:')
v2 = v2.replace("json={'label': label, 'balance': round(balance, 2)},", "json={'label': label, 'balance': round(balance, 2), 'checkin': {'confirmed': checkin_confirmed, 'date': _policy_day(), 'source': 'login_response.checked_in'}},")
v2 = v2.replace('if not push_balance(user, q / QUOTA_UNIT, proxy):\n\t\t\treturn False', 'if not push_balance(user, q / QUOTA_UNIT, proxy, checkin_confirmed=(checked is True)):\n\t\t\treturn False')
v2 = v2.replace("\t\tprint_log(f'login HTTP {r.status_code}')", "\t\tprint_log(f'login HTTP {r.status_code}')\n\t\t_block_response(r, user)")
v2 = v2.replace("\t\t\ts = c.get(BASE + '/api/user/self', headers=headers)", "\t\t\ts = c.get(BASE + '/api/user/self', headers=headers)\n\t\t\t_block_response(s, user)")
v2 = v2.replace("print_log('[FAIL] login unsuccessful: ' + str(j.get('message') or r.text[:200]))", "print_log('[FAIL] login unsuccessful (HTTP %d)' % r.status_code)")
v2 = v2.replace('ATTEMPTS = 3', 'ATTEMPTS = 1')
v2 = v2.replace("\t\tif not proxy:\n", "\t\tpermit = request_daily_permit(user)\n\t\tif permit is None:\n\t\t\tprint_log('[FAIL] no local permit; no platform requests made')\n\t\t\treturn 1\n\t\tif not permit:\n\t\t\tprint_log('[INFO] daily workflow already processed; cache only')\n\t\t\treturn 0\n\t\tif not proxy:\n")
v2 = v2.replace("if __name__ == '__main__':\n\tsys.exit(locked_main())", "def _worker_settings():\n\treturn 'http://worker', {'X-Admin-Token':'t'}\n\ndef _policy_day():\n\treturn '2026-11-17'\n\nif __name__ == '__main__':\n\tsys.exit(reconcile_cached_receipt() if '--reconcile-local' in sys.argv[1:] else locked_main())")
v2 = patcher.OLD_MARKER + '\n' + v2
upgraded = patcher.patch(v2)
assert patcher.NEW_MARKER in upgraded
assert 'request_daily_action(user)' in upgraded
assert 'request_daily_permit' not in upgraded
assert 'LAST_RESULT = {}' in upgraded
assert 'save_local_receipt' in upgraded
compile(upgraded, '<upgraded-v2-test>', 'exec')
print('PASS v2 upgrade: installed 2026-11-17.2 becomes v3 with receipt sync and noon action gate.')
try:
    patcher.patch('def main(): pass')
except ValueError:
    pass
else:
    raise AssertionError('Unknown script was accepted')

class Response:
    def __init__(self, data, status=200): self.data, self.status_code = data, status
    def json(self): return self.data

fake_httpx = types.ModuleType('httpx')
sys.modules['httpx'] = fake_httpx
module = {'__file__': str(ROOT / 'tests/fixtures/login_checkin.py'), '__name__': 'fixture'}
exec(compile(patched, '<patched-fixture>', 'exec'), module)
logs = []
module['print_log'] = logs.append
class TestSettings(dict):
    def get(self, key, default=None):
        return {
            'WORKER_URL': 'http://worker',
            'WORKER_ADMIN_TOKEN': 'test-only',
            'AGENTROUTER_USERNAME': 'example',
            'AGENTROUTER_PASSWORD': 'pwd',
            'AGENTROUTER_API_USER': '123',
            'CHECKIN_PROXY_URL': '',
        }.get(key, default)
module['load_env'] = lambda _: TestSettings()
real_main = module['main']

def scenario(quota, checked=True, query_status=200, query_success=True, push_status=200, push_success=True):
    calls=[]
    class Client:
        def __init__(self, **kwargs): pass
        def __enter__(self): return self
        def __exit__(self, *args): pass
        def post(self, url, **kwargs):
            calls.append((url,kwargs))
            if url.endswith('/login'): return Response({'success': True, 'data': {'checked_in': checked}})
            return Response({'ok':push_success},push_status)
        def get(self,url,**kwargs): return Response({'success':query_success,'data':{'quota':quota}},query_status)
    fake_httpx.Client=Client
    result=module['run_once']('example','test-only','123',None)
    assert len([c for c in calls if c[0].endswith('/login')])==1
    return result,calls

with tempfile.TemporaryDirectory(prefix='agentrouter receipts ') as folder:
    module['HERE']=folder
    module['ENV_PATH']=str(pathlib.Path(folder)/'.env')
    module['LOG_PATH']=str(pathlib.Path(folder)/'checkin.log')

    result,calls=scenario(500000,checked=True)
    assert result is True
    assert module['LAST_RESULT']['outcome']=='success'
    receipt=module['load_local_receipt']('example')
    assert receipt and receipt['checkedIn'] is True and receipt['pushed'] is True

    result,_=scenario(0,checked=False)
    assert result is True
    assert module['LAST_RESULT']['outcome']=='uncertain'
    assert module['load_local_receipt']('example') is None

    result,_=scenario(500000,checked=True,push_status=401)
    assert result is False
    assert module['LAST_RESULT']['outcome']=='success_unsynced'
    assert module['load_local_receipt']('example')['balance']==1.0

    for quota in [None, True, '10', float('nan'), float('inf')]:
        (pathlib.Path(folder)/'last_result.json').unlink(missing_ok=True)
        result,_=scenario(quota)
        assert result is False
        assert module['load_local_receipt']('example') is None
    assert scenario(500000,query_status=401)[0] is False
    assert scenario(500000,query_success=False)[0] is False
    assert scenario(500000,push_success=False)[0] is False

    module['load_env']=lambda _: {}
    assert module['push_balance']('example',0,None) is False
    assert module['request_daily_action']('example')['ok'] is False
    module['load_env']=lambda _: TestSettings()

    def permit_scenario(payload, status=200, calls=None):
        calls = calls if calls is not None else []
        class Client:
            def __init__(self, **kwargs): pass
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def post(self, url, **kwargs):
                calls.append(url)
                return Response(payload,status)
        fake_httpx.Client=Client
        return module['request_daily_action']('example'), calls

    assert permit_scenario({'ok':True,'allowed':True,'action':'run'})[0]['action']=='run'
    assert permit_scenario({'ok':True,'allowed':False,'action':'sync'})[0]['action']=='sync'
    assert permit_scenario({'ok':True,'allowed':False,'action':'none'})[0]['action']=='none'
    assert permit_scenario({'ok':True,'allowed':True})[0]['action']=='run'
    assert permit_scenario({'ok':True,'allowed':False},500)[0]['ok'] is False

    def sync_scenario(push_success=True, receipt=True):
        path=pathlib.Path(folder)/'last_result.json'
        if receipt:
            path.write_text(json.dumps({'label':'example','date':module['_policy_day'](),'at':1234567890000,'checkedIn':True,'balance':12.5,'pushed':False}))
        else:
            path.unlink(missing_ok=True)
        calls=[]
        class Client:
            def __init__(self, **kwargs): pass
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def post(self, url, **kwargs):
                calls.append((url,kwargs))
                return Response({'ok':push_success})
        fake_httpx.Client=Client
        code=module['sync_local_receipt']('example')
        assert not any(url.endswith('/login') for url,_ in calls)
        return code,calls

    code,calls=sync_scenario()
    assert code==0 and any(url.endswith('/agentrouter/api/balance') for url,_ in calls)
    assert json.loads((pathlib.Path(folder)/'last_result.json').read_text())['pushed'] is True
    assert sync_scenario(push_success=False)[0]==1
    assert sync_scenario(receipt=False)[0]==1

# Main gate: cache-only decisions must never contact the platform.
def main_scenario(action, permit_ok=True, receipt=True):
    calls=[]
    class Client:
        def __init__(self, **kwargs): pass
        def __enter__(self): return self
        def __exit__(self, *args): pass
        def post(self, url, **kwargs):
            calls.append((url,kwargs))
            if url.endswith('/agentrouter/api/permit'):
                return Response({'ok':permit_ok,'allowed':action=='run','action':action})
            if url.endswith('/login'):
                return Response({'success': True, 'data': {'checked_in': True}})
            return Response({'ok':True})
        def get(self,url,**kwargs): return Response({'success':True,'data':{'quota':500000}})
    fake_httpx.Client=Client
    with tempfile.TemporaryDirectory(prefix='agentrouter gate ') as folder:
        module['HERE']=folder
        module['ENV_PATH']=str(pathlib.Path(folder)/'.env')
        module['LOG_PATH']=str(pathlib.Path(folder)/'checkin.log')
        if receipt:
            (pathlib.Path(folder)/'last_result.json').write_text(json.dumps({'label':'example','date':module['_policy_day'](),'at':1234567890000,'checkedIn':True,'balance':12.5,'pushed':False}))
        module['load_env']=lambda _: TestSettings()
        code=module['main']()
    logins=[url for url,_ in calls if url.endswith('/login')]
    return code,logins,calls

code,logins,_=main_scenario('none')
assert code==0 and logins==[]
code,logins,calls=main_scenario('sync')
assert code==0 and logins==[] and any(url.endswith('/agentrouter/api/balance') for url,_ in calls)
code,logins,_=main_scenario('run')
assert code==0 and len(logins)==1
code,logins,_=main_scenario('run',permit_ok=False)
assert code==1 and logins==[]

# Exercise the shared lock path with a deterministic substitute for Windows msvcrt.
msvcrt=types.ModuleType('msvcrt');msvcrt.LK_NBLCK=1;msvcrt.LK_UNLCK=2;held=False

def locking(fd,mode,count):
    global held
    if mode==msvcrt.LK_NBLCK:
        if held: raise OSError('busy')
        held=True
    else: held=False

if sys.platform != 'win32':
    msvcrt.locking=locking;sys.modules['msvcrt']=msvcrt
with tempfile.TemporaryDirectory(prefix='agentrouter lock 中文 ') as folder:
    module['HERE']=folder
    def main():
        assert module['locked_main']()==75
        return 0
    module['main']=main
    assert module['locked_main']()==0 and not held
    module['main']=lambda: 1
    assert module['locked_main']()==1 and not held
module['main']=real_main
print('PASS Python patch: preserved credential lookup, valid/zero/invalid quota, rejected query/push, missing configuration, idempotence, unknown version guard, shared lock/release (native on Windows; substituted on other platforms).')

assert module['ATTEMPTS']==1
assert 'request_daily_action(user)' in patched
with tempfile.TemporaryDirectory(prefix='checkin receipt ') as folder:
    path=pathlib.Path(folder)/'sample.log'
    timezone=module['datetime'].timezone(module['datetime'].timedelta(hours=8))
    stamp=module['datetime'].datetime.now(timezone).replace(microsecond=0)
    prefix='['+stamp.strftime('%Y-%m-%d %H:%M:%S')+'] '
    valid='\n'.join(prefix+x for x in ['login HTTP 200','[OK] login success, checked_in=True','balance=$0.00 (quota=0)','push-balance: acknowledged HTTP 200'])+'\n'
    path.write_text(valid)
    row={'balance':0,'balanceAt':stamp.timestamp()*1000}
    assert module['historical_receipt'](str(path),row)==row['balanceAt']
    assert module['historical_attempt_today'](str(path)) is True
    path.write_text(valid.replace('checked_in=True','checked_in=False'))
    assert module['historical_receipt'](str(path),row) is None
    path.write_text(valid)
    assert module['historical_receipt'](str(path),{'balance':25,'balanceAt':row['balanceAt']}) is None
    assert module['historical_receipt'](str(path),{'balance':0,'balanceAt':row['balanceAt']-30000}) is None

# Denied or unavailable local permission must prevent any account request.
settings=TestSettings()
module['load_env']=lambda _: settings
for action, expected in [('none', 0), ('sync', 1)]:
    calls=[]
    class Client:
        def __init__(self, **kwargs): pass
        def __enter__(self): return self
        def __exit__(self, *args): pass
        def post(self, url, **kwargs):
            calls.append(url)
            if url.endswith('/permit'): return Response({'ok':True,'allowed':False,'action':action})
            return Response({'ok':True})
    fake_httpx.Client=Client
    def forbidden(*args): raise AssertionError('Platform contacted without a local permit')
    with tempfile.TemporaryDirectory(prefix='daily cap ') as folder:
        module['HERE']=folder
        module['LOG_PATH']=str(pathlib.Path(folder)/'checkin.log')
        module['run_once']=forbidden
        actual=module['main']()
        assert actual==expected, (action, expected, actual)
print('PASS conservative Python: one attempt, denial is fail-closed, no platform calls on skipped runs, historical receipt needs exact same-day login/balance/push evidence.')

with tempfile.TemporaryDirectory(prefix='no retry ') as folder:
    fresh={'__file__':module['__file__'],'__name__':'fixture'}
    exec(compile(patched,'<one-attempt>','exec'),fresh)
    attempts=[]
    def fail_once(*args):
        attempts.append(1)
        raise ConnectionError('synthetic network failure')
    fresh['load_env']=lambda _: settings
    fresh['request_daily_action']=lambda _: {'ok':True,'action':'run'}
    fresh['run_once']=fail_once
    fresh['HERE']=folder
    fresh['LOG_PATH']=str(pathlib.Path(folder)/'checkin.log')
    fresh['print_log']=logs.append
    assert fresh['main']()==1 and len(attempts)==1
print('PASS no retry: one failing login workflow is attempted exactly once.')

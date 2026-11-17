import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { createHelper, VERSION } from '../windows/agentrouter/helper.mjs';
const children=[];let killed=0;
const server=createHelper({run(){const child=new EventEmitter();child.pid=123;child.exitCode=null;children.push(child);return child;},timeoutMs:1000,kill(child){killed++;child.emit('close',null);}});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const base='http://127.0.0.1:'+server.address().port;
const call=()=>fetch(base+'/refresh',{method:'POST'});
async function untilChild(count){while(children.length<count)await new Promise(r=>setImmediate(r));}
try {
 assert.equal((await(await fetch(base+'/health')).json()).version,VERSION);
 let request=call();await untilChild(1);
 assert.equal((await call()).status,409);
 children[0].emit('close',0);assert.deepEqual(await(await request).json(),{ok:true});
 request=call();await untilChild(2);children[1].emit('close',1);
 assert.equal((await request).status,502);
 request=call();await untilChild(3);children[2].emit('close',75);
 assert.equal((await request).status,409);
 request=call();await untilChild(4);children[3].emit('error',new Error('synthetic spawn failure'));
 assert.equal((await request).status,502);
 assert.equal((await call()).status,504);assert.equal(killed,1);
 assert.equal((await(await fetch(base+'/health')).json()).running,false);
 console.log('PASS helper: real HTTP with mocked children, success/failure/lock/busy/spawn error/timeout, no child output disclosure.');
} finally {server.closeAllConnections();await new Promise(r=>server.close(r));}

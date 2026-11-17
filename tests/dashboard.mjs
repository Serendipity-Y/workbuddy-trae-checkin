import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import vm from 'node:vm';
const code=await fs.readFile(new URL('../worker.js',import.meta.url),'utf8');
const {default:worker}=await import('data:text/javascript;base64,'+Buffer.from(code).toString('base64'));
const html=await (await worker.fetch(new Request('http://local/'),{},{})).text();
const script=html.match(/<script>([\s\S]*?)<\/script>/)[1];
const tick=()=>new Promise(r=>setImmediate(r));
const today=new Date(Date.now()+8*3600e3).toISOString().slice(0,10);
const defs=['trae','wb','qoder','agentrouter','future'].map(id=>({id,name:id==='agentrouter'?'AgentRouter':id==='wb'?'WorkBuddy':id==='future'?'Future':id,listPath:'/'+id+'/api/list'}));
const ok=data=>Promise.resolve({status:200,ok:true,json:async()=>data});
function setup(fetch){
 const elements=new Map(), intervals=[],timers=new Map();let timerId=0;const calls=[];
 const document={hidden:false,querySelector(s){if(!elements.has(s))elements.set(s,{textContent:'',innerHTML:'',disabled:false,hidden:false,value:''});return elements.get(s);},addEventListener(){}};
 const context=vm.createContext({document,localStorage:{getItem(){return ''},setItem(){},removeItem(){}},location:{hostname:'127.0.0.1',protocol:'http:'},window:{addEventListener(){}},URL,AbortController,Date,Promise,Number,
  fetch:(...args)=>{calls.push(args);return fetch(...args)},setInterval:fn=>intervals.push(fn),clearInterval(){},setTimeout:fn=>{timers.set(++timerId,fn);return timerId},clearTimeout:id=>timers.delete(id)});
 vm.runInContext(script,context);context.tok='test-only';return{context,elements,intervals,timers,calls,document};
}
const list=path=>path==='/api/platforms'?ok({platforms:defs}):ok({accounts:[{label:'example',balance:0,balanceAt:Date.now(),signedToday:true,lastOkDate:today}]});
{
 const app=setup(p=>p.includes('/wb/api/list')?Promise.reject(new Error('WorkBuddy offline')):list(p));
 await app.context.load();
 assert.ok(app.elements.get('#rows').innerHTML.includes('AgentRouter'));
 assert.ok(app.elements.get('#rows').innerHTML.includes('$0.00'));
 assert.ok(app.elements.get('#rows').innerHTML.includes('Future'));
 assert.ok(app.elements.get('#status').textContent.includes('WorkBuddy'));
 assert.equal(app.elements.get('#dashboardStat').textContent,'4 / 5');
}
{
 const app=setup(list);
 app.elements.get('#refresh').onclick();for(let i=0;i<8;i++)await tick();
 assert.equal(app.elements.get('#refresh').disabled,false);
 assert.equal(app.elements.get('#dashboardStat').textContent,'5 / 5');
 assert.equal(app.intervals.length,0);
 assert.ok(app.calls.every(([,opts])=>opts.method==='GET'));
 assert.ok(app.elements.get('#rows').innerHTML.includes('余额采集'));
}
{
 const app=setup(()=>new Promise(()=>{}));
 const pending=app.context.requestJSON('/hung',{},100);
 for(const fn of [...app.timers.values()])fn();
 await assert.rejects(pending,/超时/);
}
console.log('PASS dashboard: dynamic five-platform progress, independent lists, zero balance, cache-only refresh, no periodic polling, request timeout, collection timestamp.');

const consoleHtml=await(await worker.fetch(new Request('http://local/console'),{},{})).text();
const consoleScript=consoleHtml.match(/<script>([\s\S]*?)<\/script>/)[1];
const elements=new Map();
const element=()=>({textContent:'',innerHTML:'',hidden:false,value:'',dataset:{},style:{},classList:{toggle(){}},addEventListener(){},appendChild(){}});
const ctx=vm.createContext({document:{querySelector(s){if(!elements.has(s))elements.set(s,element());return elements.get(s)},querySelectorAll(){return []},createElement:element,addEventListener(){}},window:{addEventListener(){}},localStorage:{getItem(){return ''},setItem(){},removeItem(){}},setInterval(){},clearInterval(){},setTimeout(){},Date,Promise,URL,console,fetch:list});
vm.runInContext(consoleScript,ctx);
ctx.state.platforms=defs;ctx.state.data=Object.fromEntries(defs.map(d=>[d.id,{accounts:[{signedToday:true,lastOkDate:today}]}]));
ctx.renderStat();assert.equal(elements.get('#statAll').textContent,'5 / 5');
ctx.state.data.agentrouter={accounts:[{updatedToday:true}]};ctx.renderStat();assert.equal(elements.get('#statAll').textContent,'4 / 5');
console.log('PASS console: registry-based platform count includes AgentRouter and future providers; balance-only update is not completion.');

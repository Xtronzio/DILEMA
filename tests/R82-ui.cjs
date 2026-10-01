const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const html=fs.readFileSync(process.argv[2]||'/tmp/r82.html','utf8');
const source=html.slice(html.indexOf('/* R82: table-approved admission'),html.lastIndexOf('</script>'));
const nodes=new Map(),calls=[],values=new Map();
function node(id){if(nodes.has(id))return nodes.get(id);const classes=new Set();const n={id,dataset:{},style:{display:'none'},textContent:'',innerHTML:'',disabled:false,classList:{contains:c=>id==='debate'&&c==='active'||classes.has(c),add:c=>classes.add(c),remove:c=>classes.delete(c),toggle:(c,on)=>on?classes.add(c):classes.delete(c)},focus(){this.focused=true},append(){},appendChild(){},after(){},setAttribute(){},querySelectorAll(){return[]},querySelector(){return node(id+'-button')}};nodes.set(id,n);return n}
for(const id of ['debate','pilotHostGroup','pilotAdmissionAction','pilotAdmissionHint','pilotVoteStage','pilotAdmissionVoteBox','pilotAdmissionInitialVote','admissionPending','admissionPendingText','admissionPendingCancel','privateCatalogError'])node(id);
const yes=node('yes'),no=node('no'),a=node('a'),b=node('b');yes.dataset.admissionVote='yes';no.dataset.admissionVote='no';a.dataset.admissionChoice='A';b.dataset.admissionChoice='B';
node('pilotAdmissionVoteBox').querySelectorAll=()=>[yes,no];node('pilotAdmissionVoteBox').querySelector=s=>node(s);
node('pilotAdmissionInitialVote').querySelectorAll=()=>[a,b];
const action=node('pilotGiroBtn'),abandon=node('pilotAbandonBtn');
let membership={id:1},rpcData={},rpcError=null,entered=0,home=0,cleaned=0,sampled=0;
const storage={setItem:(k,v)=>values.set(k,v),getItem:k=>values.get(k)||null,removeItem:k=>values.delete(k)};
const chain={select(){return this},eq(){return this},abortSignal(){return this},async maybeSingle(){calls.push({name:'membership'});return {data:membership,error:null}}};
const context={document:{getElementById:id=>nodes.get(id)||null,createElement:()=>node('created'+nodes.size),querySelectorAll:s=>s.includes('role=')?[]:[action,abandon],body:{appendChild(n){nodes.set(n.id,n)}},visibilityState:'visible'},window:{dilemaAdmissionSnapshot:{round:82,data:null},pilotRefresh:async()=>{}},currentRoomId:82,currentRoundId:82,currentUserId:'USER',localPlayerId:'PLAYER',currentDilemma:{option_a:'ALFA',option_b:'BETA'},privateBusy:false,privateCatalogueSamples:[],getComputedStyle:n=>n.style,sb:{from:()=>chain,rpc:async(name,args)=>{calls.push({name,args});return {data:rpcData,error:rpcError}}},console,Date,AbortSignal,sessionStorage:storage,setInterval:()=>1,clearInterval(){},alert:m=>calls.push({name:'alert',m}),cleanupRoom(){cleaned++;context.currentRoomId=null;values.delete('dilema_admission_pending')},goHome(){home++},enterRoom:async()=>{entered++},saveRoomSession(){},announceHallChange(){},showScreen:id=>calls.push({name:'screen',id}),renderPrivateCatalog(){},samplePrivateCatalog:async()=>{sampled++}};
vm.createContext(context);vm.runInContext(source,context);
async function paint(data){context.window.dilemaAdmissionSnapshot.data=data;await context.window.pilotRefresh()}
const base={enabled:false,is_host:true,id:null,name:null,players:3,yes:0,no:0,mine:null,present:true,needs_vote:false,can_vote:true,queued:0};
(async()=>{
 await paint(base);assert.equal(node('pilotAdmissionAction').textContent,'AÑADIR DEBATIENTE');assert.equal(node('pilotAdmissionAction').classList.contains('is-selected'),false);
 await paint({...base,enabled:true});assert.equal(node('pilotAdmissionAction').textContent,'CERRAR ENTRADA');
 await paint({...base,id:2,name:'<img src=x>',yes:1});assert.ok(node('[data-admission-question]').textContent.includes('<img src=x>'));assert.equal(yes.disabled,false);assert.equal(no.disabled,false);assert.equal(yes.classList.contains('pilot-selected'),false);assert.equal(action.disabled,true);assert.equal(abandon.disabled,false);
 await paint({...base,id:2,mine:false});assert.equal(yes.disabled,true);assert.equal(no.classList.contains('pilot-selected'),true);
 await paint({...base,needs_vote:true});assert.equal(node('pilotAdmissionInitialVote').style.display,'block');assert.ok(a.textContent.includes('ALFA'));assert.equal(a.disabled,false);
 await paint({...base,needs_vote:true,can_vote:false});assert.equal(a.disabled,true);
 vm.runInContext('roomMembershipConfirmed=true;membershipCheckedAt=0;',context);await context.verifyRoomMembership(82);assert.equal(cleaned,0);
 membership=null;vm.runInContext('membershipCheckedAt=0',context);assert.equal(await context.verifyRoomMembership(82),false);assert.equal(cleaned,1);assert.ok(node('roomExpelledNotice').innerHTML.includes('HAS SIDO EXPULSADO'));assert.ok(node('roomExpelledNotice').innerHTML.includes('VOLVER AL HALL'));assert.equal(home,0,'Exit should require acknowledgement');
 context.currentRoomId=82;rpcData=9;await context.beginNewAdmission({name:'NEW',avatar:'⭐'});assert.ok(values.has('dilema_admission_pending'));
 rpcData={status:'queued'};await context.refreshNewAdmission();assert.ok(node('admissionPendingText').textContent.includes('espera'));
 rpcData={status:'accepted',room_id:82,player_id:'NEW'};await context.refreshNewAdmission();assert.equal(entered,1);assert.equal(values.has('dilema_admission_pending'),false);
 context.privateCatalogueSamples=[{id:1},{id:2}];await context.discardPrivateWorldCandidates();assert.deepEqual(calls.filter(c=>c.name==='remember_world_dilemma').map(c=>c.args.p_id),[1,2]);assert.equal(sampled,1);
 assert.ok(html.includes('if(admissionRequestId)return false;'));assert.ok(html.includes('if(admissionRequestId)return;'));assert.ok(html.includes("'pilotAdmissionInitialVote'].some"));
 assert.ok(html.includes('ids.filter(x=>/^\\d+$/.test(String(x))).map(Number)'));assert.ok(html.includes("voteDebateSelection('__DISCARD__')"));
 assert.ok(html.includes('font-weight:400;line-height:1.65'));assert.ok(html.includes('.am-line b{color:#facc15'));
 console.log('PASS R82: admission UI, hidden default selections, safe applicant text, locks, initial posture, expulsion acknowledgement, pending recovery and private world discard');
})().catch(e=>{console.error(e);process.exitCode=1});

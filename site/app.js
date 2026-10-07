import {BrowserProvider,JsonRpcProvider,Contract,parseEther,formatEther,isAddress,toBeHex} from './vendor/ethers.js';
import {validProof} from './miner/common.js';
const $=id=>document.getElementById(id);
const show=(id,value)=>{$(id).textContent=value;};
const fmt=(value,digits=5)=>Number(formatEther(value)).toLocaleString(undefined,{maximumFractionDigits:digits});
const when=seconds=>seconds?new Date(Number(seconds)*1000).toLocaleString():'—';
const message=(text,error=false)=>{show('notice',text);$('notice').classList.toggle('error',error);};
const errorText=e=>e?.shortMessage||e?.reason||e?.message||String(e);
let config,abis,provider,wallet,signer,account,hook,frog,token,imd,staking,router;
let ready=false,busy=false,refreshing=false,worker,job,solution,mining=false,jobNumber=0;
let state={},galleryPage=0,galleryVersion='';
const controls=['start-mining','quote-trade','swap','burn','buyback','stake-button','request-exit','claim','withdraw-stake','flush','redeem'];

function buttons() {
  for(const id of controls) $(id).disabled=!ready||busy||!account;
  $('start-mining').disabled ||= mining||state.slots===0n||state.minted===2000n;
  $('mint').disabled=!ready||busy||!account||!solution;
  $('stop-mining').disabled=!mining;
}
function stopMining(reason='Miner is idle.') {
  mining=false;worker?.terminate();worker=null;job=null;solution=null;
  show('miner-status',reason);show('hashrate','0 H/s');show('eta','—');buttons();
}
function amount(id) {
  const value=$(id).value.trim();
  if(!/^\d+(\.\d{1,18})?$/.test(value)) throw new Error('Enter a positive amount with up to 18 decimals.');
  const n=parseEther(value);if(n<=0n) throw new Error('Amount must be greater than zero.');return n;
}
function slippageBps() {
  const n=Number($('slippage').value);
  if(!Number.isFinite(n)||n<0.1||n>5) throw new Error('Choose slippage between 0.1% and 5%.');
  return BigInt(Math.round(n*100));
}
async function assertWallet() {
  if(!ready||!signer||!account) throw new Error('Connect your wallet on Ethereum mainnet first.');
  const chain=await wallet.send('eth_chainId',[]);
  const accounts=await wallet.send('eth_accounts',[]);
  if(BigInt(chain)!==1n||accounts[0]?.toLowerCase()!==account.toLowerCase()) {
    stopMining('Wallet changed. Reconnect to continue.');throw new Error('Wallet account or chain changed. Reconnect.');
  }
}
async function transaction(label,fn) {
  if(busy) return;
  try {
    await assertWallet();busy=true;buttons();message(label+' — confirm in your wallet.');
    await fn();message(label+' confirmed.');await refresh();
  } catch(error) {message(errorText(error),true);} finally {busy=false;buttons();}
}
async function sent(tx) {
  message('Transaction submitted. Waiting for confirmation…');
  const link=document.createElement('a');link.href='https://etherscan.io/tx/'+tx.hash;link.target='_blank';link.rel='noopener noreferrer';link.textContent=' View transaction ↗';$('notice').append(link);
  const receipt=await tx.wait();if(receipt.status!==1) throw new Error('Transaction reverted.');return receipt;
}
async function approve(asset,spender,value) {
  await assertWallet();
  if(await asset.allowance(account,spender)<value) await sent(await asset.connect(signer).approve(spender,value));
}
async function deadline() {return BigInt((await provider.getBlock('latest')).timestamp+300);}

async function initialize() {
  [config,abis]=await Promise.all([fetch('config.json').then(r=>r.json()),fetch('abi.json').then(r=>r.json())]);
  if(config.chainId!==1||!config.hook||!isAddress(config.hook)) {buttons();return;}
  provider=config.rpcUrl?new JsonRpcProvider(config.rpcUrl):window.ethereum?new BrowserProvider(window.ethereum):null;
  if(!provider) {message('Connect an Ethereum wallet to read the live pond.');return;}
  await loadContracts();
}
async function loadContracts() {
  if((await provider.getNetwork()).chainId!==1n) throw new Error('Switch your wallet to Ethereum mainnet.');
  if(await provider.getCode(config.hook)==='0x') throw new Error('Configured hook has no deployed code.');
  hook=new Contract(config.hook,abis.HashFrogHook,provider);
  const [f,t,i,s,r,initialized,flags,pool]=await Promise.all([hook.frog(),hook.hfrog(),hook.imd(),hook.staking(),hook.router(),hook.initialized(),hook.FLAGS(),hook.poolKey()]);
  if(!initialized||flags!==0x20ccn||pool.fee!==12500n) throw new Error('Launch pool configuration does not match Hash Frog.');
  frog=new Contract(f,abis.HashFrog,provider);token=new Contract(t,abis.HFROG,provider);imd=new Contract(i,abis.HFROG,provider);staking=new Contract(s,abis.FrogStaking,provider);router=new Contract(r,abis.FrogRouter,provider);
  const [td,id,ts,is]=await Promise.all([token.decimals(),imd.decimals(),token.symbol(),imd.symbol()]);
  if(td!==18n||id!==18n||ts!=='HFROG'||is!=='IMD') throw new Error('Token identities or decimals differ from the reviewed launch.');
  ready=true;show('launch-status','Live on Ethereum');message('The pond is live. Connect your wallet to mine or trade.');
  $('contracts').replaceChildren();
  for(const [name,address] of [['Hook',config.hook],['HFROG',t],['IMD',i],['Frogs & vault',f],['Staking',s],['Router',r]]) {
    const a=document.createElement('a');a.textContent=name+' ↗';a.href='https://etherscan.io/address/'+address;a.target='_blank';a.rel='noopener noreferrer';$('contracts').append(a);
  }
  await refresh();buttons();
}
async function connect() {
  try {
    if(!window.ethereum) throw new Error('An Ethereum wallet is required for transactions.');
    wallet=new BrowserProvider(window.ethereum);await wallet.send('eth_requestAccounts',[]);
    if((await wallet.getNetwork()).chainId!==1n) throw new Error('Switch your wallet to Ethereum mainnet, then reconnect.');
    signer=await wallet.getSigner();account=await signer.getAddress();show('connect',account.slice(0,6)+'…'+account.slice(-4));
    if(config.hook) {if(!provider) provider=wallet;if(!ready) await loadContracts();await refresh();}
    else message('Wallet connected. Mainnet launch addresses have not been published yet.');buttons();
  } catch(error) {message(errorText(error),true);}
}
async function refresh() {
  if(!ready||refreshing) return;refreshing=true;
  try {
    const fa=await frog.getAddress();
    const [head,minted,burned,slots,target,seed,hackEth,teamEth,creditA,creditB,vaultToken,vaultIMD,pending,burnQuote,rewards,claimed,totalStake,lastBuyback]=await Promise.all([
      provider.getBlock('latest'),frog.totalMinted(),frog.totalBurned(),frog.freeSlots(),frog["target()"](),frog.lastSeed(),frog.ethToHackathon(),frog.ethToTeam(),
      frog.ethCredit('0x56e8c9bd511718508f7410aee3e8a693588b38f0'),frog.ethCredit('0x789C9aDDa69a5880fe70eb4FBC8147F2a54B6363'),token.balanceOf(fa),imd.balanceOf(fa),frog.pendingFees(),frog.burnQuote(),staking.totalRewards(),staking.totalClaimed(),staking.totalStaked(),frog.lastBuyback()]);
    state={head,minted,burned,slots:slots[0],target,seed};
    show('minted',minted);show('burned',burned);show('slots',slots[0]);show('next-slot',minted===2000n?'Sold out':slots[0]>0n?'Available now':when(slots[1]));
    show('difficulty',(Number(1n<<256n)/Number(target)).toLocaleString(undefined,{maximumFractionDigits:0}));show('target','TARGET '+toBeHex(target,32));
    show('hack-eth',fmt(hackEth));show('team-eth',fmt(teamEth));show('eth-credit',fmt(creditA+creditB));show('vault-hfrog',fmt(vaultToken));show('vault-imd',fmt(vaultIMD+pending));
    show('burn-share',fmt(burnQuote[0])+' HFROG + '+fmt(burnQuote[1])+' IMD');show('rewards',fmt(rewards));show('claimed',fmt(claimed));show('total-stake',fmt(totalStake));
    show('buyback-status',BigInt(head.timestamp)>=lastBuyback+60n?'Cooldown ready. Buybacks also require the 30-minute price history and a protected quote.':'Next buyback: '+when(lastBuyback+60n));
    if(account) {
      const [position,earned]=await Promise.all([staking.positions(account),staking.earned(account)]);
      show('my-stake',fmt(position.active)+' HFROG');show('my-exit',fmt(position.exiting)+' HFROG');show('exit-time',when(position.unlockAt));show('my-earned',fmt(earned)+' IMD');
    }
    if(mining && (job?.seed!==seed || job?.target!==target.toString() || head.number-Number(job.refBlock)>48)) {
      if(slots[0]===0n||minted===2000n) stopMining('No mint slot is available. Mining stopped.');
      else await startJob();
    }
    if(solution && (job?.seed!==seed || job?.target!==target.toString() || head.number-Number(job.refBlock)>64)) stopMining('Puzzle changed or reference expired. Start mining again.');
    const version=`${minted}/${burned}/${galleryPage}`;
    if(version!==galleryVersion) {galleryVersion=version;await loadGallery();}
  } catch(error) {message('Live refresh failed: '+errorText(error),true);}
  finally {refreshing=false;buttons();}
}
async function loadGallery() {
  const max=Number(state.minted)-galleryPage*12;
  $('gallery-prev').disabled=galleryPage===0;$('gallery-next').disabled=max<=12;
  if(max<1) return;
  const ids=Array.from({length:Math.min(12,max)},(_,i)=>max-i);
  const results=await Promise.all(ids.map(async id=>{
    try {
      const uri=await frog.tokenURI(id);
      if(!uri.startsWith('data:application/json;base64,')) throw new Error('Unexpected metadata encoding');
      const data=JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(uri.split(',')[1]),c=>c.charCodeAt(0))));
      if(!data.image?.startsWith('data:image/svg+xml;base64,')) throw new Error('Unexpected art encoding');
      return {id,data};
    } catch {return {id,data:null};}
  }));
  $('frogs').replaceChildren();
  for(const {id,data} of results) {
    const card=document.createElement('figure');
    if(data) {
      const img=document.createElement('img');img.src=data.image;img.alt=data.name;img.loading='lazy';card.append(img);
      const caption=document.createElement('figcaption');caption.textContent=data.name;card.append(caption);
      const traits=document.createElement('p');traits.className='traits';traits.textContent=data.attributes.filter(a=>a.trait_type!=='Genome').map(a=>a.value).join(' · ');card.append(traits);
    } else {const caption=document.createElement('figcaption');caption.textContent=`Frog #${id} · burned or unavailable`;card.append(caption);}
    $('frogs').append(card);
  }
}
async function startJob() {
  solution=null;job=null;worker?.terminate();
  const block=await provider.getBlock(state.head.number-1);
  if(!mining) return;
  job={id:++jobNumber,account,seed:state.seed,target:state.target.toString(),refBlock:block.number,refHash:block.hash};
  worker=new Worker(new URL('./miner/worker.js',import.meta.url),{type:'module'});
  worker.onmessage=({data})=>{
    if(data.jobId!==job?.id) return;
    if(data.type==='backend') show('backend',data.backend);
    if(data.type==='progress') {
      show('hashrate',Math.round(data.hashrate).toLocaleString()+' H/s');
      const seconds=Number(1n<<256n)/Number(state.target)/data.hashrate;
      show('eta',seconds<60?seconds.toFixed(1)+' sec':seconds<3600?(seconds/60).toFixed(1)+' min':(seconds/3600).toFixed(1)+' hr');
    }
    if(data.type==='solution') {
      if(!validProof(job,data.nonce)) {stopMining('Proof validation failed.');return;}
      solution={...job,nonce:data.nonce};mining=false;show('miner-status','Proof found. Mint now before the puzzle changes.');buttons();
    }
    if(data.type==='error') stopMining(data.message);
  };
  worker.onerror=e=>stopMining('Miner failed: '+e.message);
  worker.postMessage({action:'start',job});show('ref-block',block.number);show('miner-status','Mining your next frog…');buttons();
}

$('connect').onclick=connect;
$('start-mining').onclick=async()=>{if(mining||busy)return;busy=true;buttons();try{await assertWallet();await refresh();if(state.slots===0n) throw new Error('No mint slot is available.');mining=true;buttons();await startJob();}catch(e){stopMining(errorText(e));}finally{busy=false;buttons();}};
$('stop-mining').onclick=()=>stopMining('Mining stopped.');
$('mint').onclick=()=>transaction('Mint',async()=>{
  const proof=solution;if(!proof) throw new Error('Find a proof first.');
  const [seed,target,head]=await Promise.all([frog.lastSeed(),frog["target()"](),provider.getBlock('latest')]);
  const ref=await provider.getBlock(proof.refBlock);
  if(seed!==proof.seed||target.toString()!==proof.target||head.number-proof.refBlock>64||ref.hash!==proof.refHash||account!==proof.account) {stopMining('Proof expired. Start mining again.');throw new Error('The puzzle changed or the proof expired.');}
  await sent(await frog.connect(signer).mine(BigInt(proof.nonce),proof.seed,proof.refBlock,{value:parseEther('0.0019')}));stopMining('Your frog is minted. Welcome to the pond.');
});
$('quote-trade').onclick=async()=>{try{const buy=$('side').value==='buy';const [,out]=await router.quote.staticCall(buy,amount('trade-amount'),0);show('trade-quote','Expected '+fmt(out)+' '+(buy?'HFROG':'IMD')+' · minimum '+fmt(out*(10000n-slippageBps())/10000n));}catch(e){message(errorText(e),true);}};
$('swap').onclick=()=>transaction('Swap',async()=>{
  const buy=$('side').value==='buy',value=amount('trade-amount');await approve(buy?imd:token,await router.getAddress(),value);
  const [,out]=await router.quote.staticCall(buy,value,0);const min=out*(10000n-slippageBps())/10000n;
  await sent(await router.connect(signer).swap(buy,value,min,0,await deadline()));
});
$('burn').onclick=()=>transaction('Permanent frog burn',async()=>{
  const id=$('burn-id').value;if(!/^\d+$/.test(id)||BigInt(id)<1n||BigInt(id)>2000n) throw new Error('Enter a frog ID from 1 to 2,000.');
  if((await frog.ownerOf(id)).toLowerCase()!==account.toLowerCase()) throw new Error('This wallet does not own that frog.');
  await sent(await frog.connect(signer).burn(id));
});
$('buyback').onclick=()=>transaction('Vault buyback',async()=>{
  const value=amount('buyback-amount');if(value>parseEther('100')) throw new Error('Buybacks are capped at 100 IMD.');
  await hook.consult();const [,out]=await router.quote.staticCall(true,value,0);const min=out*9950n/10000n;
  await sent(await frog.connect(signer).buyback(value,min,0,await deadline()));
});
$('stake-button').onclick=()=>transaction('Stake',async()=>{const value=amount('stake-amount');await approve(token,await staking.getAddress(),value);await sent(await staking.connect(signer).stake(value));});
$('request-exit').onclick=()=>transaction('Start unstake delay',async()=>sent(await staking.connect(signer).requestUnstake(amount('stake-amount'))));
$('withdraw-stake').onclick=()=>transaction('Withdraw stake',async()=>sent(await staking.connect(signer).unstake()));
$('claim').onclick=()=>transaction('Claim IMD',async()=>sent(await staking.connect(signer).claim()));
$('flush').onclick=()=>transaction('Forward pending ETH',async()=>sent(await frog.connect(signer).flush()));
$('redeem').onclick=()=>transaction('Redeem team IMD fees',async()=>sent(await hook.connect(signer).redeemFees()));
$('gallery-prev').onclick=async()=>{galleryPage=Math.max(0,galleryPage-1);await loadGallery();};
$('gallery-next').onclick=async()=>{galleryPage++;await loadGallery();};
window.ethereum?.on?.('accountsChanged',()=>{stopMining('Wallet account changed. Reconnect.');account=null;signer=null;show('connect','Reconnect wallet');buttons();});
window.ethereum?.on?.('chainChanged',()=>{stopMining('Network changed. Reconnect on Ethereum.');ready=false;account=null;signer=null;provider=null;wallet=null;show('connect','Reconnect wallet');buttons();});
window.addEventListener('pagehide',()=>worker?.terminate());
initialize().catch(e=>message(errorText(e),true));setInterval(refresh,10000);

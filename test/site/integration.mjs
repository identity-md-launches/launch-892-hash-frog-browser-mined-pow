// Real local PoolManager + production contracts + DOM application + real WASM mining.
// Run after forge build. Uses only an isolated Anvil process with unlocked, unfunded-on-mainnet test accounts.
import fs from 'node:fs';
import net from 'node:net';
import {spawn} from 'node:child_process';
import assert from 'node:assert/strict';
import {parseHTML} from '../../tools/vendor/linkedom.js';
import {JsonRpcProvider,ContractFactory,Contract,concat,keccak256,getCreate2Address,toBeHex,getBytes,parseEther} from '../../site/vendor/ethers.js';
import {paddedInput} from '../../site/miner/common.js';
const listener=net.createServer();await new Promise(r=>listener.listen(0,'127.0.0.1',r));const port=listener.address().port;await new Promise(r=>listener.close(r));
const child=spawn('anvil',['--port',String(port),'--host','127.0.0.1','--chain-id','1','--silent'],{stdio:'ignore'});
let provider;
const originalFetch=globalThis.fetch,originalInterval=globalThis.setInterval;
try {
 const rpc=`http://127.0.0.1:${port}`;
 for(let i=0;i<100;i++) {try {await originalFetch(rpc,{method:'POST',headers:{'content-type':'application/json'},body:'{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}'});break;} catch {await new Promise(r=>setTimeout(r,50));}}
 provider=new JsonRpcProvider(rpc,1,{cacheTimeout:-1});const signer=await provider.getSigner(0);const account=await signer.getAddress();
 function artifact(name,file=name){return JSON.parse(fs.readFileSync(`out/${file}.sol/${name}.json`,'utf8'));}
 async function deploy(name,args=[],file=name) {const a=artifact(name,file);const c=await new ContractFactory(a.abi,a.bytecode.object,signer).deploy(...args);await c.waitForDeployment();return c;}
 const manager=await deploy('PoolManager',[account]);const token=await deploy('HFROG');const imd=await deploy('MockERC20',['IdentityMD','IMD',10n**30n]);const factory=await deploy('Create2Deployer');
 const hookArtifact=artifact('HashFrogHook');const deployTx=await new ContractFactory(hookArtifact.abi,hookArtifact.bytecode.object,signer).getDeployTransaction(await manager.getAddress(),await token.getAddress(),await imd.getAddress(),60);
 const initHash=keccak256(deployTx.data);const factoryAddress=await factory.getAddress();let salt,at;
 for(let i=0;i<200000;i++){salt=toBeHex(i,32);at=getCreate2Address(factoryAddress,salt,initHash);if((BigInt(at)&0x3fffn)===0x20ccn)break;}
 assert.equal(BigInt(at)&0x3fffn,0x20ccn);
 await (await factory.deploy(salt,deployTx.data)).wait();
 const hook=new Contract(at,hookArtifact.abi,signer);const key=await hook.poolKey();
 const pool=[key.currency0,key.currency1,key.fee,key.tickSpacing,key.hooks];await(await manager.initialize(pool,1n<<96n)).wait();
 const lp=await deploy('PoolModifyLiquidityTest',[await manager.getAddress()]);await(await token.approve(await lp.getAddress(),parseEther('10000000'))).wait();await(await imd.approve(await lp.getAddress(),parseEther('10000000'))).wait();
 await(await lp['modifyLiquidity((address,address,uint24,int24,address),(int24,int24,int256,bytes32),bytes)'](pool,[-60000,60000,parseEther('10000000'),toBeHex(0,32)],'0x')).wait();
 const frog=new Contract(await hook.frog(),artifact('HashFrog').abi,signer);const router=new Contract(await hook.router(),artifact('FrogRouter').abi,signer);const staking=new Contract(await hook.staking(),artifact('FrogStaking').abi,signer);
 const head=await provider.getBlock('latest');const ref=await provider.getBlock(head.number-1);
 const job={account,seed:await frog.lastSeed(),target:(await frog["target()"]()).toString(),refHash:ref.hash};
 const {instance}=await WebAssembly.instantiate(fs.readFileSync('site/miner/keccak.wasm'));const memory=new Uint8Array(instance.exports.memory.buffer);
 memory.set(paddedInput(job,toBeHex(0,32)));memory.set(getBytes(toBeHex(BigInt(job.target),32)),160);
 let nonce=-1n;for(let start=0;nonce<0n;start+=1000000)nonce=instance.exports.mine(start,1000000);
 await(await frog.mine(nonce,job.seed,ref.number,{value:parseEther('0.0019')})).wait();assert.equal(await frog.ownerOf(1),account);
 const {document,window}=parseHTML(fs.readFileSync('site/index.html','utf8'));globalThis.document=document;globalThis.window=window;
 window.ethereum={request:async({method,params})=>method==='eth_requestAccounts'?provider.send('eth_accounts',[]):provider.send(method,params||[]),on:()=>{}};
 globalThis.fetch=async(input,...args)=> {
  if(input==='config.json')return{json:async()=>({chainId:1,hook:at,rpcUrl:rpc,deploymentBlock:1})};
  if(input==='abi.json')return{json:async()=>JSON.parse(fs.readFileSync('site/abi.json','utf8'))};
  return originalFetch(input,...args);
 };
 globalThis.setInterval=()=>0;
 await import('../../site/app.js');
 const $=id=>document.getElementById(id);
 async function until(fn){for(let i=0;i<200;i++){if(fn())return;await new Promise(r=>setTimeout(r,30));}throw new Error('Timed out; '+$('notice').textContent);}
 await until(()=>$('minted').textContent==='1');assert.equal($('launch-status').textContent,'Live on Ethereum');
 await until(()=>$('frogs').querySelectorAll('img').length===1);await $('connect').onclick();
 assert.equal($('swap').disabled,false);
 // Linkedom exposes select.value as read-only; select the first option as a real browser would.
 Object.defineProperty($('side'),'value',{value:'buy',writable:true});
 $('trade-amount').value='100';$('slippage').value='0.5';
 await $('quote-trade').onclick();assert.match($('trade-quote').textContent,/Expected/);
 await $('swap').onclick();assert.match($('notice').textContent,/Swap confirmed/);assert.equal(await hook.totalFees(),parseEther('1.5'));
 $('stake-amount').value='10';await $('stake-button').onclick();assert.equal((await staking.positions(account)).active,parseEther('10'));
 $('side').value='sell';$('trade-amount').value='5';await $('swap').onclick();assert.match($('notice').textContent,/Swap confirmed/);
 await $('claim').onclick();assert((await staking.totalClaimed())>0n);
 await $('request-exit').onclick();assert.equal(await staking.totalStaked(),0n);
 await provider.send('evm_increaseTime',[86400]);await provider.send('evm_mine',[]);
 await $('withdraw-stake').onclick();assert.equal((await staking.positions(account)).exiting,0n);
 // The vault's small earned balance is enough for a limited buyback.
 $('buyback-amount').value='0.1';await $('buyback').onclick();assert((await frog.totalBoughtHFROG())>0n,$('notice').textContent);
 $('burn-id').value='1';await $('burn').onclick();assert.equal(await frog.totalBurned(),1n);assert.equal(await token.balanceOf(await frog.getAddress()),0n);
 await $('redeem').onclick();await $('flush').onclick();
 console.log('PASS: local DOM app, wallet connect, tokenURI gallery, buy/sell, approvals, stake/claim/24h exit, buyback, burn, fee redemption, ETH flush and WASM proof mint.');
} finally {
 globalThis.fetch=originalFetch;globalThis.setInterval=originalInterval;provider?.destroy();child.kill('SIGTERM');
}

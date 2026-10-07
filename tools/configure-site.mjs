// Read-only verification. Writes public deployment data; never accepts a wallet/key.
import fs from 'node:fs';
import {JsonRpcProvider,Contract,isAddress} from '../site/vendor/ethers.js';
const [rpc,hookAddress,blockText]=process.argv.slice(2);
if(!rpc||!isAddress(hookAddress)||!/^\d+$/.test(blockText||'')) throw new Error('Usage: node tools/configure-site.mjs PUBLIC_RPC_URL HOOK_ADDRESS DEPLOYMENT_BLOCK');
const url=new URL(rpc);
if(url.username||url.password||url.search||url.hash) throw new Error('Use a public RPC URL without credentials or query parameters. It will be published.');
const provider=new JsonRpcProvider(rpc);
if((await provider.getNetwork()).chainId!==1n) throw new Error('Expected Ethereum mainnet');
const abi=JSON.parse(fs.readFileSync('site/abi.json','utf8'));
const hook=new Contract(hookAddress,abi.HashFrogHook,provider);
if(await provider.getCode(hookAddress)==='0x') throw new Error('Hook not deployed');
const [initialized,flags,key,frog,stake,router,token,imd,manager]=await Promise.all([hook.initialized(),hook.FLAGS(),hook.poolKey(),hook.frog(),hook.staking(),hook.router(),hook.hfrog(),hook.imd(),hook.poolManager()]);
if(!initialized||flags!==0x20ccn||key.fee!==12500n||(BigInt(hookAddress)&0x3fffn)!==flags) throw new Error('Hook/pool mismatch');
for(const address of [frog,stake,router,token,imd,manager]) if(await provider.getCode(address)==='0x') throw new Error('Missing companion code: '+address);
for(const [address,symbol] of [[token,'HFROG'],[imd,'IMD']]) {
 const c=new Contract(address,abi.HFROG,provider);
 if(await c.symbol()!==symbol||await c.decimals()!==18n) throw new Error('Token mismatch: '+address);
}
const nft=new Contract(frog,abi.HashFrog,provider),staking=new Contract(stake,abi.FrogStaking,provider),swap=new Contract(router,abi.FrogRouter,provider);
for(const c of [nft,staking,swap]) {
 if((await c.hook()).toLowerCase()!==hookAddress.toLowerCase() || (await c.poolManager()).toLowerCase()!==manager.toLowerCase()) throw new Error('Companion binding mismatch');
}
if(await nft.PRICE()!==1900000000000000n || await nft.MAX_SUPPLY()!==2000n) throw new Error('NFT policy mismatch');
const tokenC=new Contract(token,abi.HFROG,provider);
if(await tokenC.totalSupply()!==10n**27n) throw new Error('Token supply mismatch');
const block=Number(blockText);
if(!Number.isSafeInteger(block)||!await provider.getBlock(block)) throw new Error('Invalid deployment block');
fs.writeFileSync('site/config.json',JSON.stringify({chainId:1,hook:hookAddress,rpcUrl:rpc,deploymentBlock:block},null,2)+'\n');
console.log('Verified public wiring and wrote site/config.json. Publish site/ over HTTPS after reviewing deployed bytecode.');

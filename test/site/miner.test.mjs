import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {keccak256,toBeHex,toUtf8Bytes,getBytes,hexlify} from '../../site/vendor/ethers.js';
import {packedProof,paddedInput,nonceFromCounter,gpuInput,validProof} from '../../site/miner/common.js';
const bytes=fs.readFileSync(new URL('../../site/miner/keccak.wasm',import.meta.url));
const job={account:'0x00000000000000000000000000000000000a11ce',seed:keccak256(toUtf8Bytes('Hash Frog / a pond begins / genesis v1')),refHash:keccak256(toUtf8Bytes('reference')),target:toBeHex((1n<<236n)-1n,32)};
test('WASM hash matches Ethereum packed proof over 100 different 256-bit nonces',async()=>{
 const {instance}=await WebAssembly.instantiate(bytes);const mem=new Uint8Array(instance.exports.memory.buffer);
 for(let i=0;i<100;i++) {
  const nonce=keccak256(toUtf8Bytes('vector '+i));const input=paddedInput(job,nonce);mem.set(input);instance.exports.hash();
  assert.equal(hexlify(mem.slice(192,224)),keccak256(packedProof(job.account,nonce,job.seed,job.refHash)));
 }
});
test('fixed launch-difficulty proof is found and bound to minter and previous seed',async()=>{
 const {instance}=await WebAssembly.instantiate(bytes);const mem=new Uint8Array(instance.exports.memory.buffer);
 mem.set(paddedInput(job,toBeHex(0,32)));mem.set(getBytes(job.target),160);
 assert.equal(instance.exports.mine(0,729977),-1n);
 assert.equal(instance.exports.mine(729977,1),729977n);
 assert(validProof(job,729977));
 assert(!validProof({...job,account:'0x0000000000000000000000000000000000000b0b'},729977));
 assert(!validProof({...job,seed:toBeHex(0,32)},729977));
});
test('strict target bound, nonce endian convention, and GPU buffer layout',async()=>{
 const {instance}=await WebAssembly.instantiate(bytes);const mem=new Uint8Array(instance.exports.memory.buffer);
 const nonce=nonceFromCounter(toBeHex(0,32),729977);
 assert.equal(BigInt(nonce),729977n);
 mem.set(paddedInput(job,nonce));const digest=keccak256(packedProof(job.account,nonce,job.seed,job.refHash));
 mem.set(getBytes(digest),160);assert.equal(instance.exports.mine(729977,1),-1n);
 mem.set(getBytes(toBeHex(BigInt(digest)+1n,32)),160);assert.equal(instance.exports.mine(729977,1),729977n);
 const words=gpuInput(job,toBeHex(0,32),729977);assert.equal(words[42],729977);assert.equal(words[29],1);assert.equal(words[33],0x80000000);assert.equal(words[34],0x00000fff);assert.equal(words[41],0xffffffff);
});

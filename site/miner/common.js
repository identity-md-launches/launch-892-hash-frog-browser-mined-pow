import { getBytes, hexlify, keccak256, solidityPacked, toBeHex } from '../vendor/ethers.js';

export function packedProof(account, nonce, seed, refHash) {
  return solidityPacked(['address','uint256','bytes32','bytes32'],[account,nonce,seed,refHash]);
}
export function validProof(job, nonce) {
  return BigInt(keccak256(packedProof(job.account,nonce,job.seed,job.refHash))) < BigInt(job.target);
}
export function nonceFromCounter(prefix, counter) {
  const bytes=getBytes(prefix).slice();
  new DataView(bytes.buffer).setUint32(28,counter,false);
  return hexlify(bytes);
}
export function paddedInput(job, prefix) {
  const input=new Uint8Array(136);
  input.set(getBytes(packedProof(job.account,BigInt(prefix),job.seed,job.refHash)));
  input[116]=1; input[135]=128; // Ethereum Keccak, not FIPS SHA3.
  return input;
}
export function gpuInput(job, prefix, start) {
  const words=new Uint32Array(43);
  const bytes=paddedInput(job,prefix);
  const dv=new DataView(bytes.buffer);
  for(let i=0;i<34;i++) words[i]=dv.getUint32(i*4,true);
  const target=new DataView(getBytes(toBeHex(BigInt(job.target),32)).buffer);
  for(let i=0;i<8;i++) words[34+i]=target.getUint32(i*4,false);
  words[42]=start;
  return words;
}

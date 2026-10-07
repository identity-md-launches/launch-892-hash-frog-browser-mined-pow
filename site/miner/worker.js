import {getBytes, hexlify, keccak256, toBeHex} from '../vendor/ethers.js';
import {nonceFromCounter, paddedInput, gpuInput, validProof} from './common.js';
let generation=0;
let wasm, gpu;
let gpuDisabled=false;
const wait=()=>new Promise(resolve=>setTimeout(resolve,0));

async function gpuSetup() {
  if (!navigator.gpu) throw new Error('WebGPU unavailable');
  const adapter=await navigator.gpu.requestAdapter();
  if (!adapter) throw new Error('No GPU adapter');
  const device=await adapter.requestDevice();
  const code=await (await fetch(new URL('./keccak.wgsl',import.meta.url))).text();
  const module=device.createShaderModule({code});
  const info=await module.getCompilationInfo();
  if(info.messages.some(m=>m.type==='error')) throw new Error('GPU shader did not compile');
  const pipeline=await device.createComputePipelineAsync({layout:'auto',compute:{module,entryPoint:'main'}});
  const input=device.createBuffer({size:43*4,usage:GPUBufferUsage.STORAGE|GPUBufferUsage.COPY_DST});
  const output=device.createBuffer({size:4,usage:GPUBufferUsage.STORAGE|GPUBufferUsage.COPY_DST|GPUBufferUsage.COPY_SRC});
  const read=device.createBuffer({size:4,usage:GPUBufferUsage.MAP_READ|GPUBufferUsage.COPY_DST});
  const bind=device.createBindGroup({layout:pipeline.getBindGroupLayout(0),entries:[{binding:0,resource:{buffer:input}},{binding:1,resource:{buffer:output}}]});
  const run=async(job,prefix,start,count)=>{
    device.queue.writeBuffer(input,0,gpuInput(job,prefix,start));
    device.queue.writeBuffer(output,0,new Uint32Array([0xffffffff]));
    const encoder=device.createCommandEncoder();
    const pass=encoder.beginComputePass();pass.setPipeline(pipeline);pass.setBindGroup(0,bind);pass.dispatchWorkgroups(count/64);pass.end();
    encoder.copyBufferToBuffer(output,0,read,0,4);device.queue.submit([encoder.finish()]);
    await read.mapAsync(GPUMapMode.READ);
    const found=new Uint32Array(read.getMappedRange())[0];read.unmap();
    return found===0xffffffff ? -1 : found;
  };
  // Production-difficulty known-answer check before advertising the GPU backend.
  const job={account:'0x00000000000000000000000000000000000a11ce',seed:'0xf5bcb75fd0ca54493e23441242a075cbcecf00b4111d9d2a509623a27cccacf3',refHash:'0x756c9a4f9309d505bbefa8a8c595a4e5964909fc8ae9d0224756478b6586267f',target:toBeHex((1n<<236n)-1n,32)};
  if(await run(job,toBeHex(0,32),729977,64)!==729977) throw new Error('GPU self-test failed');
  return run;
}

async function wasmSetup() {
  const response=await fetch(new URL('./keccak.wasm',import.meta.url));
  if(!response.ok) throw new Error('WASM file unavailable');
  const {instance}=await WebAssembly.instantiate(await response.arrayBuffer());
  return instance.exports;
}

self.onmessage=({data})=>{
  const id=++generation;
  if(data.action==='start') run(data.job,id).catch(error=>{
    if(id===generation) self.postMessage({type:'error',jobId:data.job.id,message:error.message});
  });
};

async function run(job,id) {
  let backend='CPU';
  if(!gpuDisabled) {try {gpu ??= await gpuSetup();backend='WebGPU';} catch { gpu=null;gpuDisabled=true; }}
  if(!gpu) {try {wasm ??= await wasmSetup();backend='WASM / CPU';} catch {wasm=null;}}
  if(id!==generation) return;
  self.postMessage({type:'backend',jobId:job.id,backend});
  let prefix=hexlify(crypto.getRandomValues(new Uint8Array(32)));
  let start=0,total=0;
  const begin=performance.now();
  let report=begin;
  const batch=backend==='CPU'?128:32768;
  if(wasm && !gpu) {
    const mem=new Uint8Array(wasm.memory.buffer);
    mem.set(paddedInput(job,prefix));mem.set(getBytes(toBeHex(BigInt(job.target),32)),160);
    wasm.hash();
    if(hexlify(mem.slice(192,224))!==keccak256(mem.slice(0,116))) throw new Error('WASM self-test failed');
  }
  while(id===generation) {
    let found=-1;
    if(gpu) {
      try {found=await gpu(job,prefix,start,batch);} catch {
        if(id!==generation) return;
        gpu=null;gpuDisabled=true;generation++;return run(job,generation); // Fall back after device loss.
      }
    } else if(wasm) found=Number(wasm.mine(start,batch));
    else for(let i=0;i<batch;i++) {
      if(validProof(job,nonceFromCounter(prefix,start+i))) {found=start+i;break;}
    }
    if(id!==generation) return;
    total+=found>=0 ? found-start+1 : batch;
    const now=performance.now();
    if(now-report>250 || found>=0) {
      self.postMessage({type:'progress',jobId:job.id,hashrate:total/((now-begin)/1000),hashes:total,backend});report=now;
    }
    if(found>=0) {
      const nonce=nonceFromCounter(prefix,found);
      if(!validProof(job,nonce)) throw new Error('Backend produced an invalid proof');
      self.postMessage({type:'solution',jobId:job.id,nonce});return;
    }
    start+=batch;
    if(start+batch>=0xffffffff) {
      prefix=hexlify(crypto.getRandomValues(new Uint8Array(32)));start=0;
      if(wasm&&!gpu) new Uint8Array(wasm.memory.buffer).set(paddedInput(job,prefix));
    }
    await wait();
  }
}

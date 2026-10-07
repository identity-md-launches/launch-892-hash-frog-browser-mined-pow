import wabtFactory from './vendor/wabt.cjs';
import fs from 'node:fs';
const wabt=await wabtFactory();
const module=wabt.parseWat('keccak.wat',fs.readFileSync('site/miner/keccak.wat','utf8'));
module.validate();
fs.writeFileSync('site/miner/keccak.wasm',module.toBinary({}).buffer);
console.log('Built single-block Keccak WASM');

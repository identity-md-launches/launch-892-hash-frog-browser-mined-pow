import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {parseHTML} from '../../tools/vendor/linkedom.js';
test('unconfigured site is honest and disables every fund-moving action',async()=>{
 const html=fs.readFileSync('site/index.html','utf8');const {document,window}=parseHTML(html);
 globalThis.document=document;globalThis.window=window;
 const originalFetch=globalThis.fetch, originalInterval=globalThis.setInterval;
 globalThis.fetch=async path=>({json:async()=>JSON.parse(fs.readFileSync('site/'+path,'utf8'))});
 globalThis.setInterval=()=>0;
 try {
  await import('../../site/app.js');await new Promise(r=>setTimeout(r,30));
  assert.match(document.getElementById('notice').textContent,/ready for launch addresses/);
  for(const button of document.querySelectorAll('.requires-live')) assert(button.disabled,button.id+' should be disabled');
  assert.equal(document.getElementById('minted').textContent,'—');
  await document.getElementById('connect').onclick();
  assert.match(document.getElementById('notice').textContent,/wallet is required/);
  assert.equal(document.querySelectorAll('img[src="pond.svg"]').length,1);
 } finally {globalThis.fetch=originalFetch;globalThis.setInterval=originalInterval;}
});

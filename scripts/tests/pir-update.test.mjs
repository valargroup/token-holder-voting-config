import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {signingBytes,verifyUpdate} from '../verify-pir-update.mjs';
const v=JSON.parse(readFileSync(new URL('./pir-update-vector.json',import.meta.url)));
test('shared signing vector and mutation rejection',()=>{
 assert.equal(signingBytes('prod',v.payload).toString('base64'),v.message_base64);
 assert.equal(verifyUpdate(Buffer.from(v.config),v.attestations,'prod',[v.key]).binary_tag,'v1.2.3');
 assert.throws(()=>verifyUpdate(Buffer.from(v.config+' '),v.attestations,'prod',[v.key]));
 assert.throws(()=>verifyUpdate(Buffer.from(v.config),v.attestations,'stage',[v.key]));
 assert.throws(()=>verifyUpdate(Buffer.from(v.config),v.attestations,'prod',[]));
 for(const field of Object.keys(v.payload)){const a=structuredClone(v.attestations);a.payload[field]='f'.repeat(64);assert.throws(()=>verifyUpdate(Buffer.from(v.config),a,'prod',[v.key]));}
});

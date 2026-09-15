#!/usr/bin/env node
// Independent publication verification; hosts enforce the same authorization themselves.
import {createHash, createPublicKey, verify} from 'node:crypto';
import {readFileSync, existsSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {resolve, dirname} from 'node:path';
const keys = JSON.parse(readFileSync(new URL('./pir-update-keys.json', import.meta.url)));
const hash = data => createHash('sha256').update(data).digest('hex');
export function signingBytes(scope, p) {
  if (!['prod','stage'].includes(scope)) throw Error('invalid signing scope');
  const fields = [p.config_sha256,p.linux_amd64_sha256,p.linux_arm64_sha256,p.snapshot_manifest_sha256,p.service_sha256];
  if (!fields.every(h=>typeof h==='string' && /^[0-9a-f]{64}$/.test(h))) throw Error('invalid SHA-256');
  return Buffer.from(`valargroup/pir-update/v1\n${scope}\n${fields.join('\n')}\n`);
}
function exactFields(object, fields) {
  if (!object || Array.isArray(object) || Object.keys(object).sort().join(',') !== fields.sort().join(',')) throw Error('unexpected metadata fields');
}
export function verifyUpdate(config, att, scope, trusted=keys[scope]) {
  const cfg = JSON.parse(config);
  exactFields(cfg,['schema_version','snapshot_height','binary_tag']);
  exactFields(att,['schema_version','payload','signatures']);
  exactFields(att.payload,['config_sha256','linux_amd64_sha256','linux_arm64_sha256','snapshot_manifest_sha256','service_sha256']);
  if (cfg.schema_version!==1 || !Number.isSafeInteger(cfg.snapshot_height) || cfg.snapshot_height<=0 || cfg.snapshot_height%10!==0 || !/^v[0-9A-Za-z.+-]{1,127}$/.test(cfg.binary_tag)) throw Error('invalid PIR config');
  if (att.schema_version!==1 || att.payload.config_sha256!==hash(config) || !Array.isArray(att.signatures)) throw Error('config/attestation mismatch');
  const message = signingBytes(scope,att.payload);
  const valid = att.signatures.some(s=> {
    exactFields(s,['key_id','alg','sig']);
    if(s.alg!=='ed25519' || typeof s.sig!=='string' || !/^[A-Za-z0-9+/]{86}==$/.test(s.sig)) return false;
    return (trusted||[]).filter(k=>k.key_id===s.key_id).some(k=> {
      const raw=Buffer.from(k.pubkey,'base64'); if(raw.length!==32)return false;
      const pk=createPublicKey({format:'der',type:'spki',key:Buffer.concat([Buffer.from('302a300506032b6570032100','hex'),raw])});
      return verify(null,message,pk,Buffer.from(s.sig,'base64'));
    });
  });
  if(!valid)throw Error('no pinned coordinator signature matches PIR update');
  return cfg;
}
async function main() {
  const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
  for (const scope of ['prod','stage']) {
    const config=readFileSync(resolve(root,scope,'pir.json'));
    const attPath=resolve(root,scope,'pir_attestations.json');
    const cfg=JSON.parse(config);
    // Legacy snapshot-only publication remains available until a coordinator enrolls the environment.
    if(!Object.hasOwn(cfg,'binary_tag') && !existsSync(attPath))continue;
    const att=readFileSync(attPath);if(config.length>65536 || att.length>65536)throw Error('PIR metadata too large');
    const parsed=JSON.parse(att);verifyUpdate(config,parsed,scope);
    if(process.argv.includes('--artifacts')) {
      const github=`https://github.com/valargroup/vote-nullifier-pir/releases/download/${cfg.binary_tag}`;
      // Hash artifact bytes, not an unauthenticated checksum document.
      for(const [name,digest] of [['nf-server-linux-amd64',parsed.payload.linux_amd64_sha256],['nf-server-linux-arm64',parsed.payload.linux_arm64_sha256],['nullifier-query-server.service',parsed.payload.service_sha256]]) {
        const resp=await fetch(`${github}/${name}`,{signal:AbortSignal.timeout(600000)});if(!resp.ok)throw Error('release artifact unavailable');
        const h=createHash('sha256'); let length=0;
        for await(const chunk of resp.body){length+=chunk.length;if(length>1073741824)throw Error('release artifact too large');h.update(chunk);}
        if(h.digest('hex')!==digest)throw Error('release artifact hash mismatch');
      }
      // The manifest hash selects the published snapshot independently of transport.
      let matched=false;
      for(const network of ['main','test']) {
        const resp=await fetch(`https://shielded-vote.nyc3.digitaloceanspaces.com/snapshots/${network}/${cfg.snapshot_height}/manifest.json`,{signal:AbortSignal.timeout(30000)});
        if(resp.ok){const bytes=Buffer.from(await resp.arrayBuffer());if(bytes.length<=1048576 && hash(bytes)===parsed.payload.snapshot_manifest_sha256)matched=true;}
      }
      if(!matched)throw Error('snapshot manifest unavailable or hash mismatch');
    }
    console.log(`${scope}: coordinator authorization verified`);
  }
}
if (process.argv[1] && resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  main().catch(error=>{console.error(error.message);process.exitCode=1;});
}

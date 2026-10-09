import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import { signerMatches } from '../../scripts/license-key-check.mjs';

test('read-only signer check accepts exact pair and rejects another issuer or malformed key', () => {
  const first = generateKeyPairSync('ed25519'), second = generateKeyPairSync('ed25519');
  const pem = first.privateKey.export({format:'pem',type:'pkcs8'});
  const raw = pair => pair.publicKey.export({format:'der',type:'spki'}).subarray(-32).toString('base64');
  assert.equal(signerMatches(pem,raw(first)),true);
  assert.equal(signerMatches(pem.replace(/\n/g,'\\n'),raw(first)),true);
  assert.equal(signerMatches(pem,raw(second)),false);
  assert.equal(signerMatches('',raw(first)),false);
  assert.equal(signerMatches(pem,'invalid'),false);
});

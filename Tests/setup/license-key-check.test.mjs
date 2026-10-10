import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { signerMatches } from '../../scripts/license-key-check.mjs';
import { RELEASE_LICENSE_PUBLIC_KEY_BASE64 } from '../../docs/api/_lib.mjs';

test('backend live-issuer guard stays synchronized with the paid app public key', () => {
  const swift = readFileSync(new URL('../../Sources/ReadAloud/Licensing.swift', import.meta.url),'utf8');
  const embedded = swift.match(/rawRepresentation: Data\(base64Encoded: "([A-Za-z0-9+/=]+)"\)/)?.[1];
  assert.equal(RELEASE_LICENSE_PUBLIC_KEY_BASE64, embedded);
});

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

// Read-only correspondence check. Never creates, persists or prints a private key.
import { createPrivateKey, createPublicKey, timingSafeEqual } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

export function signerMatches(privatePEM, embeddedBase64) {
  try {
    const key = createPrivateKey(privatePEM.replace(/\\n/g, '\n'));
    if (key.asymmetricKeyType !== 'ed25519') return false;
    const raw = createPublicKey(key).export({format:'der',type:'spki'}).subarray(-32);
    const embedded = Buffer.from(embeddedBase64, 'base64');
    return embedded.length === 32 && timingSafeEqual(raw, embedded);
  } catch { return false; }
}

if (import.meta.url === pathToFileURL(process.argv[1] || '').href) {
  const source = readFileSync(new URL('../Sources/ReadAloud/Licensing.swift', import.meta.url), 'utf8');
  const embedded = source.match(/rawRepresentation: Data\(base64Encoded: "([A-Za-z0-9+/=]+)"\)/)?.[1];
  const matches = signerMatches(process.env.LICENSE_SIGNING_KEY || '', embedded || '');
  console.log(matches ? 'Issuer matches the app public key.' : 'Issuer is missing, invalid or does not match the app public key.');
  process.exitCode = matches ? 0 : 1;
}

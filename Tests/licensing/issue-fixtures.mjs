// No network or persisted keys: exercise the real backend issuer with a fresh in-memory key.
import { generateKeyPairSync, sign } from 'node:crypto';
import { licenseFor } from '../../docs/api/_lib.mjs';

const { privateKey, publicKey } = generateKeyPairSync('ed25519');
process.env.LICENSE_SIGNING_KEY = privateKey.export({ type: 'pkcs8', format: 'pem' }).toString();
process.env.STRIPE_SECRET_KEY = 'sk_test_fixture';
process.env.STRIPE_PRICE_ID = 'price_fixture';
process.env.ALOUD_PAYMENT_MODE = 'test';
const baseSession = {
  object: 'checkout.session', id: 'cs_test_fixture123', mode: 'payment', livemode: false,
  payment_status: 'paid', status: 'complete', created: 1_791_504_000,
  customer_details: { email: 'buyer+test@example.com' },
  metadata: { product: 'aloud', price: 'price_fixture' },
  amount_total: 500, currency: 'usd',
};
const test = licenseFor(baseSession);
process.env.ALOUD_PAYMENT_MODE = 'live';
process.env.ALOUD_ENABLE_LIVE_PAYMENTS = 'true';
process.env.VERCEL_ENV = 'production';
process.env.STRIPE_SECRET_KEY = 'sk_live_fixture';
const live = licenseFor({ ...baseSession, id: 'cs_live_fixture123', livemode: true });

function signed(payload) {
  const bytes = Buffer.from(typeof payload === 'string' ? payload : JSON.stringify(payload));
  return `${bytes.toString('base64url')}.${sign(null, bytes, privateKey).toString('base64url')}`;
}
const valid = { product: 'aloud', mode: 'live', email: 'buyer@example.com', id: 'cs_live_fixture123', issued: '2026-10-09' };
const invalid = {
  wrongProduct: signed({ ...valid, product: 'another-app' }),
};
// Explicit object construction keeps every malformed schema signed, distinguishing schema checks
// from signature checks. All fixtures are public test data; the private key stays in this process.
const { mode, ...withoutMode } = valid;
invalid.missingMode = signed(withoutMode);
const { email, ...withoutEmail } = valid;
invalid.missingEmail = signed(withoutEmail);
const { id, ...withoutID } = valid;
invalid.missingID = signed(withoutID);
const { product, ...withoutProduct } = valid;
invalid.missingProduct = signed(withoutProduct);
const { issued, ...withoutIssued } = valid;
invalid.missingIssued = signed(withoutIssued);
invalid.unknownMode = signed({ ...valid, mode: 'preview' });
invalid.numericEmail = signed({ ...valid, email: 7 });
invalid.emptyEmail = signed({ ...valid, email: '' });
invalid.badEmail = signed({ ...valid, email: 'not-an-email' });
invalid.whitespaceEmail = signed({ ...valid, email: 'buyer @example.com' });
invalid.controlEmail = signed({ ...valid, email: 'buyer@example.com\n' });
invalid.htmlEmail = signed({ ...valid, email: 'buyer<@example.com' });
invalid.longEmail = signed({ ...valid, email: `${'x'.repeat(250)}@example.com` });
invalid.emptyID = signed({ ...valid, id: '' });
invalid.numericID = signed({ ...valid, id: 7 });
invalid.modeIDMismatch = signed({ ...valid, id: 'cs_test_fixture123' });
invalid.invalidIssued = signed({ ...valid, issued: '2026-02-30' });
invalid.numericIssued = signed({ ...valid, issued: 7 });
invalid.array = signed([valid]);
invalid.notJSON = signed('not JSON');
invalid.emptyObject = signed({});
invalid.oversized = signed({ ...valid, extra: 'x'.repeat(5_000) });
const testSameSigner = signed({ ...valid, mode: 'test', id: 'cs_test_fixture123' });
const parts = live.split('.');
const changed = JSON.parse(Buffer.from(parts[0], 'base64url').toString());
changed.email = 'other@example.com';
invalid.tamperedPayload = `${Buffer.from(JSON.stringify(changed)).toString('base64url')}.${parts[1]}`;
const signature = Buffer.from(parts[1], 'base64url');
signature[0] ^= 1;
invalid.tamperedSignature = `${parts[0]}.${signature.toString('base64url')}`;
invalid.shortSignature = `${parts[0]}.${Buffer.alloc(63).toString('base64url')}`;
invalid.badBase64 = `${parts[0]}=.${parts[1]}`;
invalid.extraPart = `${live}.extra`;
invalid.emptyPart = `.${parts[1]}`;

console.log(JSON.stringify({
  publicKey: Buffer.from(publicKey.export({ format: 'jwk' }).x, 'base64url').toString('base64'),
  live, test, testSameSigner, invalid,
}));

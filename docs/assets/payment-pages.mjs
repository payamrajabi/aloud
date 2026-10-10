const validLicense = value => typeof value === 'string' && value.length <= 8192 && /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(value);
const activationLink = license => 'aloud://activate?license=' + encodeURIComponent(license);
const show = (document, id) => ['waiting', 'done', 'problem'].forEach(s => { document.getElementById(s).hidden = s !== id; });

export async function initThanksPage({ document, location, history, fetcher = fetch, later = setTimeout }) {
  const sessionId = new URLSearchParams(location.search).get('session_id') || '';
  let tries = 0;
  async function check() {
    try {
      if (!/^cs_(test|live)_[A-Za-z0-9]+$/.test(sessionId)) throw new Error('This link is missing its checkout reference.');
      const res = await fetcher('/api/license?session_id=' + encodeURIComponent(sessionId), { cache: 'no-store' });
      const data = await res.json();
      if (res.status === 202) {
        if (tries++ < 20) return later(check, 3000);
        throw new Error('Your payment is still processing. Come back to this link later, or contact support.');
      }
      if (!res.ok || !validLicense(data.license) || !['live', 'test'].includes(data.mode)) throw new Error(data.error || 'We could not confirm this purchase yet.');
      const open = document.getElementById('open');
      document.getElementById('key').textContent = data.license;
      document.getElementById('email').textContent = data.email || 'your purchase email';
      show(document, 'done');
      history?.replaceState(null, '', location.pathname);
      if (data.mode === 'test') {
        document.getElementById('title').textContent = 'Test purchase complete';
        document.getElementById('delivery').textContent = 'No money was charged. This test license does not unlock the installed app.';
        document.getElementById('instructions').hidden = true;
        document.getElementById('download-tip').hidden = true;
        open.hidden = true;
        return;
      }
      open.href = activationLink(data.license);
      location.href = open.href;
    } catch (error) {
      document.getElementById('reason').textContent = error.message;
      show(document, 'problem');
    }
  }
  return check();
}

export function initActivationPage({ document, location, history }) {
  // Fragments never reach server logs; remove them from the current history entry after reading.
  const license = location.hash.slice(1);
  history?.replaceState(null, '', location.pathname);
  let payload;
  try {
    if (!validLicense(license)) throw new Error('Invalid license');
    const encoded = license.split('.')[0].replace(/-/g, '+').replace(/_/g, '/');
    payload = JSON.parse(atob(encoded));
  } catch { /* the Mac verifies the cryptographic signature, this page only parses the mode */ }
  if (payload?.product !== 'aloud' || payload?.mode !== 'live') {
    document.getElementById('missing').hidden = false;
    return;
  }
  const link = activationLink(license);
  document.getElementById('open').href = link;
  document.getElementById('key').textContent = license;
  document.getElementById('ready').hidden = false;
  location.href = link;
}

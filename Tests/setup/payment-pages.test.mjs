import test from 'node:test';
import assert from 'node:assert/strict';
import { initThanksPage, initActivationPage } from '../../docs/assets/payment-pages.mjs';
const license = mode => Buffer.from(JSON.stringify({product:'aloud',mode})).toString('base64url') + '.signature';
function context(search = '?session_id=cs_test_example') {
  const nodes = Object.fromEntries(['waiting','done','problem','reason','open','key','email','title','delivery','instructions','download-tip','missing','ready'].map(id => [id,{hidden:true,textContent:'',href:''}]));
  return { nodes, document:{ getElementById:id=>nodes[id] }, location:{search,pathname:'/thanks',hash:'',href:'unchanged'}, history:{replaceState(){}} };
}
test('sandbox success shows license but never opens the installed app', async () => {
  const c = context();
  await initThanksPage({...c,fetcher:async()=>Response.json({license:license('test'),mode:'test',email:'buyer@example.test'})});
  assert.equal(c.nodes.done.hidden,false); assert.equal(c.nodes.open.hidden,true);
  assert.equal(c.location.href,'unchanged'); assert.match(c.nodes.delivery.textContent,/No money was charged/);
});
test('live success creates only the app activation scheme and sets text safely', async () => {
  const c = context('?session_id=cs_live_example');
  await initThanksPage({...c,fetcher:async()=>Response.json({license:license('live'),mode:'live',email:'<script>test</script>'})});
  assert.match(c.location.href,/^aloud:\/\/activate\?license=/);
  assert.equal(c.nodes.email.textContent,'<script>test</script>');
});
test('invalid checkout fails without contacting any endpoint', async () => {
  const c = context('?session_id=invalid');
  await initThanksPage({...c,fetcher:()=>assert.fail('network call')});
  assert.equal(c.nodes.problem.hidden,false); assert.equal(c.location.href,'unchanged');
});
test('pending payments never unlock and stop polling with a useful message', async () => {
  const c = context(); let scheduled;
  const input = {...c,fetcher:async()=>Response.json({pending:true,mode:'test'},{status:202}),later:fn=>{scheduled=fn}};
  await initThanksPage(input);
  for(let n=0;n<20;n++) await scheduled();
  assert.equal(c.nodes.problem.hidden,false); assert.match(c.nodes.reason.textContent,/still processing/);
  assert.equal(c.location.href,'unchanged');
});
test('activation page rejects test, malformed and HTML-shaped license links', () => {
  for(const value of [license('test'),'bad','<script>evil</script>']) {
    const c=context();c.location.hash='#'+value;initActivationPage(c);
    assert.equal(c.nodes.missing.hidden,false);assert.equal(c.location.href,'unchanged');
  }
});

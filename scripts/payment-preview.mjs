// Local UI simulation only. No Stripe calls, emails, account changes or production licenses.
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve, extname, sep } from 'node:path';
import { generateKeyPairSync, sign } from 'node:crypto';
const docs = fileURLToPath(new URL('../docs/', import.meta.url));
const { privateKey } = generateKeyPairSync('ed25519');
const payload = Buffer.from(JSON.stringify({product:'aloud',mode:'test',email:'preview@example.test',id:'cs_test_preview',issued:'2026-10-09'}));
const license = payload.toString('base64url') + '.' + sign(null,payload,privateKey).toString('base64url');
const server = createServer(async (req,res) => {
  const url = new URL(req.url,'http://127.0.0.1');
  res.setHeader('Cache-Control','no-store');
  res.setHeader('Referrer-Policy','no-referrer');
  if(url.pathname==='/api/license') {
    res.setHeader('Content-Type','application/json');
    if(url.searchParams.get('session_id')==='cs_test_pending') {res.statusCode=202;res.end(JSON.stringify({pending:true,mode:'test'}));return;}
    if(url.searchParams.get('session_id')!=='cs_test_preview') {res.statusCode=400;res.end(JSON.stringify({error:'This is a local simulation. Use cs_test_preview.'}));return;}
    res.end(JSON.stringify({license,email:'preview@example.test',mode:'test'}));return;
  }
  if(url.pathname.startsWith('/api/') || url.pathname==='/buy') {res.statusCode=503;res.end('Local simulation: payments and email are disabled.');return;}
  try {
    let path = decodeURIComponent(url.pathname);
    if(path==='/')path='/index.html';
    if(!extname(path))path+='.html';
    const file=resolve(docs,'.'+path);
    if(!file.startsWith(resolve(docs)+sep)||path.split('/').some(p=>p.startsWith('.')))throw new Error('Invalid path');
    res.setHeader('Content-Type',({'.html':'text/html; charset=utf-8','.mjs':'text/javascript; charset=utf-8','.svg':'image/svg+xml','.png':'image/png'})[extname(file)]||'application/octet-stream');
    res.end(await readFile(file));
  }catch{res.statusCode=404;res.end('Not found');}
});
server.listen(Number(process.env.PAYMENT_PREVIEW_PORT||8784),'127.0.0.1',()=>console.log('Local simulation: http://127.0.0.1:8784/thanks?session_id=cs_test_preview (no real payment)'));

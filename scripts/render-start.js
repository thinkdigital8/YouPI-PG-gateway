/**
 * Single-host entrypoint for platforms that expose one public port (Render free tier).
 *
 * Boots the normal production gateway (scripts/start.js), then listens on $PORT and routes:
 *   /admin, merchant-admin APIs  -> Merchant Admin (6001)
 *   everything else              -> Demo Store (5000), which already proxies
 *                                   /checkout/*, /icons/*, /youpi.js and /api/v1/* to the
 *                                   checkout portal and payment API.
 */
import http from 'node:http';

const publicUrl = (process.env.PUBLIC_BASE_URL || process.env.RENDER_EXTERNAL_URL || '').trim().replace(/\/+$/, '');
if (!publicUrl) {
  console.error('[render-start] PUBLIC_BASE_URL (or RENDER_EXTERNAL_URL) is required.');
  process.exit(1);
}
const publicHost = new URL(publicUrl).host;

process.env.PUBLIC_BASE_URL = publicUrl;
process.env.CLOUDFLARE_DOMAIN ||= publicHost;
process.env.BASE_PAYMENT_API_URL ||= 'http://127.0.0.1:6100';
process.env.BASE_CHECKOUT_URL ||= publicUrl;
process.env.COIN_STORE_PUBLIC_URL ||= publicUrl;

const ADMIN_PORT = Number(process.env.MERCHANT_ADMIN_PORT || 6001);
const STORE_PORT = Number(process.env.COIN_STORE_PORT || 5000);

function targetFor(pathname) {
  if (pathname === '/admin' || pathname.startsWith('/admin/')) return { port: ADMIN_PORT, path: '/admin' };
  if (pathname.startsWith('/api/v1/admin/') || pathname.startsWith('/api/services') ||
      pathname === '/api/logs/stream' || pathname === '/api/admin/tickets' ||
      pathname === '/youpi-sms-gateway.apk') {
    return { port: ADMIN_PORT };
  }
  return { port: STORE_PORT };
}

await import('./start.js');

const router = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const target = targetFor(url.pathname);
  const proxyReq = http.request({
    hostname: '127.0.0.1',
    port: target.port,
    path: target.path ? target.path + url.search : req.url,
    method: req.method,
    headers: {
      ...req.headers,
      'x-forwarded-host': req.headers.host || publicHost,
      'x-forwarded-proto': req.headers['x-forwarded-proto'] || 'https'
    }
  }, (proxyRes) => {
    res.writeHead(proxyRes.statusCode, proxyRes.headers);
    proxyRes.pipe(res);
  });
  proxyReq.on('error', (err) => {
    if (!res.headersSent) res.writeHead(502, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Service unavailable', details: err.message }));
  });
  req.pipe(proxyReq);
});

const port = Number(process.env.PORT || 10000);
router.listen(port, '0.0.0.0', () => {
  console.log(`[render-start] Public router on :${port} -> ${publicUrl} (admin at ${publicUrl}/admin)`);
});

(() => {
  'use strict';
  // Remove preferences and cookies left by the previous Google Analytics setup.
  try { localStorage.removeItem('chimpread-analytics-consent'); } catch (_) {}
  for (const cookie of document.cookie.split(';')) {
    const name = cookie.trim().split('=')[0];
    if (!/^_ga(?:_|$)/.test(name)) continue;
    for (const domain of ['', location.hostname, '.' + location.hostname]) {
      document.cookie = name + '=; Max-Age=0; path=/; SameSite=Lax' + (domain ? '; domain=' + domain : '');
    }
  }
  if (location.hostname !== 'chimpread.com') return;
  const script = document.createElement('script');
  script.type = 'module';
  script.src = 'https://static.cloudflareinsights.com/beacon.min.js';
  script.dataset.cfBeacon = JSON.stringify({ token: '78d1d374244b43f681640aa8de41b93c' });
  document.body.append(script);
})();

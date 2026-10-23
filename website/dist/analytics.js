(() => {
  'use strict';
  const id = 'G-T14T1H4QKJ';
  const key = 'chimpread-analytics-consent';
  const production = location.hostname === 'chimpread.com';
  let consent = null;
  let loaded = false;
  try { consent = localStorage.getItem(key); } catch (_) {}
  window.dataLayer = window.dataLayer || [];
  function gtag() { window.dataLayer.push(arguments); }
  gtag('consent', 'default', { analytics_storage: 'denied', ad_storage: 'denied', ad_user_data: 'denied', ad_personalization: 'denied' });
  function enable() {
    if (loaded || !production) return;
    loaded = true;
    window['ga-disable-' + id] = false;
    gtag('consent', 'update', { analytics_storage: 'granted' });
    gtag('js', new Date());
    gtag('config', id, { allow_google_signals: false, allow_ad_personalization_signals: false, cookie_expires: 15552000, page_location: location.origin + location.pathname });
    const script = document.createElement('script');
    script.async = true;
    script.src = 'https://www.googletagmanager.com/gtag/js?id=' + id;
    document.head.append(script);
  }
  const panel = document.createElement('section');
  panel.className = 'analytics-choice';
  panel.setAttribute('aria-label', 'Analytics preferences');
  panel.innerHTML = '<p>Allow Google Analytics? <a href="/privacy">Privacy</a></p><div><button type="button" data-choice="denied">No thanks</button><button type="button" data-choice="granted">Allow</button></div>';
  panel.hidden = consent === 'granted' || consent === 'denied';
  document.body.append(panel);
  panel.addEventListener('click', event => {
    const button = event.target.closest('[data-choice]');
    if (!button) return;
    consent = button.dataset.choice;
    try { localStorage.setItem(key, consent); } catch (_) {}
    panel.hidden = true;
    if (consent === 'granted') enable();
    else {
      window['ga-disable-' + id] = true;
      for (const cookie of document.cookie.split(';')) {
        const name = cookie.trim().split('=')[0];
        if (!/^_ga(?:_|$)/.test(name)) continue;
        for (const domain of ['', location.hostname, '.' + location.hostname]) {
          document.cookie = name + '=; Max-Age=0; path=/; SameSite=Lax' + (domain ? '; domain=' + domain : '');
        }
      }
      if (loaded) location.reload();
    }
    document.querySelector('[data-analytics-settings]')?.focus();
  });
  document.querySelectorAll('[data-analytics-settings]').forEach(button => button.addEventListener('click', () => {
    panel.hidden = false;
    panel.querySelector('button').focus();
  }));
  document.querySelectorAll('a.download').forEach(link => link.addEventListener('click', () => {
    if (consent === 'granted' && loaded) gtag('event', 'download_click', { file_name: link.href.split('/').pop(), link_url: link.href, transport_type: 'beacon' });
  }));
  if (consent === 'granted') enable();
})();

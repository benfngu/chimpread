document.getElementById('id').textContent=chrome.runtime.id;
document.getElementById('oauth').textContent=chrome.runtime.getManifest().oauth2?.client_id?'OAuth client configured.':'Google Docs OAuth is not configured yet.';
document.getElementById('disconnect').onclick=async()=>{
  await chrome.identity.clearAllCachedAuthTokens();
  document.getElementById('status').textContent='Cached authorization cleared. To revoke the Google grant completely, remove this app in your Google Account → Third-party connections.';
};

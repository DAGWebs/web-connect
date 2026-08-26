(function () {
  'use strict';

  // A site that refuses framing never fires load, and its error is not visible
  // cross-origin. If nothing has loaded by the time this elapses, offer the link.
  var LOAD_GRACE_MS = 6000;

  var shell = document.getElementById('shell');
  var frame = document.getElementById('frame');
  var title = document.getElementById('title');
  var fallback = document.getElementById('fallback');
  var fallbackUrl = document.getElementById('fallback-url');
  var currentUrl = '';
  var loadTimer = null;

  function post(name, body) {
    var target = 'https://' + (window.GetParentResourceName ? GetParentResourceName() : 'web-connect');
    return fetch(target + '/' + name, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify(body || {})
    }).catch(function () { /* the game is gone; nothing useful to do */ });
  }

  function clearTimer() {
    if (loadTimer !== null) {
      window.clearTimeout(loadTimer);
      loadTimer = null;
    }
  }

  function open(payload) {
    currentUrl = payload.url;
    title.textContent = payload.title || 'Website';
    fallbackUrl.textContent = currentUrl;
    fallback.hidden = true;
    shell.hidden = false;
    frame.src = currentUrl;

    clearTimer();
    loadTimer = window.setTimeout(function () {
      fallback.hidden = false;
    }, LOAD_GRACE_MS);
  }

  function close() {
    clearTimer();
    shell.hidden = true;
    // Dropping the src stops audio and background work while the overlay is down.
    frame.src = 'about:blank';
  }

  function copyLink(button) {
    var restore = button.textContent;
    var done = function (message) {
      button.textContent = message;
      window.setTimeout(function () { button.textContent = restore; }, 1500);
    };

    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(currentUrl).then(function () { done('Copied'); },
        function () { done('Press Ctrl+C'); });
      return;
    }

    var scratch = document.createElement('textarea');
    scratch.value = currentUrl;
    document.body.appendChild(scratch);
    scratch.select();
    try {
      done(document.execCommand('copy') ? 'Copied' : 'Press Ctrl+C');
    } catch (error) {
      done('Press Ctrl+C');
    }
    document.body.removeChild(scratch);
  }

  frame.addEventListener('load', function () {
    // about:blank fires load too; only a real navigation clears the warning.
    if (frame.src && frame.src !== 'about:blank') {
      clearTimer();
      fallback.hidden = true;
    }
  });

  document.getElementById('close').addEventListener('click', function () {
    close();
    post('close');
  });

  document.getElementById('copy').addEventListener('click', function (event) {
    copyLink(event.currentTarget);
  });
  document.getElementById('fallback-copy').addEventListener('click', function (event) {
    copyLink(event.currentTarget);
  });

  document.addEventListener('keyup', function (event) {
    if (event.key === 'Escape' && !shell.hidden) {
      close();
      post('close');
    }
  });

  window.addEventListener('message', function (event) {
    var payload = event.data || {};
    if (payload.action === 'open' && typeof payload.url === 'string') open(payload);
    else if (payload.action === 'close') close();
  });
}());

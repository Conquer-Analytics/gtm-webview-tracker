___INFO___

{
  "type": "MACRO",
  "id": "cvt_temp_public_id",
  "version": 1,
  "securityGroups": [],
  "displayName": "In-App Browser Detector",
  "categories": [
    "ANALYTICS",
    "UTILITY"
  ],
  "description": "Classifies in-app (webview) browsers from the User-Agent. Returns one of: a ≤100-char User-Agent tail (custom-dimension-safe), an is-in-app boolean, a normalized app name (facebook, instagram, tiktok, …), or the matched token. Create one variable instance per output and map each to a GA4 event parameter / custom dimension.",
  "containerContexts": [
    "WEB"
  ]
}


___TEMPLATE_PARAMETERS___

[
  {
    "type": "TEXT",
    "name": "userAgent",
    "displayName": "User-Agent",
    "simpleValueType": true,
    "valueHint": "{{User Agent}}",
    "help": "Pass the User-Agent string in. GTM's sandboxed templates cannot read `navigator` directly, so supply it as a variable: create a GTM **JavaScript Variable** (not *Custom* JavaScript) whose value is `navigator.userAgent`, then reference it here — e.g. `{{User Agent}}`."
  },
  {
    "type": "SELECT",
    "name": "output",
    "displayName": "What should this variable return?",
    "macrosInSelect": false,
    "selectItems": [
      {
        "value": "is_inapp",
        "displayValue": "Is in-app browser (boolean)"
      },
      {
        "value": "app_name",
        "displayValue": "App name (facebook, instagram, tiktok, …)"
      },
      {
        "value": "token",
        "displayValue": "Matched token (granular signal)"
      },
      {
        "value": "ua_tail",
        "displayValue": "User-Agent tail (≤100 chars, custom-dimension-safe)"
      },
      {
        "value": "all",
        "displayValue": "All fields as an object (advanced)"
      }
    ],
    "simpleValueType": true,
    "defaultValue": "is_inapp",
    "help": "Each variable instance returns a single value. To populate several GA4 custom dimensions, create one instance per field (e.g. “Webview - is_inapp”, “Webview - app_name”)."
  }
]


___SANDBOXED_JS_FOR_WEB_TEMPLATE___


// ---------------------------------------------------------------------------
// Detection table. First match wins, so the most specific markers must come
// before the generic ones. To support a newly-spotted app, add one row here.
//
//   match   - substring searched for in the raw User-Agent (case-sensitive)
//   app     - canonical app name returned by the "app_name" output
//   token   - value returned by the "token" output
//   extract - (optional) a key whose value is pulled out of the UA and used as
//             the token instead of the static `token` field
//
// Sandboxed JS has no RegExp, so detection is plain indexOf substring matching.
// ---------------------------------------------------------------------------
const APPS = [
  // Meta family. iOS appends a bracketed [FBAN/...;FBAV/...] block; Android
  // uses an [FB_IAB/...] block. Messenger and Threads ride inside the same
  // token family, so they must be matched before the generic Facebook rows.
  { match: 'FBAN/MessengerForiOS', app: 'messenger', token: 'MessengerForiOS' },
  { match: 'MessengerLiteForiOS', app: 'messenger', token: 'MessengerLiteForiOS' },
  { match: 'FB_IAB/Orca-Android', app: 'messenger', token: 'Orca-Android' },
  { match: 'Barcelona', app: 'threads', token: 'Barcelona' },
  { match: 'Instagram', app: 'instagram', token: 'Instagram' },
  { match: 'FBAN/', app: 'facebook', extract: 'FBAN/' },
  { match: 'FB_IAB/', app: 'facebook', extract: 'FB_IAB/' },
  { match: 'FBAV/', app: 'facebook', token: 'facebook' },

  // TikTok / ByteDance. inapp-spy keys on `musical_ly|Bytedance`; the first two
  // rows below are curated-backed. Trill (TikTok intl) and aweme (CN) are extra
  // legacy/region names seen in the wild but not in inapp-spy.
  { match: 'BytedanceWebview', app: 'tiktok', token: 'BytedanceWebview' },
  { match: 'musical_ly', app: 'tiktok', token: 'musical_ly' },
  { match: 'Trill/', app: 'tiktok', token: 'Trill' },
  { match: 'aweme', app: 'tiktok', token: 'aweme' },

  // --- Verified against the inapp-spy / detect-inapp curated lists ---
  { match: 'Snapchat', app: 'snapchat', token: 'Snapchat' },
  { match: 'LinkedInApp', app: 'linkedin', token: 'LinkedInApp' },
  { match: 'MicroMessenger', app: 'wechat', token: 'MicroMessenger' },
  { match: 'Line/', app: 'line', token: 'Line' },
  { match: 'Twitter', app: 'twitter', token: 'Twitter' },
  { match: 'GSA/', app: 'googleapp', token: 'GSA' },
  { match: 'WAiOS/', app: 'whatsapp', token: 'WAiOS' },
  { match: 'WA4A/', app: 'whatsapp', token: 'WA4A' },

  // --- Beyond the curated lists: plausible and seen in the wild, but NOT in
  // inapp-spy. Lower confidence -- verify against real UAs before trusting.
  // (Telegram in particular is detected client-side, not by UA, upstream.) ---
  { match: 'Pinterest', app: 'pinterest', token: 'Pinterest' },
  { match: 'Reddit', app: 'reddit', token: 'Reddit' },
  { match: 'KAKAOTALK', app: 'kakaotalk', token: 'KAKAOTALK' },
  { match: 'Telegram', app: 'telegram', token: 'Telegram' }
];

// Pull the value following `key` up to the next UA delimiter. Used to read
// Meta's FBAN / FB_IAB app code (e.g. "FBAN/FBIOS" -> "FBIOS").
function extractValue(ua, key) {
  const start = ua.indexOf(key);
  if (start === -1) {
    return undefined;
  }
  let i = start + key.length;
  let out = '';
  while (i < ua.length) {
    const c = ua.charAt(i);
    if (c === ';' || c === ']' || c === ' ' || c === '/' || c === ')') {
      break;
    }
    out = out + c;
    i = i + 1;
  }
  return out.length > 0 ? out : undefined;
}

function isIosWebKit(ua) {
  const isApple =
    ua.indexOf('iPhone') > -1 ||
    ua.indexOf('iPad') > -1 ||
    ua.indexOf('iPod') > -1;
  return isApple && ua.indexOf('AppleWebKit') > -1 && ua.indexOf('Mobile/') > -1;
}

function classify(ua) {
  const empty = { isInApp: false, app: undefined, token: undefined };
  if (!ua) {
    return empty;
  }

  for (let i = 0; i < APPS.length; i = i + 1) {
    const def = APPS[i];
    if (ua.indexOf(def.match) > -1) {
      let token = def.token;
      if (def.extract) {
        token = extractValue(ua, def.extract);
      }
      return { isInApp: true, app: def.app, token: token };
    }
  }

  // Generic in-app detection below. These flag is_inapp = true with a GENERIC
  // app_name bucket (the specific app is unknown). "app_name is one of these
  // generic buckets" is the discovery signal -- pivot on ua_tail to spot
  // new/missed tokens and add a row to the table above. The `token` field tells
  // the generic buckets apart by detection method.

  // Generic Android System WebView: the "; wv" flag inside the platform block.
  if (ua.indexOf('; wv') > -1) {
    return { isInApp: true, app: 'android_webview', token: 'wv' };
  }

  // Generic literal "WebView" token, used by assorted in-app browsers on both
  // platforms. Part of inapp-spy's generic fallback set.
  if (ua.indexOf('WebView') > -1) {
    return { isInApp: true, app: 'webview', token: 'WebView' };
  }

  // iOS WKWebView heuristic: an iOS WebKit UA missing the "Safari" token that
  // real Mobile Safari always carries. Imperfect -- an unknown iOS in-app
  // browser that appends no vendor token is indistinguishable from Safari, so
  // this only catches the subset that drop the Safari token. Expect iOS false
  // negatives on unknown apps.
  if (isIosWebKit(ua) && ua.indexOf('Safari') === -1) {
    return { isInApp: true, app: 'ios_webview', token: 'no-safari-token' };
  }

  return empty;
}

// ---------------------------------------------------------------------------
// ua_tail: a <=100-char, custom-dimension-safe slice of the User-Agent.
//
// GA4 truncates text event-param values to 100 chars at INGESTION, head-first,
// so a full UA reaches BigQuery (via the normal GA4 -> BQ export) as 100 chars
// of identical boilerplate -- the signal at the end is gone. We keep the tail
// instead. Apps append their vendor block after the last standard landmark
// (Mobile/<build> on iOS, Safari/<version> on Android), so we return whatever
// follows that landmark's own version token. For everything else -- desktop,
// regular mobile web, or any UA with no appended block -- we fall back to the
// last 100 chars of the full string. Either way the result is capped at 100,
// keeping the rightmost (highest-signal) end.
// ---------------------------------------------------------------------------
function cap100(s) {
  return s.length > 100 ? s.substring(s.length - 100) : s;
}

function uaTail(s) {
  const landmarks = ['Mobile/', 'Safari/'];
  for (let i = 0; i < landmarks.length; i = i + 1) {
    const at = s.lastIndexOf(landmarks[i]);
    if (at === -1) {
      continue;
    }
    // Skip the landmark's own version token (up to the next space); whatever
    // remains is the appended vendor/app block.
    const rest = s.substring(at + landmarks[i].length);
    const sp = rest.indexOf(' ');
    if (sp !== -1) {
      const tail = rest.substring(sp + 1);
      if (tail.length > 0) {
        return cap100(tail);
      }
    }
  }
  // No appended block (desktop / regular web): keep the last 100 chars.
  return cap100(s);
}

const ua = data.userAgent || '';
const output = data.output;

if (output === 'ua_tail') {
  return uaTail(ua);
}

const result = classify(ua);

if (output === 'app_name') {
  return result.app;
}
if (output === 'token') {
  return result.token;
}
if (output === 'all') {
  return {
    raw_ua: ua,
    ua_tail: uaTail(ua),
    is_inapp: result.isInApp,
    app_name: result.app,
    token: result.token
  };
}

// Default: is_inapp boolean.
return result.isInApp;


___WEB_PERMISSIONS___

[]


___TESTS___

scenarios:
- name: Facebook iOS - app name, extracted token, boolean
  code: |-
    const ua = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [FBAN/FBIOS;FBAV/466.0.0.0.0;FBDV/iPhone14,2;FBSN/iOS;FBSV/17.5;FBSS/3;FBID/phone;FBLC/en_US]';
    assertThat(runCode({output: 'app_name', userAgent: ua})).isEqualTo('facebook');
    assertThat(runCode({output: 'token', userAgent: ua})).isEqualTo('FBIOS');
    assertThat(runCode({output: 'is_inapp', userAgent: ua})).isEqualTo(true);
- name: Facebook Android - extracts FB_IAB token, ignores generic wv
  code: |-
    const ua = 'Mozilla/5.0 (Linux; Android 14; SM-S911B Build/UP1A; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/124.0.0.0 Mobile Safari/537.36 [FB_IAB/FB4A;FBAV/466.0.0.0.0;]';
    assertThat(runCode({output: 'app_name', userAgent: ua})).isEqualTo('facebook');
    assertThat(runCode({output: 'token', userAgent: ua})).isEqualTo('FB4A');
- name: Instagram iOS
  code: |-
    const ua = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Instagram 333.0.0.31.94 (iPhone14,2; iOS 17_5; en_US; en-US; scale=3.00; 1170x2532; 000000000)';
    assertThat(runCode({output: 'app_name', userAgent: ua})).isEqualTo('instagram');
    assertThat(runCode({output: 'is_inapp', userAgent: ua})).isEqualTo(true);
- name: TikTok Android - specific token beats generic wv
  code: |-
    const ua = 'Mozilla/5.0 (Linux; Android 14; SM-S911B; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/124.0.0.0 Mobile Safari/537.36 BytedanceWebview/d8a21c6 musical_ly_2022803040';
    assertThat(runCode({output: 'app_name', userAgent: ua})).isEqualTo('tiktok');
    assertThat(runCode({output: 'token', userAgent: ua})).isEqualTo('BytedanceWebview');
- name: Generic Android WebView - in-app true, generic app_name bucket
  code: |-
    const ua = 'Mozilla/5.0 (Linux; Android 14; SM-S911B; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/124.0.0.0 Mobile Safari/537.36';
    assertThat(runCode({output: 'is_inapp', userAgent: ua})).isEqualTo(true);
    assertThat(runCode({output: 'app_name', userAgent: ua})).isEqualTo('android_webview');
    assertThat(runCode({output: 'token', userAgent: ua})).isEqualTo('wv');
- name: iOS WKWebView heuristic - in-app true, generic app_name bucket
  code: |-
    const ua = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148';
    assertThat(runCode({output: 'is_inapp', userAgent: ua})).isEqualTo(true);
    assertThat(runCode({output: 'app_name', userAgent: ua})).isEqualTo('ios_webview');
    assertThat(runCode({output: 'token', userAgent: ua})).isEqualTo('no-safari-token');
- name: Real Mobile Safari is not in-app
  code: |-
    const ua = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1';
    assertThat(runCode({output: 'is_inapp', userAgent: ua})).isEqualTo(false);
    assertThat(runCode({output: 'app_name', userAgent: ua})).isEqualTo(undefined);
- name: Desktop Chrome is not in-app
  code: |-
    const ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
    assertThat(runCode({output: 'is_inapp', userAgent: ua})).isEqualTo(false);
- name: ua_tail - short UA passes through unchanged
  code: |-
    const ua = 'Mozilla/5.0 some-test-agent';
    assertThat(runCode({output: 'ua_tail', userAgent: ua})).isEqualTo('Mozilla/5.0 some-test-agent');
- name: ua_tail - iOS in-app returns the appended vendor block (after the Mobile build)
  code: |-
    const ua = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [FBAN/FBIOS;FBAV/466.0.0.0.0;FBDV/iPhone14,2]';
    assertThat(runCode({output: 'ua_tail', userAgent: ua})).isEqualTo('[FBAN/FBIOS;FBAV/466.0.0.0.0;FBDV/iPhone14,2]');
- name: ua_tail - Android in-app returns the appended block (after the Safari version)
  code: |-
    const ua = 'Mozilla/5.0 (Linux; Android 14; SM-S911B; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/124.0.0.0 Mobile Safari/537.36 BytedanceWebview/d8a21c6 musical_ly_2022803040';
    assertThat(runCode({output: 'ua_tail', userAgent: ua})).isEqualTo('BytedanceWebview/d8a21c6 musical_ly_2022803040');
- name: ua_tail - desktop web (no appended block) falls back to the last 100 chars
  code: |-
    const ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
    assertThat(ua.length > 100).isEqualTo(true);
    assertThat(runCode({output: 'ua_tail', userAgent: ua})).isEqualTo(ua.substring(ua.length - 100));
- name: ua_tail - real Mobile Safari returns the trailing Safari token
  code: |-
    const ua = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1';
    assertThat(runCode({output: 'ua_tail', userAgent: ua})).isEqualTo('Safari/604.1');
- name: All fields as an object
  code: |-
    const ua = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [FBAN/FBIOS;FBAV/466.0.0.0.0]';
    const r = runCode({output: 'all', userAgent: ua});
    assertThat(r.is_inapp).isEqualTo(true);
    assertThat(r.app_name).isEqualTo('facebook');
    assertThat(r.token).isEqualTo('FBIOS');
    assertThat(r.raw_ua).isEqualTo(ua);
    assertThat(r.ua_tail).isEqualTo('[FBAN/FBIOS;FBAV/466.0.0.0.0]');
- name: Empty User-Agent is handled
  code: |-
    assertThat(runCode({output: 'is_inapp'})).isEqualTo(false);
    assertThat(runCode({output: 'ua_tail'})).isEqualTo('');


___NOTES___

Created for the webview-tracker project. The User-Agent is supplied via the
"userAgent" template field (data.userAgent) -- GTM's sandboxed templates cannot
read navigator.userAgent directly: access_globals rejects any path whose first
token is a predefined browser global ("navigator"). Wire in a GTM JavaScript
Variable returning navigator.userAgent (e.g. {{User Agent}}). Classifies in-app
browsers with substring matching (sandboxed JS has no RegExp). To add a
newly-discovered app, add one row to the APPS table in the sandboxed JS and a
matching test scenario.

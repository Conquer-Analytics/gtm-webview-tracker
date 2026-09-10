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
//   match   - substring searched for in the User-Agent. Written LOWERCASE:
//             matching runs against a lowercased copy of the UA, mirroring
//             inapp-spy, where every pattern carries the /i flag.
//   app     - canonical app name returned by the "app_name" output
//   token   - value returned by the "token" output
//   extract - (optional) a lowercase key whose value is pulled out of the UA
//             and used as the token instead of the static `token` field. The
//             extracted value keeps its ORIGINAL casing ("fban/" -> "FBIOS").
//
// Sandboxed JS has no RegExp, so detection is plain indexOf substring matching.
// Rows that mirror an upstream pattern keep its trailing slash (`reddit/`,
// `micromessenger/`, `line/`): it is what separates the app from its crawler
// (`Reddit/2024.1` matches, `Redditbot/1.0` does not).
// ---------------------------------------------------------------------------
const APPS = [
  // Meta family. iOS appends a bracketed [FBAN/...;FBAV/...] block; Android
  // uses an [FB_IAB/...] block. Messenger and Threads ride inside the same
  // token family, so they must be matched before the generic Facebook rows.
  { match: 'fban/messengerforios', app: 'messenger', token: 'MessengerForiOS' },
  { match: 'messengerliteforios', app: 'messenger', token: 'MessengerLiteForiOS' },
  { match: 'fb_iab/orca-android', app: 'messenger', token: 'Orca-Android' },
  { match: 'barcelona', app: 'threads', token: 'Barcelona' },
  { match: 'instagram', app: 'instagram', token: 'Instagram' },
  { match: 'fban/', app: 'facebook', extract: 'fban/' },
  { match: 'fb_iab/', app: 'facebook', extract: 'fb_iab/' },
  { match: 'fbav/', app: 'facebook', token: 'facebook' },

  // TikTok / ByteDance. inapp-spy keys on `musical_ly|Bytedance`; the first two
  // rows below are curated-backed. Trill (TikTok intl) and aweme (CN) are extra
  // legacy/region names seen in the wild but not in inapp-spy.
  { match: 'bytedancewebview', app: 'tiktok', token: 'BytedanceWebview' },
  { match: 'musical_ly', app: 'tiktok', token: 'musical_ly' },
  { match: 'trill/', app: 'tiktok', token: 'Trill' },
  { match: 'aweme', app: 'tiktok', token: 'aweme' },

  // --- Verified against the inapp-spy / detect-inapp curated lists ---
  { match: 'snapchat', app: 'snapchat', token: 'Snapchat' },
  { match: 'linkedinapp', app: 'linkedin', token: 'LinkedInApp' },
  { match: 'micromessenger/', app: 'wechat', token: 'MicroMessenger' },
  { match: 'line/', app: 'line', token: 'Line' },
  { match: 'twitter', app: 'twitter', token: 'Twitter' },
  { match: 'gsa/', app: 'googleapp', token: 'GSA' },
  { match: 'waios/', app: 'whatsapp', token: 'WAiOS' },
  { match: 'wa4a/', app: 'whatsapp', token: 'WA4A' },
  { match: 'reddit/', app: 'reddit', token: 'Reddit' },

  // --- Beyond the curated lists: plausible and seen in the wild, but NOT in
  // inapp-spy. Lower confidence -- verify against real UAs before trusting.
  // (Telegram in particular is detected client-side, not by UA, upstream.)
  // These stay deliberately loose (no trailing slash), so the crawler filter
  // below is what keeps their bots out. ---
  { match: 'pinterest', app: 'pinterest', token: 'Pinterest' },
  { match: 'kakaotalk', app: 'kakaotalk', token: 'KAKAOTALK' },
  { match: 'telegram', app: 'telegram', token: 'Telegram' }
];

// Crawlers and link-preview fetchers carry app names too ("Twitterbot/1.0",
// "Redditbot/1.0", "TelegramBot (like TwitterBot)" -- which would otherwise be
// counted as Twitter -- and "Pinterest/0.2 (+http://...)"), so they are filtered
// before the table runs. GTM needs JS execution, so most crawlers never reach
// this code, but JS-rendering preview services do exist.
const BOT_MARKERS = ['bot/', 'bot ', 'bot)', 'crawler', 'spider', '+http', 'externalhit'];

function isBot(uaLower) {
  for (let i = 0; i < BOT_MARKERS.length; i = i + 1) {
    if (uaLower.indexOf(BOT_MARKERS[i]) > -1) {
      return true;
    }
  }
  return false;
}

// Pull the value following `keyLower` up to the next UA delimiter. Used to read
// Meta's FBAN / FB_IAB app code (e.g. "FBAN/FBIOS" -> "FBIOS"). The key is
// located in the lowercased UA but the value is read from the original, so the
// token keeps its real casing. Safe because toLowerCase() is length-preserving
// for the ASCII a User-Agent is built from, so the indices line up.
function extractValue(ua, uaLower, keyLower) {
  const start = uaLower.indexOf(keyLower);
  if (start === -1) {
    return undefined;
  }
  let i = start + keyLower.length;
  let out = '';
  while (i < ua.length) {
    const c = ua.substring(i, i + 1);
    if (c === ';' || c === ']' || c === ' ' || c === '/' || c === ')') {
      break;
    }
    out = out + c;
    i = i + 1;
  }
  return out.length > 0 ? out : undefined;
}

// iOS heuristic, aligned with inapp-spy's `(iPhone|iPod|iPad)(?!.*Safari/)`:
// an Apple mobile UA missing the "Safari/" token that real Mobile Safari always
// carries. Deliberately does NOT also require "AppleWebKit" or a "Mobile/"
// build token -- demanding those made this stricter than upstream and missed
// in-app browsers that ship neither.
function isIosNonSafari(uaLower) {
  const isApple =
    uaLower.indexOf('iphone') > -1 ||
    uaLower.indexOf('ipad') > -1 ||
    uaLower.indexOf('ipod') > -1;
  return isApple && uaLower.indexOf('safari/') === -1;
}

function classify(ua) {
  const empty = { isInApp: false, app: undefined, token: undefined };
  if (!ua) {
    return empty;
  }

  const uaLower = ua.toLowerCase();

  // Crawlers carry app names but are not in-app traffic.
  if (isBot(uaLower)) {
    return empty;
  }

  for (let i = 0; i < APPS.length; i = i + 1) {
    const def = APPS[i];
    if (uaLower.indexOf(def.match) > -1) {
      let token = def.token;
      if (def.extract) {
        token = extractValue(ua, uaLower, def.extract);
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
  if (uaLower.indexOf('; wv') > -1) {
    return { isInApp: true, app: 'android_webview', token: 'wv' };
  }

  // Generic literal "WebView" token, used by assorted in-app browsers on both
  // platforms. Part of inapp-spy's generic fallback set.
  if (uaLower.indexOf('webview') > -1) {
    return { isInApp: true, app: 'webview', token: 'WebView' };
  }

  // iOS WKWebView heuristic. Imperfect -- an unknown iOS in-app browser that
  // appends no vendor token AND keeps the Safari token is indistinguishable
  // from Safari, so expect iOS false negatives on unknown apps.
  if (isIosNonSafari(uaLower)) {
    return { isInApp: true, app: 'ios_webview', token: 'no-safari-token' };
  }

  return empty;
}

// ---------------------------------------------------------------------------
// ua_tail: a <=100-char, custom-dimension-safe slice of the User-Agent.
//
// GA4 truncates text event-param values at INGESTION, head-first, so a full UA
// reaches BigQuery (via the normal GA4 -> BQ export) as boilerplate -- the
// signal at the end is gone. We keep the tail instead. Apps append their vendor
// block after the last standard landmark (Mobile/<build> on iOS, Safari/<version>
// on Android), so we return whatever follows that landmark's own version token.
//
// Capping direction differs per path, and that matters: an ISOLATED vendor block
// carries its app name at the FRONT ("Instagram 336.0.0...", "[FBAN/FBIOS;..."),
// so it is capped head-first. Only the fallback -- desktop, regular mobile web,
// or any UA with no appended block -- keeps the last 100 chars, because there the
// rightmost end is the highest-signal one.
// ---------------------------------------------------------------------------
function capTail(s) {
  return s.length > 100 ? s.substring(s.length - 100) : s;
}

function capHead(s) {
  return s.length > 100 ? s.substring(0, 100) : s;
}

// Return the space-delimited token sitting directly in front of `at`. Used for
// the iOS shape `<vendor>/<version> Mobile/<build> Safari/<version>`, where the
// app puts its token BEFORE the landmark (GSA/, CriOS/, FxiOS/) instead of after
// it. Only tokens carrying a "/" qualify, which skips the "(KHTML, like Gecko)"
// boilerplate for UAs that have nothing else in front of the landmark.
function preLandmarkToken(s, at) {
  const head = s.substring(0, at);
  let end = head.length;
  while (end > 0 && head.substring(end - 1, end) === ' ') {
    end = end - 1;
  }
  let start = end;
  while (start > 0 && head.substring(start - 1, start) !== ' ') {
    start = start - 1;
  }
  const token = head.substring(start, end);
  return token.indexOf('/') > -1 ? token : undefined;
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
      let tail = rest.substring(sp + 1);
      // An iOS app can append its block after Safari/<version> rather than
      // after Mobile/<build>. Dropping that redundant prefix hands the 100-char
      // budget to the vendor block instead of spending it on boilerplate. A
      // bare trailing "Safari/604.1" (real Mobile Safari) has no following
      // space and is handled below.
      if (tail.indexOf('Safari/') === 0) {
        const sp2 = tail.indexOf(' ');
        if (sp2 !== -1) {
          tail = tail.substring(sp2 + 1);
        } else {
          // A bare trailing "Safari/<version>" means nothing was appended after
          // the landmark at all, so this UA carries its signal in front of it.
          const before = preLandmarkToken(s, at);
          if (before) {
            return capHead(before);
          }
        }
      }
      if (tail.length > 0) {
        return capHead(tail);
      }
    }
  }
  // No appended block (desktop / regular web): keep the last 100 chars.
  return capTail(s);
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
- name: iOS heuristic also catches a UA with no Mobile build token
  code: |-
    const ua = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) SomeUnknownApp/1.0';
    assertThat(runCode({output: 'is_inapp', userAgent: ua})).isEqualTo(true);
    assertThat(runCode({output: 'app_name', userAgent: ua})).isEqualTo('ios_webview');
- name: Real Mobile Safari is not in-app
  code: |-
    const ua = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1';
    assertThat(runCode({output: 'is_inapp', userAgent: ua})).isEqualTo(false);
    assertThat(runCode({output: 'app_name', userAgent: ua})).isEqualTo(undefined);
- name: Desktop Chrome is not in-app
  code: |-
    const ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
    assertThat(runCode({output: 'is_inapp', userAgent: ua})).isEqualTo(false);
- name: Case-insensitive matching - lowercase and mixed-case app tokens
  code: |-
    const lower = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 instagram 336.0.0.34.105';
    assertThat(runCode({output: 'app_name', userAgent: lower})).isEqualTo('instagram');
    const kakao = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 KakaoTalk/10.4.5';
    assertThat(runCode({output: 'app_name', userAgent: kakao})).isEqualTo('kakaotalk');
- name: Case-insensitive matching keeps the extracted token's original casing
  code: |-
    const ua = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [fban/FBIOS;FBAV/466.0.0.0.0]';
    assertThat(runCode({output: 'app_name', userAgent: ua})).isEqualTo('facebook');
    assertThat(runCode({output: 'token', userAgent: ua})).isEqualTo('FBIOS');
- name: Crawlers and link-preview bots are not in-app
  code: |-
    assertThat(runCode({output: 'is_inapp', userAgent: 'Twitterbot/1.0'})).isEqualTo(false);
    assertThat(runCode({output: 'is_inapp', userAgent: 'Redditbot/1.0'})).isEqualTo(false);
    assertThat(runCode({output: 'is_inapp', userAgent: 'TelegramBot (like TwitterBot)'})).isEqualTo(false);
    assertThat(runCode({output: 'is_inapp', userAgent: 'Pinterest/0.2 (+http://www.pinterest.com/bot.html)'})).isEqualTo(false);
    assertThat(runCode({output: 'app_name', userAgent: 'Twitterbot/1.0'})).isEqualTo(undefined);
- name: Reddit app matches on the version slash, Redditbot does not
  code: |-
    const ua = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Reddit/Version 2024.20.0/Build 1000000';
    assertThat(runCode({output: 'app_name', userAgent: ua})).isEqualTo('reddit');
    assertThat(runCode({output: 'token', userAgent: ua})).isEqualTo('Reddit');
    assertThat(runCode({output: 'is_inapp', userAgent: 'Redditbot/1.0'})).isEqualTo(false);
- name: WeChat matches on the MicroMessenger version slash
  code: |-
    const ua = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.44';
    assertThat(runCode({output: 'app_name', userAgent: ua})).isEqualTo('wechat');
- name: X/Twitter iOS matches without a trailing slash
  code: |-
    const ua = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Twitter for iPhone/10.55';
    assertThat(runCode({output: 'app_name', userAgent: ua})).isEqualTo('twitter');
- name: Messenger iOS beats the generic Facebook rows
  code: |-
    const ua = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [FBAN/MessengerForiOS;FBAV/456.0.0.44.108]';
    assertThat(runCode({output: 'app_name', userAgent: ua})).isEqualTo('messenger');
    assertThat(runCode({output: 'token', userAgent: ua})).isEqualTo('MessengerForiOS');
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
- name: ua_tail - a long iOS block is capped head-first, so the app name survives
  code: |-
    const ua = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Instagram 336.0.0.34.105 (iPhone15,3; iOS 17_5_1; nl_NL; nl-NL; scale=3.00; 1290x2796; 610000000; IABMV/1)';
    const tail = runCode({output: 'ua_tail', userAgent: ua});
    assertThat(tail.length).isEqualTo(100);
    assertThat(tail.substring(0, 9)).isEqualTo('Instagram');
- name: ua_tail - a long Meta block keeps its FBAN token
  code: |-
    const ua = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [FBAN/MessengerForiOS;FBAV/456.0.0.44.108;FBBV/570000000;FBDV/iPhone15,3;FBMD/iPhone;FBSN/iOS;FBSV/17.5;FBSS/3;FBID/phone;FBLC/nl_NL;FBOP/5;FBRID/0]';
    const tail = runCode({output: 'ua_tail', userAgent: ua});
    assertThat(tail.length).isEqualTo(100);
    assertThat(tail.substring(0, 21)).isEqualTo('[FBAN/MessengerForiOS');
- name: ua_tail - drops a redundant leading Safari version token
  code: |-
    const ua = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1 SomeApp/9.1';
    assertThat(runCode({output: 'ua_tail', userAgent: ua})).isEqualTo('SomeApp/9.1');
- name: ua_tail - desktop web (no appended block) falls back to the last 100 chars
  code: |-
    const ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
    assertThat(ua.length > 100).isEqualTo(true);
    assertThat(runCode({output: 'ua_tail', userAgent: ua})).isEqualTo(ua.substring(ua.length - 100));
- name: ua_tail - nothing appended, so the token before the landmark is returned
  code: |-
    const ua = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1';
    assertThat(runCode({output: 'ua_tail', userAgent: ua})).isEqualTo('Version/17.5');
- name: ua_tail - iOS apps that put their token before the landmark stay visible
  code: |-
    const gsa = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) GSA/318.0.642132907 Mobile/15E148 Safari/604.1';
    assertThat(runCode({output: 'ua_tail', userAgent: gsa})).isEqualTo('GSA/318.0.642132907');
    const crios = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/126.0.6478.108 Mobile/15E148 Safari/604.1';
    assertThat(runCode({output: 'ua_tail', userAgent: crios})).isEqualTo('CriOS/126.0.6478.108');
- name: ua_tail - falls back to the Safari token when nothing usable precedes it
  code: |-
    const ua = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Safari/604.1';
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

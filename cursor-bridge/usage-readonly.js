'use strict';

const https = require('https');

function get(path) {
  return new Promise((resolve, reject) => {
    const req = https.request(
      {
        hostname: 'api2.cursor.sh',
        path,
        method: 'GET',
        headers: { Authorization: 'Bearer ' + process.env.CURSOR_API_KEY },
      },
      (res) => {
        let data = '';
        res.on('data', (chunk) => {
          data += chunk;
        });
        res.on('end', () => resolve({ status: res.statusCode || 0, body: data }));
      },
    );
    req.on('error', reject);
    req.setTimeout(8000, () => req.destroy(new Error('timeout')));
    req.end();
  });
}

function parse(body) {
  try {
    return JSON.parse(body);
  } catch {
    return null;
  }
}

function planName(profile) {
  const type = profile.membershipType;
  if (type === 'free_trial') return 'Pro Trial (' + (profile.daysRemainingOnTrial ?? 0) + 'd left)';
  if (type === 'pro') return 'Pro';
  if (type === 'pro_plus') return 'Pro+';
  if (type === 'ultra') return 'Ultra';
  if (type === 'free' || type === 'hobby') return 'Hobby (free)';
  return type || 'unknown';
}

const LABELS = {
  'gpt-4': 'Fast Premium Requests',
  'claude-sonnet-4-6': 'Claude Sonnet 4.6',
  'claude-opus-4-6-v1': 'Claude Opus 4.6',
  'cursor-small': 'Cursor Small (free)',
};

(async () => {
  if (!process.env.CURSOR_API_KEY) {
    console.error('CURSOR_API_KEY missing in cursor-bridge');
    process.exit(1);
  }
  let usageRes;
  let profileRes;
  try {
    [usageRes, profileRes] = await Promise.all([
      get('/auth/usage'),
      get('/auth/full_stripe_profile'),
    ]);
  } catch (err) {
    console.error('Could not reach Cursor plan APIs: ' + (err && err.message ? err.message : err));
    process.exit(1);
  }
  if (usageRes.status === 401 || profileRes.status === 401) {
    console.error('Cursor rejected the Dashboard key for plan APIs (HTTP 401).');
    console.error('Open https://cursor.com/dashboard to see quota.');
    process.exit(2);
  }
  if (usageRes.status < 200 || usageRes.status >= 300) {
    console.error('usage API HTTP ' + usageRes.status);
    process.exit(1);
  }
  const usage = parse(usageRes.body);
  const profile = parse(profileRes.body);
  if (!usage || typeof usage !== 'object') {
    console.error('usage API did not return JSON');
    process.exit(1);
  }
  if (profile && profile.membershipType) {
    const status = profile.subscriptionStatus ? ' (' + profile.subscriptionStatus + ')' : '';
    console.log('Plan: ' + planName(profile) + status);
  }
  if (usage.startOfMonth) {
    console.log('Billing period from: ' + usage.startOfMonth);
  }
  const models = { ...usage };
  delete models.startOfMonth;
  const entries = Object.entries(models).filter(([, value]) => value && typeof value === 'object');
  if (!entries.length) {
    console.log('No request counts this period.');
  } else {
    entries.sort(([, left], [, right]) => {
      const leftMax = left.maxRequestUsage != null;
      const rightMax = right.maxRequestUsage != null;
      if (leftMax !== rightMax) return leftMax ? -1 : 1;
      return (Number(right.numRequests) || 0) - (Number(left.numRequests) || 0);
    });
    for (const [key, value] of entries) {
      const used = Number(value.numRequests) || 0;
      const max = value.maxRequestUsage;
      const label = LABELS[key] || key;
      if (max != null && max > 0) {
        console.log('  ' + label + ': ' + used + '/' + max + ' (' + Math.round((used / max) * 100) + '%)');
      } else if (used > 0) {
        console.log('  ' + label + ': ' + used + ' requests');
      }
    }
  }
  console.log('Unofficial Cursor API. Dashboard is the source of truth.');
})();

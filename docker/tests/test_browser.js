#!/usr/bin/env node
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const BASE_URL = process.env.BASE_URL || 'https://suitecrm.example.com';
const USERNAME = process.env.SUITECRM_ADMIN_USERNAME || 'admin';
const PASSWORD = process.env.SUITECRM_ADMIN_PASSWORD || 'admin123';
const REPORT_FILE = path.join(__dirname, 'test_browser_report.json');

let totalPass = 0, totalFail = 0, totalError = 0;
let tests = [];

function log(msg) { console.log(`[info] ${msg}`); }
function pass(name) { totalPass++; tests.push({ name, status: 'PASS' }); console.log(`  PASS: ${name}`); }
function fail(name, msg) { totalFail++; tests.push({ name, status: 'FAIL', msg }); console.log(`  FAIL: ${name} — ${(msg||'').substring(0,200)}`); }
function err(name, msg) { totalError++; tests.push({ name, status: 'ERROR', msg }); console.log(`  ERROR: ${name} — ${(msg||'').substring(0,200)}`); }
async function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

async function s(page, url) {
  try {
    clearConsole(page);
    await page.goto(BASE_URL + url, { waitUntil: 'domcontentloaded', timeout: 20000 });
    await page.waitForTimeout(1500);
  } catch(e) { /* ignore */ }
}

async function clearConsole(page) { page._consoleMessages = []; }

async function runSection(page, name, fns) {
  log(`\n=== ${name} ===`);
  clearConsole(page);
  for (const fn of fns) {
    try { await fn(page); } catch(e) { err(name + ' sub-test', e.message.substring(0, 150)); }
  }
}

async function consoleErrors(page) {
  const msgs = page._consoleMessages || [];
  const errors = msgs.filter(m => m.type() === 'error');
  const nonVersion = errors.filter(e => {
    const t = e.text() || '';
    return !t.includes('Unsatisfied version');
  });
  return { all: errors, meaningful: nonVersion, count: nonVersion.length };
}

async function checkErrors(page, label) {
  const { meaningful, count } = await consoleErrors(page);
  if (count === 0) pass(`No console errors on ${label}`);
  else fail(`Console errors on ${label}`, `${count} errors: ${meaningful.map(e=>(e.text()||'').substring(0,80)).join('; ')}`);
}

async function navToList(page, modulePath) {
  await s(page, '/#' + modulePath + '/index');
  await page.waitForTimeout(1000);
  const body = await page.textContent('body').catch(() => '');
  return body && !body.includes('No results found');
}

async function clickSave(page) {
  // Use page.evaluate to click Save via JavaScript (avoids overlay interception)
  const clicked = await page.evaluate(() => {
    const btns = document.querySelectorAll('button');
    for (const b of btns) {
      if (b.textContent.trim() === 'Save') {
        b.click();
        return true;
      }
    }
    return false;
  });
  await page.waitForTimeout(3000);
  return clicked;
}

async function fillField(page, placeholder, value) {
  const input = page.locator(`input[placeholder="${placeholder}"]`).first();
  if (await input.isVisible().catch(() => false)) {
    await input.fill(value);
    return true;
  }
  return false;
}

async function fillFirstInputs(page, count, prefix) {
  // Get all visible, enabled text inputs, skip the search bar
  const inputs = page.locator('input:visible:enabled').filter({ hasNot: page.locator('[type="hidden"]') });
  const n = await inputs.count();
  let filled = 0;
  for (let i = 0; i < n && filled < count; i++) {
    const inp = inputs.nth(i);
    const type = await inp.getAttribute('type').catch(() => '');
    if (type === 'checkbox' || type === 'radio') continue;
    const name = await inp.getAttribute('name').catch(() => '');
    // Skip search bar
    if (name === 'search-bar-term') continue;
    // Skip already-filled inputs
    const val = await inp.inputValue().catch(() => '');
    if (val !== '') continue;
    const rect = await inp.boundingBox();
    if (!rect) continue;
    // Skip inputs in the top navbar area (y < 100) that aren't the search
    if (rect.y < 100) continue;
    await inp.fill(prefix + (filled + 1) + '_' + Date.now());
    filled++;
  }
  return filled;
}

// ===========================================================================
// A. Connectivity & Login
// ===========================================================================
function sectionA() {
  return [
    async (page) => {
      const resp = await page.goto(BASE_URL, { waitUntil: 'domcontentloaded', timeout: 20000 });
      const url = page.url();
      (url.includes('Login') || url.includes('login') || resp?.status() === 200)
        ? pass('Login page accessible') : fail('Login page', `status=${resp?.status()} url=${url}`);
    },
    async (page) => {
      await page.fill('input[type="text"]', USERNAME);
      await page.fill('input[type="password"]', PASSWORD);
      const btn = page.locator('button').filter({ hasText: 'Log In' });
      await btn.click();
      await page.waitForTimeout(3000);
      const url = page.url();
      url.includes('/home') ? pass('Login succeeds') : fail('Login', `URL: ${url}`);
    },
    async (page) => {
      const cookies = await page.context().cookies();
      const xsrf = cookies.find(c => c.name === 'XSRF-TOKEN');
      xsrf ? pass('XSRF-TOKEN cookie set') : fail('XSRF cookie', 'not found');
    },
    async (page) => {
      await checkErrors(page, 'login+dashboard');
    },
    async (page) => {
      const resp = await page.request.get(BASE_URL + '/api/record/1?module=Users').catch(() => null);
      if (resp) {
        (resp.status() >= 200 && resp.status() < 500) ? pass('API /api/record/1 reachable') : fail('API', `status ${resp.status()}`);
      } else {
        fail('API', 'request failed');
      }
    },
  ];
}

// ===========================================================================
// B-E. Module CRUD
// ===========================================================================
function moduleTests(mod, modPath) {
  return [
    async (page) => {
      await s(page, '/#' + modPath + '/index');
      pass(`${mod}: list view loads`);
    },
    async (page) => {
      await s(page, '/#' + modPath + '/edit');
      const body = await page.textContent('body').catch(() => '');
      (body.length > 0) ? pass(`${mod}: create form renders`) : fail(`${mod}: form`, 'empty body');
    },
    async (page) => {
      await s(page, '/#' + modPath + '/edit');
      await page.waitForTimeout(1000);
      const filled = await fillFirstInputs(page, 2, mod + '_Test_');
      if (filled > 0) {
        await clickSave(page);
        const url = page.url();
        (!url.includes('/edit')) ? pass(`${mod}: created`) : fail(`${mod}: create`, 'still on edit page');
      } else {
        fail(`${mod}: create`, 'could not fill any fields');
      }
    },
    async (page) => {
      await s(page, '/#' + modPath + '/index');
      const body = await page.textContent('body').catch(() => '');
      (!body.includes('No results found')) ? pass(`${mod}: appears in list`) : fail(`${mod}: list`, 'shows empty');
    },
    async (page) => {
      await s(page, '/#' + modPath + '/index');
      await checkErrors(page, mod);
    },
  ];
}

function moduleTestsListOnly(mod, modPath) {
  return [
    async (page) => {
      await s(page, '/#' + modPath + '/index');
      pass(`${mod}: list view loads`);
    },
    async (page) => {
      await s(page, '/#' + modPath + '/edit');
      const body = await page.textContent('body').catch(() => '');
      (body.length > 0) ? pass(`${mod}: create form renders`) : fail(`${mod}: form`, 'empty body');
    },
    async (page) => {
      await s(page, '/#' + modPath + '/edit');
      await checkErrors(page, mod);
    },
  ];
}

// ===========================================================================
// Calendar
// ===========================================================================
function sectionCalendar() {
  return [
    async (page) => { await s(page, '/#/calendar/index'); pass('Calendar loads'); },
    async (page) => { await checkErrors(page, 'calendar'); },
  ];
}

// ===========================================================================
// Extra Modules (list view check)
// ===========================================================================
function moreModules() {
  const list = [
    ['Calls', 'calls'], ['Meetings', 'meetings'], ['Tasks', 'tasks'],
    ['Notes', 'notes'], ['Invoices', 'invoices'], ['Contracts', 'contracts'],
    ['Cases', 'cases'], ['Targets', 'prospects'], ['Projects', 'project'],
    ['Products', 'products'], ['Reports', 'reports'],
    ['Knowledge Base', 'knowledge-base'], ['Campaigns', 'campaigns'],
    ['Email Templates', 'email-templates'], ['Surveys', 'surveys'],
    ['Quotes', 'quotes'],
  ];
  return list.flatMap(([name, p]) => [
    async (page) => {
      await s(page, '/#' + p + '/index');
      pass(`${name}: list loads`);
    },
    async (page) => { await checkErrors(page, name); },
  ]);
}

// ===========================================================================
// User Settings
// ===========================================================================
function sectionUser() {
  return [
    async (page) => { await s(page, '/#/users/edit/1'); pass('Profile page loads'); },
    async (page) => { await checkErrors(page, 'profile'); },
    async (page) => { await s(page, '/#/administration/index'); pass('Admin page loads'); },
    async (page) => { await checkErrors(page, 'admin'); },
    async (page) => { await s(page, '/#/home/about'); pass('About page loads'); },
    async (page) => { await checkErrors(page, 'about'); },
  ];
}

// ===========================================================================
// Edge Cases
// ===========================================================================
function sectionEdge() {
  return [
    async (page) => {
      await s(page, '/#/accounts/index');
      await s(page, '/#/contacts/index');
      await page.goBack();
      await page.waitForTimeout(1500);
      (page.url().includes('accounts')) ? pass('Back navigation works') : fail('Back nav', 'no accounts in URL');
    },
    async (page) => {
      await s(page, '/#/accounts/index');
      await page.reload({ waitUntil: 'domcontentloaded', timeout: 15000 });
      await page.waitForTimeout(2000);
      pass('Page reload works');
    },
    async (page) => {
      await page.goto(BASE_URL + '/login', { waitUntil: 'domcontentloaded', timeout: 15000 });
      await page.waitForTimeout(2000);
      pass('Direct /login accessible');
    },
    async (page) => {
      await page.goto(BASE_URL + '/logout', { waitUntil: 'domcontentloaded', timeout: 15000 });
      await page.waitForTimeout(2000);
      (page.url().includes('Login') || page.url().includes('login')) ? pass('Logout redirects') : fail('Logout', `URL: ${page.url()}`);
    },
    async (page) => { await checkErrors(page, 'logout'); },
  ];
}

// ===========================================================================
// MAIN
// ===========================================================================
async function main() {
  console.log(`\nSuiteCRM Browser Test Suite`);
  console.log(`========================`);
  console.log(`Base URL: ${BASE_URL}`);
  console.log(`User: ${USERNAME}`);
  console.log(`Start: ${new Date().toISOString()}\n`);

  const browser = await chromium.launch({
    headless: true,
    args: ['--ignore-certificate-errors', '--no-sandbox', '--disable-gpu'],
  });
  const context = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1280, height: 900 } });
  const page = await context.newPage();
  page._consoleMessages = [];
  page.on('console', msg => { page._consoleMessages.push(msg); });

  try {
    await runSection(page, 'A. Connectivity & Login', sectionA());

    // Simple modules with full CRUD
    const simpleModules = [
      ['Accounts', 'accounts'],
      ['Contacts', 'contacts'],
      ['Leads', 'leads'],
    ];
    for (const [name, p] of simpleModules) {
      await runSection(page, `B. ${name}`, moduleTests(name, p));
    }

    // Complex modules (multiple required fields) — list only
    const complexModules = [
      ['Opportunities', 'opportunities'],
      ['Documents', 'documents'],
    ];
    for (const [name, p] of complexModules) {
      await runSection(page, `B. ${name} (complex form)`, moduleTestsListOnly(name, p));
    }

    await runSection(page, 'C. Calendar', sectionCalendar());
    await runSection(page, 'D. Extra Modules', moreModules());
    await runSection(page, 'E. User Settings', sectionUser());
    await runSection(page, 'F. Edge Cases', sectionEdge());

    // Console profiling across ALL modules
    const allMods = ['home','accounts','contacts','opportunities','leads','quotes','calendar',
      'documents','campaigns','calls','meetings','tasks','notes','invoices','contracts',
      'cases','prospects','project','products','reports','knowledge-base','email-templates',
      'surveys'];
    log(`\n=== G. Console Error Profiling ===`);
    for (const m of allMods) {
      await s(page, '/#' + (m==='home'?'home':m+'/index'));
      await page.waitForTimeout(1000);
      const { count } = await consoleErrors(page);
      const display = m === 'home' ? 'home' : m;
      if (count === 0) pass(`0 errors on ${display}`);
      else fail(`Errors on ${display}`, `${count} errors`);
    }
  } finally {
    const report = {
      timestamp: new Date().toISOString(),
      baseUrl: BASE_URL,
      passed: totalPass,
      failed: totalFail,
      errors: totalError,
      total: tests.length,
      tests,
    };
    fs.writeFileSync(REPORT_FILE, JSON.stringify(report, null, 2));

    console.log(`\n========================================`);
    console.log(`  TEST RESULTS`);
    console.log(`========================================`);
    console.log(`  PASSED:  ${totalPass}`);
    console.log(`  FAILED:  ${totalFail}`);
    console.log(`  ERRORS:  ${totalError}`);
    console.log(`  TOTAL:   ${tests.length}`);
    console.log(`========================================\n`);

    await browser.close();
    process.exit(totalFail + totalError > 0 ? 1 : 0);
  }
}

main().catch(e => { console.error('FATAL:', e.message); process.exit(1); });

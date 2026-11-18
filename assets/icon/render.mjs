// Render icon.svg to a transparent 1024px PNG with headless Chrome.
//   node assets/icon/render.mjs [out.png]
// Needs playwright-core (any install) and Google Chrome.
import { readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createRequire } from 'node:module'

const here = dirname(fileURLToPath(import.meta.url))
const out = resolve(process.argv[2] ?? resolve(here, 'icon-1024.png'))
const require = createRequire(process.env.PLAYWRIGHT_FROM ?? import.meta.url)
const { chromium } = require('playwright-core')

const svg = readFileSync(resolve(here, 'icon.svg'), 'utf8')
const browser = await chromium.launch({ channel: 'chrome' })
const page = await browser.newPage({ viewport: { width: 1024, height: 1024 }, deviceScaleFactor: 1 })
await page.setContent(`<!doctype html><html><body style="margin:0;background:transparent">${svg}</body></html>`)
await page.screenshot({ path: out, omitBackground: true, clip: { x: 0, y: 0, width: 1024, height: 1024 } })
await browser.close()
console.log(out)

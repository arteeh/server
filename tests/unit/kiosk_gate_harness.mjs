// Executes files/k0s/kiosk/kiosk-gate.js against a stub DOM so its behaviour —
// not merely its source text — can be asserted from tests/unit/
// test_kiosk_gate_behavior.py.
//
// Usage: node kiosk_gate_harness.mjs <path-to-kiosk-gate.js> '<scenario-json>'
//
// Scenario keys:
//   session  - value returned by localStorage.getItem('kc-has-session')
//   storage  - "throws" to make localStorage.getItem raise (private mode)
//   health   - "ok" | "error" | "throw": how the kc-agent health probe answers
//   health2  - optional second answer, used by the interval tick
//
// Result JSON is printed on stdout.

import { readFileSync } from 'node:fs'
import vm from 'node:vm'

const [scriptPath, scenarioJSON] = process.argv.slice(2)
const scenario = JSON.parse(scenarioJSON ?? '{}')

const GATE_ID = 'kubestellar-kiosk-gate'

const nodes = new Map()
const listeners = []
const timers = []
const fetchCalls = []
let inserts = 0
let healthAnswers = [scenario.health ?? 'throw']
if (scenario.health2) healthAnswers.push(scenario.health2)

const makeElement = (id, html) => {
  const el = {
    id,
    html,
    remove: () => nodes.delete(id),
    contains: (node) => node === el || node?.parentGate === el,
  }
  return el
}

const document = {
  body: {
    insertAdjacentHTML(position, html) {
      inserts += 1
      const id = /id="([^"]+)"/.exec(html)?.[1]
      nodes.set(id, makeElement(id, html))
      document.body.lastPosition = position
    },
    lastPosition: null,
  },
  getElementById: (id) => nodes.get(id) ?? null,
  addEventListener: (type, handler, capture) =>
    listeners.push({ type, handler, capture }),
}

const window = {
  localStorage: {
    getItem(key) {
      if (scenario.storage === 'throws') throw new Error('storage disabled')
      return key === 'kc-has-session' ? (scenario.session ?? null) : null
    },
  },
  location: { origin: 'https://console.example' },
  setInterval: (handler, delay) => {
    timers.push({ handler, delay })
    return timers.length
  },
}

const answerHealth = () => {
  const answer = healthAnswers.length > 1 ? healthAnswers.shift() : healthAnswers[0]
  if (answer === 'throw') throw new Error('connection refused')
  return { ok: answer === 'ok', status: answer === 'ok' ? 200 : 503 }
}

const fetchStub = async (url, options) => {
  fetchCalls.push({ url, options })
  return answerHealth()
}

const flush = async () => {
  for (let i = 0; i < 10; i += 1) await new Promise((r) => setTimeout(r, 0))
}

const keydownResult = (target) => {
  const handler = listeners.find((l) => l.type === 'keydown')?.handler
  if (!handler) return null
  const event = {
    target,
    defaultPrevented: false,
    preventDefault() {
      this.defaultPrevented = true
    },
  }
  handler(event)
  return event.defaultPrevented
}

const context = vm.createContext({ window, document, fetch: fetchStub, console })
new vm.Script(readFileSync(scriptPath, 'utf8'), { filename: 'kiosk-gate.js' }).runInContext(
  context,
)

await flush()

const afterLoad = {
  gate: nodes.has(GATE_ID),
  inserts,
  fetchCalls: fetchCalls.length,
}

// Drive the poll the script registered, so a second cycle is exercised the way
// the browser would exercise it.
if (timers.length) {
  timers[0].handler()
  await flush()
}

const gate = nodes.get(GATE_ID) ?? null

const result = {
  afterLoad,
  afterTick: {
    gate: nodes.has(GATE_ID),
    inserts,
    fetchCalls: fetchCalls.length,
  },
  gateHTML: gate?.html ?? null,
  insertPosition: document.body.lastPosition,
  timers: timers.map((t) => t.delay),
  listeners: listeners.map((l) => ({ type: l.type, capture: l.capture })),
  fetchURLs: fetchCalls.map((c) => c.url),
  fetchOptions: fetchCalls.map((c) => c.options ?? null),
  keydownOutside: keydownResult({}),
  keydownInside: gate ? keydownResult({ parentGate: gate }) : null,
}

process.stdout.write(JSON.stringify(result))

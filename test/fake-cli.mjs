// Stand-in for the agentcheckup CLI, used by test/scripts.sh. It checks the arguments the action
// passes, logs every call to $FAKE_LOG, and writes canned reports. $FAKE_SCENARIO picks the
// result: gate, clean, plain, error, base-crash or big.
import { appendFileSync, readFileSync, realpathSync, writeFileSync } from 'node:fs';

const scenario = process.env.FAKE_SCENARIO ?? 'clean';
const argv = process.argv.slice(2);
const options = new Map();
const flags = new Set();
let path;

function usage(message) {
  process.stderr.write(`Error: ${message}\n`);
  process.exit(2);
}

for (let i = 0; i < argv.length; i += 1) {
  const arg = argv[i];
  if (arg === '--') {
    if (argv.length !== i + 2) usage('expected exactly one path after --');
    path = argv[i + 1];
    break;
  }
  if (!arg.startsWith('--')) usage(`unexpected argument ${arg}`);
  const eq = arg.indexOf('=');
  if (eq === -1) flags.add(arg.slice(2));
  else options.set(arg.slice(2, eq), arg.slice(eq + 1));
}

const cwd = process.cwd();
const workspace = process.env.FAKE_WORKSPACE ? realpathSync(process.env.FAKE_WORKSPACE) : '';
const isHead = cwd === workspace;
appendFileSync(
  process.env.FAKE_LOG,
  `${JSON.stringify({
    cwd,
    head: isHead,
    argv,
    // test/scripts.sh uses a token that starts with ghs_FakeToken.
    tokenInEnv: Object.values(process.env).some((value) => value.includes('ghs_FakeToken')),
  })}\n`,
);

for (const flag of ['untrusted', 'no-gitignore', 'context']) {
  if (!flags.has(flag)) usage(`missing --${flag}`);
}
if (path === undefined) usage('missing path');
const format = options.get('format');
if (!['json', 'markdown', 'sarif', 'github'].includes(format)) usage('bad --format');
if (format !== 'github' && !options.has('output')) usage('missing --output');
if (options.has('gate') && !options.has('baseline')) usage('--gate needs --baseline');
if (options.has('baseline')) {
  const baseline = JSON.parse(readFileSync(options.get('baseline'), 'utf8'));
  if (baseline.schemaVersion !== 1) usage('bad baseline');
}

if (scenario === 'base-crash' && !isHead) process.exit(3);
if (scenario === 'error' && isHead) usage('simulated usage error');

const prefix = path === '.' ? '' : `${path.replace(/^\.\//u, '')}/`;
const hasBaseline = options.has('baseline');
const gateOn = hasBaseline && options.get('gate') !== 'none';
const tripped = scenario === 'gate' && gateOn;
const hits = tripped
  ? [
      { class: 'env', id: `env:${prefix}.claude/settings.json#ANTHROPIC_BASE_URL`, change: 'added', summary: 'Env override' },
      { class: 'mcp-unpinned', id: `mcp:${prefix}.mcp.json#browser`, change: 'added', summary: 'New MCP server, not pinned' },
      { class: 'permissions', id: `perm:${prefix}.claude/settings.json#permissions.allow=Bash`, change: 'added', summary: 'Permission widened' },
    ]
  : [];
const errors = scenario === 'plain' ? 2 : 0;

const report = {
  schemaVersion: 1,
  tool: { name: 'agentcheckup', version: '0.0.0-fake' },
  ruleset: '2026.10',
  findings: [],
  summary: { errors, warnings: scenario === 'plain' ? 1 : 0, infos: 0, suppressed: 0 },
  inventory: { mcpServers: [], hooks: [], permissions: [], env: [], incomplete: [] },
  context: { agents: [], sources: {}, plans: [] },
  ...(hasBaseline
    ? {
        baseline: {
          against: { version: '0.0.0-fake', ruleset: '2026.10', sameRuleset: true },
          findings: { new: tripped ? 2 : 0, unchanged: 0, resolved: [] },
          inventory: { added: [], removed: [], changed: [] },
          context: [],
          gate: { classes: ['env', 'mcp-unpinned', 'permissions'], hits },
        },
      }
    : {}),
};

let text;
if (format === 'json') text = `${JSON.stringify(report, null, 2)}\n`;
if (format === 'sarif') text = `${JSON.stringify({ version: '2.1.0', runs: [] })}\n`;
if (format === 'markdown') {
  text = `### agentcheckup: agent configuration changes\n\n**Needs review: ${hits.length} security-relevant changes**\n`;
  if (scenario === 'big') text += `${'| row | with some table text that fills the summary |\n'.repeat(60000)}`;
}
if (format === 'github') {
  process.stdout.write(`::warning file=${prefix}CLAUDE.md,line=1,title=fake/rule::Fake finding\n`);
} else {
  writeFileSync(options.get('output'), text);
}

const failed = tripped || (!hasBaseline && options.get('fail-on') !== 'none' && errors > 0);
process.exit(failed ? 1 : 0);

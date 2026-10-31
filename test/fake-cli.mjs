// Stand-in for the agentcheckup CLI, used by test/scripts.sh. It checks the arguments the action
// passes, logs every call to $FAKE_LOG, and writes canned reports.
//
// Scans: $FAKE_SCENARIO picks the result: gate, clean, plain, findings (new findings only),
// skips (the change makes an agent skip a file), not-read (a new skip of a file the agent never
// reads), error, base-crash or big. With --policy it reads the policy like the real CLI (a
// regular file of at most 256 KiB, known top-level fields only) and reports one violation per
// `forbid` entry, failing unless the policy's mode is audit.
//
// `fix --format suggestions`: $FAKE_SUGGEST picks the result: ok (default), error (exit 2),
// crash (exit 3) or garbage (unreadable output).
import { createHash } from 'node:crypto';
import { appendFileSync, lstatSync, readFileSync, realpathSync, writeFileSync } from 'node:fs';

const scenario = process.env.FAKE_SCENARIO ?? 'clean';
const fix = process.argv[2] === 'fix';
const argv = process.argv.slice(fix ? 3 : 2);
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
    fix,
    argv,
    // test/scripts.sh uses tokens that start with ghs_FakeToken and ghp_CentralToken.
    tokenInEnv: Object.values(process.env).some(
      (value) => value.includes('ghs_FakeToken') || value.includes('ghp_CentralToken'),
    ),
  })}\n`,
);

if (path === undefined) usage('missing path');
if (!flags.has('untrusted')) usage('missing --untrusted');

if (fix) {
  // The real fix command rejects the scan's flags and needs --untrusted and --diff.
  for (const flag of ['no-gitignore', 'context']) if (flags.has(flag)) usage(`--${flag} is not for fix`);
  for (const option of ['baseline', 'gate', 'fail-on', 'policy']) {
    if (options.has(option)) usage(`--${option} is not for fix`);
  }
  if (options.get('format') !== 'suggestions') usage('bad --format');
  if (!options.has('diff') || !options.has('output')) usage('missing --diff or --output');
  const diff = readFileSync(options.get('diff'), 'utf8');
  if (!diff.startsWith('diff --git ')) usage('the diff is not a unified diff');
  const suggest = process.env.FAKE_SUGGEST ?? 'ok';
  if (suggest === 'error') usage('simulated usage error');
  if (suggest === 'crash') process.exit(3);
  if (suggest === 'garbage') {
    writeFileSync(options.get('output'), 'not json');
    process.exit(0);
  }
  const marker = (hash) => `<!-- agentcheckup-suggestion claude-code/fake-rule ${hash} -->`;
  const body = (lines, hash) =>
    ['```suggestion', ...lines, '```', '', '**agentcheckup** safe fix: fake.', '', marker(hash)].join('\n');
  const comments = [
    { path: 'sub/CLAUDE.md', line: 3, side: 'RIGHT', body: body(['Run `npm test` first.'], 'aaaaaaaaaaaa') },
    {
      path: 'sub/CLAUDE.md',
      line: 2,
      start_line: 1,
      side: 'RIGHT',
      start_side: 'RIGHT',
      body: body(['# Project notes', ''], 'bbbbbbbbbbbb'),
    },
    // Hostile: the suggested line is repository text that looks like another comment's marker.
    { path: 'sub/CLAUDE.md', line: 1, side: 'RIGHT', body: body([marker('cccccccccccc')], 'dddddddddddd') },
    // Outside the scanned path, sub.
    { path: 'other/AGENTS.md', line: 1, side: 'RIGHT', body: body(['x'], 'eeeeeeeeeeee') },
    // No marker on the last line: never posted, it could not be matched on the next run.
    { path: 'sub/CLAUDE.md', line: 2, side: 'RIGHT', body: `${body(['y'], 'ffffffffffff')}\ntrailing text` },
  ];
  const output = {
    schemaVersion: 1,
    tool: { name: 'agentcheckup', version: '0.0.0-fake' },
    ruleset: '2026.10',
    comments,
    skipped: [{ reason: 'outside-diff', count: 2 }],
  };
  writeFileSync(options.get('output'), `${JSON.stringify(output, null, 2)}\n`);
  process.exit(0);
}

for (const flag of ['no-gitignore', 'context']) {
  if (!flags.has(flag)) usage(`missing --${flag}`);
}
const format = options.get('format');
if (!['json', 'markdown', 'sarif', 'github'].includes(format)) usage('bad --format');
if (format !== 'github' && !options.has('output')) usage('missing --output');
const category = options.get('sarif-category');
if (category !== undefined && format !== 'sarif') usage('--sarif-category works only with --format sarif');
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
const newFindings = tripped ? 2 : scenario === 'findings' && hasBaseline ? 1 : 0;

// A skip of sub/.cursor/rules/x.md that the change adds, for the skips and not-read scenarios.
const skip =
  (scenario === 'skips' || scenario === 'not-read') && isHead
    ? { id: `skip:${prefix}.cursor/rules/x.md`, role: 'rule', path: `${prefix}.cursor/rules/x.md`, code: scenario === 'skips' ? 'wrong-extension' : 'not-read', certainty: 'documented', evidence: [] }
    : undefined;

let policy;
if (options.has('policy')) {
  const file = options.get('policy');
  const stat = lstatSync(file);
  if (stat.isSymbolicLink() || !stat.isFile()) usage(`Refusing to read policy file ${file}`);
  if (stat.size > 262144) usage(`Refusing to read policy file ${file}: too large`);
  const bytes = readFileSync(file);
  let parsed;
  try {
    parsed = JSON.parse(bytes.toString('utf8'));
  } catch {
    usage(`${file}: not JSON`);
  }
  const known = ['$schema', 'policyVersion', 'name', 'mode', 'existing', 'mcp', 'forbid', 'permissions', 'hooks', 'budgets'];
  for (const key of Object.keys(parsed)) {
    if (!known.includes(key)) usage(`${file}: Unknown field "${key}". Unknown fields are an error, so a typo cannot switch a check off.`);
  }
  const mode = parsed.mode ?? 'enforce';
  const real = realpathSync(file);
  policy = {
    name: parsed.name,
    sha256: createHash('sha256').update(bytes).digest('hex'),
    mode,
    insideScanRoot: real.startsWith(`${cwd}/`),
    checks: 1,
    violations: (parsed.forbid ?? []).map((name) => ({
      id: `forbidden-setting:${name}`,
      check: 'forbidden-setting',
      entry: name,
      path: `${prefix}.claude/settings.json`,
      message: `The policy forbids ${name}.`,
      ...(hasBaseline ? { baseline: 'new' } : {}),
      fails: mode !== 'audit',
    })),
    notes: [],
  };
}
const policyFails = policy !== undefined && policy.violations.some((violation) => violation.fails);

const report = {
  schemaVersion: 1,
  tool: { name: 'agentcheckup', version: '0.0.0-fake' },
  ruleset: '2026.10',
  findings: [],
  summary: { errors, warnings: scenario === 'plain' ? 1 : 0, infos: 0, suppressed: 0 },
  inventory: { mcpServers: [], hooks: [], permissions: [], env: [], incomplete: [] },
  context: {
    agents: ['claude-code'],
    sources: {},
    plans: [{ agent: 'claude-code', cwd: '.', entries: [], skipped: skip === undefined ? [] : [skip] }],
  },
  ...(hasBaseline
    ? {
        baseline: {
          against: { version: '0.0.0-fake', ruleset: '2026.10', sameRuleset: true, newRules: [] },
          findings: { new: newFindings, unchanged: 0, resolved: [] },
          inventory: { added: [], removed: [], changed: [] },
          context: [
            {
              agent: 'claude-code',
              cwd: '.',
              entries: { added: [], removed: [], changed: [] },
              skipped: { added: skip === undefined ? [] : [skip.id], removed: [], changed: [] },
              startupTokens: { before: 10, after: 10 },
              limits: [],
            },
          ],
          gate: { classes: ['env', 'mcp-unpinned', 'permissions'], hits },
        },
      }
    : {}),
  ...(policy === undefined ? {} : { policy }),
};

let text;
if (format === 'json') text = `${JSON.stringify(report, null, 2)}\n`;
if (format === 'sarif') {
  const id = category === undefined ? 'agentcheckup/' : `agentcheckup/${category}/`;
  text = `${JSON.stringify({ version: '2.1.0', runs: [{ automationDetails: { id } }] })}\n`;
}
if (format === 'markdown') {
  text = '';
  if (policy !== undefined) {
    text += `### Policy: ${policy.name}\n\n**Violations: ${policy.violations.length}**\n\n`;
  }
  text += `### agentcheckup: agent configuration changes\n\n**Needs review: ${hits.length} security-relevant changes**\n`;
  if (scenario === 'big') text += `${'| row | with some table text that fills the summary |\n'.repeat(60000)}`;
}
if (format === 'github') {
  process.stdout.write(`::warning file=${prefix}CLAUDE.md,line=1,title=fake/rule::Fake finding\n`);
} else {
  writeFileSync(options.get('output'), text);
}

const failed =
  tripped || policyFails || (!hasBaseline && options.get('fail-on') !== 'none' && errors > 0);
process.exit(failed ? 1 : 0);

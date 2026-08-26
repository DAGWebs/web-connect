import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

// The resource is Lua, so the behavioural suite runs under a real interpreter
// with FiveM's natives stubbed (tests/lua/harness.lua). Install lua5.4 to run
// it; CI does this in .github/workflows/test.yml.
const INTERPRETERS = ['lua5.4', 'lua'];

function findInterpreter() {
  for (const candidate of INTERPRETERS) {
    const probe = spawnSync(candidate, ['-v'], { encoding: 'utf8' });
    if (!probe.error) return candidate;
  }
  return null;
}

test('lua behavioural suite', () => {
  const interpreter = findInterpreter();
  assert.ok(
    interpreter,
    `No Lua interpreter found (tried ${INTERPRETERS.join(', ')}). Install lua5.4 to run the resource tests.`,
  );

  const result = spawnSync(interpreter, ['tests/lua/spec.lua'], { encoding: 'utf8' });
  const output = `${result.stdout || ''}${result.stderr || ''}`;
  if (result.status !== 0) console.error(output);
  else console.log(output.trim().split('\n').at(-1));

  assert.equal(result.status, 0, 'every Lua test should pass');
  assert.match(output, /\d+ passed, 0 failed/);
});

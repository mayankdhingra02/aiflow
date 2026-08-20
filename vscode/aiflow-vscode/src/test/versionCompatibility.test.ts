import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import {
    checkCodexExtensionVersion,
    SUPPORTED_CODEX_EXTENSION_VERSIONS,
    TESTED_CODEX_EXTENSION_VERSION
} from '../codexIpc/versionCompatibility';

test('the accepted Codex extension version is supported', () => {
    const result = checkCodexExtensionVersion('26.814.41407');

    assert.equal(result.supported, true);
    assert.equal(result.version, '26.814.41407');
    assert.equal(TESTED_CODEX_EXTENSION_VERSION, '26.814.41407');
    assert.deepEqual(SUPPORTED_CODEX_EXTENSION_VERSIONS, ['26.814.41407']);
});

test('the known incompatible version is rejected', () => {
    const result = checkCodexExtensionVersion('26.818.21641');

    assert.equal(result.supported, false);
    assert.equal(result.version, '26.818.21641');
    assert.match(result.detail, /26\.818\.21641/);
    assert.match(result.detail, /26\.814\.41407/);
});

test('arbitrary future versions are rejected', () => {
    const result = checkCodexExtensionVersion('26.999.99999');

    assert.equal(result.supported, false);
    assert.match(result.detail, /26\.999\.99999/);
});

test('missing, empty, and malformed versions fail closed', () => {
    for (const version of [undefined, '', null, 26.81441407, {}, '26.814.41407-beta']) {
        const result = checkCodexExtensionVersion(version);

        assert.equal(result.supported, false, `version should be rejected: ${String(version)}`);
        assert.match(result.detail, /could not determine|disabled/);
        assert.match(result.detail, /26\.814\.41407/);
    }
});

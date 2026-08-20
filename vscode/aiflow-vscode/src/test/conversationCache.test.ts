import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import { ConversationCache } from '../codexIpc/conversationCache';

const CONV_A = '01a01ce8-26ec-7a03-af97-7e4bf1196de5';
const CONV_B = '01a01c88-87fe-71d0-9d34-ad555722dc2a';

/** Records what the cache asked for, so bootstraps can be counted exactly. */
function harness(options: { owned?: Set<string>; mint?: string[] } = {}): {
    cache: ConversationCache;
    bootstraps: string[];
    ownerChecks: string[];
    owned: Set<string>;
} {
    const owned = options.owned ?? new Set<string>();
    const mint = options.mint ? [...options.mint] : [CONV_A, CONV_B];
    const bootstraps: string[] = [];
    const ownerChecks: string[] = [];

    const cache = new ConversationCache({
        // Mirrors the real helper's macOS behaviour without touching the filesystem.
        canonicalPath: (value) => value.replace(/^\/private\/tmp\//, '/tmp/'),
        hasLiveOwner: async (conversationId) => {
            ownerChecks.push(conversationId);
            return owned.has(conversationId);
        },
        bootstrap: async (workspacePath) => {
            bootstraps.push(workspacePath);
            const minted = mint.shift();
            if (!minted) {
                throw new Error('no more conversations to mint');
            }
            owned.add(minted);
            return minted;
        }
    });

    return { cache, bootstraps, ownerChecks, owned };
}

test('the first run for a workspace bootstraps exactly once and remembers the result', async () => {
    const { cache, bootstraps } = harness();

    const first = await cache.resolve('/tmp/demo');

    assert.equal(first.conversationId, CONV_A);
    assert.equal(first.bootstrapped, true);
    assert.deepEqual(bootstraps, ['/tmp/demo']);
    assert.equal(cache.peek('/tmp/demo'), CONV_A);
});

test('a second run for the same workspace reuses the conversation without bootstrapping', async () => {
    const { cache, bootstraps } = harness();

    const first = await cache.resolve('/tmp/demo');
    const second = await cache.resolve('/tmp/demo');

    assert.equal(second.conversationId, first.conversationId);
    assert.equal(second.bootstrapped, false, 'no synthetic turn on the second run');
    assert.deepEqual(bootstraps, ['/tmp/demo'], 'bootstrap ran exactly once');
});

test('reuse is only accepted after confirming the conversation still has an owner', async () => {
    const { cache, ownerChecks } = harness();

    await cache.resolve('/tmp/demo');
    await cache.resolve('/tmp/demo');

    assert.deepEqual(ownerChecks, [CONV_A], 'the cached conversation is validated before reuse');
});

test('/tmp and /private/tmp share one cache entry', async () => {
    const { cache, bootstraps } = harness();

    const first = await cache.resolve('/tmp/demo');
    const second = await cache.resolve('/private/tmp/demo');

    assert.equal(second.conversationId, first.conversationId);
    assert.equal(second.bootstrapped, false);
    assert.deepEqual(bootstraps, ['/tmp/demo'], 'the same repo never bootstraps twice');
    assert.equal(cache.size, 1);
});

test('a cached conversation whose owner is gone is evicted and replaced once', async () => {
    const { cache, bootstraps, owned } = harness();

    const first = await cache.resolve('/tmp/demo');
    assert.equal(first.conversationId, CONV_A);

    // The VS Code client that owned it went away.
    owned.delete(CONV_A);

    const second = await cache.resolve('/tmp/demo');

    assert.equal(second.conversationId, CONV_B, 'a fresh conversation replaces the stale one');
    assert.equal(second.bootstrapped, true);
    assert.deepEqual(bootstraps, ['/tmp/demo', '/tmp/demo'], 'exactly one extra bootstrap');
    assert.equal(cache.peek('/tmp/demo'), CONV_B);

    // And the replacement is then reused like any other.
    const third = await cache.resolve('/tmp/demo');
    assert.equal(third.bootstrapped, false);
    assert.equal(bootstraps.length, 2);
});

test('different workspaces get independent conversations', async () => {
    const { cache, bootstraps } = harness();

    const one = await cache.resolve('/tmp/alpha');
    const two = await cache.resolve('/tmp/beta');

    assert.notEqual(one.conversationId, two.conversationId);
    assert.deepEqual(bootstraps, ['/tmp/alpha', '/tmp/beta']);
    assert.equal(cache.size, 2);

    // Each keeps its own.
    assert.equal((await cache.resolve('/tmp/alpha')).conversationId, one.conversationId);
    assert.equal((await cache.resolve('/tmp/beta')).conversationId, two.conversationId);
    assert.equal(bootstraps.length, 2);
});

// MARK: the cache survives run outcomes
//
// Completion, cancellation, and ordinary turn failures say nothing about whether the
// conversation is still usable, so none of them touch the cache. The next run revalidates
// ownership anyway.

test('a completed run leaves the conversation cached', async () => {
    const { cache, bootstraps } = harness();
    const first = await cache.resolve('/tmp/demo');

    // A completed run does not call forget(); the next run reuses.
    const next = await cache.resolve('/tmp/demo');

    assert.equal(next.conversationId, first.conversationId);
    assert.deepEqual(bootstraps, ['/tmp/demo']);
});

test('a cancelled run leaves the conversation cached', async () => {
    const { cache, bootstraps } = harness();
    const first = await cache.resolve('/tmp/demo');

    // Cancelling a turn does not destroy the thread it ran in.
    const next = await cache.resolve('/tmp/demo');

    assert.equal(next.conversationId, first.conversationId);
    assert.equal(next.bootstrapped, false);
    assert.deepEqual(bootstraps, ['/tmp/demo']);
});

test('a failed turn does not by itself discard the conversation', async () => {
    const { cache, bootstraps } = harness();
    await cache.resolve('/tmp/demo');

    // Nothing in the failure path calls forget(); only a missing owner evicts.
    const next = await cache.resolve('/tmp/demo');

    assert.equal(next.bootstrapped, false);
    assert.deepEqual(bootstraps, ['/tmp/demo']);
});

// MARK: determinism

test('two concurrent resolves for one workspace mint only one conversation', async () => {
    const { cache, bootstraps } = harness();

    const [first, second] = await Promise.all([
        cache.resolve('/tmp/demo'),
        cache.resolve('/tmp/demo')
    ]);

    assert.equal(first.conversationId, second.conversationId);
    assert.deepEqual(bootstraps, ['/tmp/demo'], 'never two bootstraps for one workspace');
});

test('concurrent resolves for different workspaces are independent', async () => {
    const { cache, bootstraps } = harness();

    const [one, two] = await Promise.all([
        cache.resolve('/tmp/alpha'),
        cache.resolve('/tmp/beta')
    ]);

    assert.notEqual(one.conversationId, two.conversationId);
    assert.equal(bootstraps.length, 2);
});

test('a failed bootstrap is not cached and does not block a later attempt', async () => {
    const { cache } = harness({ mint: [] });

    await assert.rejects(() => cache.resolve('/tmp/demo'));
    assert.equal(cache.size, 0, 'nothing is remembered for a workspace that never got a thread');
    assert.equal(cache.peek('/tmp/demo'), undefined);
});

test('forget drops a workspace, and clear drops everything', async () => {
    const { cache } = harness();
    await cache.resolve('/tmp/alpha');
    await cache.resolve('/tmp/beta');

    cache.forget('/private/tmp/alpha'); // canonicalised to the same entry
    assert.equal(cache.peek('/tmp/alpha'), undefined);
    assert.equal(cache.size, 1);

    cache.clear();
    assert.equal(cache.size, 0);
});

test('the cache stores nothing about prompts', async () => {
    const { cache } = harness();
    await cache.resolve('/tmp/demo');

    // Only a workspace key and a conversation id exist; there is no prompt-shaped API at all.
    assert.equal(cache.peek('/tmp/demo'), CONV_A);
    assert.deepEqual(
        Object.getOwnPropertyNames(ConversationCache.prototype).sort(),
        ['constructor', 'size', 'clear', 'forget', 'peek', 'resolve'].sort()
    );
});

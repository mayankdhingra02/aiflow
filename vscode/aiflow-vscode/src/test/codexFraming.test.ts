import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import { FrameDecoder, FrameError, encodeFrame } from '../codexIpc/framing';

function frame(value: unknown): Buffer {
    return encodeFrame(value);
}

test('encodes a 4-byte little-endian length prefix', () => {
    const encoded = frame({ a: 1 });
    const payload = JSON.stringify({ a: 1 });

    assert.equal(encoded.readUInt32LE(0), Buffer.byteLength(payload, 'utf8'));
    assert.equal(encoded.subarray(4).toString('utf8'), payload);
});

test('round-trips a single frame', () => {
    const decoder = new FrameDecoder();
    assert.deepEqual(decoder.push(frame({ type: 'response', id: '1' })), [
        { type: 'response', id: '1' }
    ]);
});

test('reassembles a header split across chunks', () => {
    const decoder = new FrameDecoder();
    const encoded = frame({ hello: 'world' });

    assert.deepEqual(decoder.push(encoded.subarray(0, 2)), []);
    assert.deepEqual(decoder.push(encoded.subarray(2, 4)), []);
    assert.deepEqual(decoder.push(encoded.subarray(4)), [{ hello: 'world' }]);
});

test('reassembles a payload split across chunks', () => {
    const decoder = new FrameDecoder();
    const encoded = frame({ value: 'abcdefghijklmnop' });
    const split = Math.floor(encoded.length / 2);

    assert.deepEqual(decoder.push(encoded.subarray(0, split)), []);
    assert.deepEqual(decoder.push(encoded.subarray(split)), [{ value: 'abcdefghijklmnop' }]);
});

test('decodes several frames delivered in one chunk', () => {
    const decoder = new FrameDecoder();
    const chunk = Buffer.concat([frame({ n: 1 }), frame({ n: 2 }), frame({ n: 3 })]);

    assert.deepEqual(decoder.push(chunk), [{ n: 1 }, { n: 2 }, { n: 3 }]);
});

test('leaves a trailing partial frame buffered', () => {
    const decoder = new FrameDecoder();
    const complete = frame({ n: 1 });
    const partial = frame({ n: 2 }).subarray(0, 5);

    assert.deepEqual(decoder.push(Buffer.concat([complete, partial])), [{ n: 1 }]);
    assert.ok(decoder.bufferedBytes > 0);
});

test('measures multi-byte UTF-8 by bytes, not characters', () => {
    const decoder = new FrameDecoder();
    const value = { text: '😀 héllo 中文' };
    const encoded = frame(value);

    // The length prefix must be the byte length, otherwise the split below would desync.
    assert.equal(encoded.readUInt32LE(0), Buffer.byteLength(JSON.stringify(value), 'utf8'));
    assert.deepEqual(decoder.push(encoded.subarray(0, 7)), []);
    assert.deepEqual(decoder.push(encoded.subarray(7)), [value]);
});

test('rejects a zero-length frame', () => {
    const decoder = new FrameDecoder();
    const header = Buffer.alloc(4);
    header.writeUInt32LE(0, 0);

    assert.throws(() => decoder.push(header), FrameError);
    assert.equal(decoder.isFailed, true);
});

test('rejects an oversized declared length before allocating', () => {
    const decoder = new FrameDecoder(1024);
    const header = Buffer.alloc(4);
    header.writeUInt32LE(5_000_000, 0);

    assert.throws(() => decoder.push(header), FrameError);
    assert.equal(decoder.isFailed, true);
    assert.equal(decoder.bufferedBytes, 0, 'nothing is retained after a fatal framing error');
});

test('a failed decoder refuses further data', () => {
    const decoder = new FrameDecoder(1024);
    const header = Buffer.alloc(4);
    header.writeUInt32LE(5_000_000, 0);

    assert.throws(() => decoder.push(header), FrameError);
    assert.throws(() => decoder.push(frame({ n: 1 })), FrameError);
});

test('buffering stays bounded while a payload is still arriving', () => {
    const decoder = new FrameDecoder(4096);
    const encoded = frame({ text: 'x'.repeat(2000) });

    decoder.push(encoded.subarray(0, 100));
    assert.ok(decoder.bufferedBytes <= 4096 + 4);
});

test('skips a malformed payload without desynchronising the stream', () => {
    const decoder = new FrameDecoder();
    const bad = Buffer.from('{not json', 'utf8');
    const header = Buffer.alloc(4);
    header.writeUInt32LE(bad.length, 0);

    const chunk = Buffer.concat([header, bad, frame({ good: true })]);

    // The bad frame is dropped, the following frame is still decoded correctly.
    assert.deepEqual(decoder.push(chunk), [{ good: true }]);
    assert.equal(decoder.isFailed, false);
});

test('refuses to encode an oversized outbound frame', () => {
    assert.throws(() => encodeFrame({ text: 'x'.repeat(5000) }, 1024), FrameError);
});

test('reset clears buffered bytes and failure', () => {
    const decoder = new FrameDecoder(1024);
    const header = Buffer.alloc(4);
    header.writeUInt32LE(5_000_000, 0);
    assert.throws(() => decoder.push(header), FrameError);

    decoder.reset();
    assert.equal(decoder.isFailed, false);
    assert.deepEqual(decoder.push(frame({ n: 1 })), [{ n: 1 }]);
});

/**
 * Framing for the official Codex client-coordination IPC router.
 *
 * Each frame is a 4-byte little-endian unsigned payload length followed by exactly that many
 * bytes of UTF-8 JSON. The reader is deliberately defensive: a hostile or simply broken peer
 * must not be able to make us allocate without bound, and a length that is impossible is a
 * protocol error rather than something to wait on.
 */

export const FRAME_HEADER_BYTES = 4;

/** Hard ceiling on a single inbound frame. Codex control messages are small. */
export const MAX_FRAME_BYTES = 8 * 1024 * 1024;

export class FrameError extends Error {}

/** Encodes one frame. Throws rather than emitting a frame the peer would reject. */
export function encodeFrame(value: unknown, maxBytes: number = MAX_FRAME_BYTES): Buffer {
    const payload = Buffer.from(JSON.stringify(value), 'utf8');
    if (payload.length > maxBytes) {
        throw new FrameError(`outbound frame of ${payload.length} bytes exceeds ${maxBytes}`);
    }
    const header = Buffer.allocUnsafe(FRAME_HEADER_BYTES);
    header.writeUInt32LE(payload.length, 0);
    return Buffer.concat([header, payload]);
}

/**
 * Accumulates socket chunks and yields complete frames.
 *
 * Handles the cases a stream actually produces: a header split across chunks, a payload split
 * across chunks, and several frames arriving in one chunk.
 */
export class FrameDecoder {
    private buffer: Buffer = Buffer.alloc(0);
    private failed = false;

    constructor(private readonly maxFrameBytes: number = MAX_FRAME_BYTES) {}

    get isFailed(): boolean {
        return this.failed;
    }

    /** Bytes currently buffered awaiting more data. Exposed for tests and diagnostics. */
    get bufferedBytes(): number {
        return this.buffer.length;
    }

    /**
     * Returns the frames completed by this chunk. Throws `FrameError` when the stream is
     * unusable — the caller must then drop the connection, since framing cannot resynchronise.
     */
    push(chunk: Buffer): unknown[] {
        if (this.failed) {
            throw new FrameError('decoder already failed');
        }

        this.buffer = this.buffer.length === 0 ? chunk : Buffer.concat([this.buffer, chunk]);
        const frames: unknown[] = [];

        for (;;) {
            if (this.buffer.length < FRAME_HEADER_BYTES) {
                break;
            }

            const length = this.buffer.readUInt32LE(0);

            if (length === 0) {
                this.failed = true;
                this.buffer = Buffer.alloc(0);
                throw new FrameError('zero-length frame');
            }
            if (length > this.maxFrameBytes) {
                // Refuse before allocating: this is how an oversized length would hurt us.
                this.failed = true;
                this.buffer = Buffer.alloc(0);
                throw new FrameError(`frame length ${length} exceeds ${this.maxFrameBytes}`);
            }

            const total = FRAME_HEADER_BYTES + length;
            if (this.buffer.length < total) {
                break; // payload still arriving
            }

            const payload = this.buffer.subarray(FRAME_HEADER_BYTES, total);
            this.buffer = this.buffer.subarray(total);

            let parsed: unknown;
            try {
                parsed = JSON.parse(payload.toString('utf8'));
            } catch {
                // One malformed payload does not desynchronise the stream: the frame boundary
                // is known, so skip this frame and keep reading.
                continue;
            }
            frames.push(parsed);
        }

        return frames;
    }

    reset(): void {
        this.buffer = Buffer.alloc(0);
        this.failed = false;
    }
}

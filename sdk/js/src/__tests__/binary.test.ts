import { describe, expect, it } from "vitest";

import { BROADCAST, decodeServerFrame, encodePush, PUSH, REPLY } from "../binary.js";

/**
 * Le cadrage binaire de Phoenix v2.
 *
 * These assertions are transcribed from Phoenix's own serializer rather than
 * from a running server, deliberately: they are what pins the SDK to the
 * protocol, so they have to state the byte layout rather than agree with
 * whatever the code currently emits.
 */
describe("encodePush", () => {
  it("place les tailles avant les champs, dans l'ordre du sérialiseur", () => {
    const data = new Uint8Array([0xaa, 0xbb]);
    const bytes = new Uint8Array(encodePush("7", "12", "room:x", "a", data));

    expect(bytes[0]).toBe(PUSH);
    expect(bytes[1]).toBe(1); // join_ref "7"
    expect(bytes[2]).toBe(2); // ref "12"
    expect(bytes[3]).toBe(6); // topic "room:x"
    expect(bytes[4]).toBe(1); // event "a"

    const text = new TextDecoder().decode(bytes.subarray(5, 5 + 1 + 2 + 6 + 1));
    expect(text).toBe("712room:xa");
    expect(Array.from(bytes.subarray(15))).toEqual([0xaa, 0xbb]);
  });

  it("copie la charge utile, pour que l'appelant puisse réutiliser son tampon", () => {
    const scratch = new Uint8Array([1, 2, 3]);
    const bytes = new Uint8Array(encodePush("1", "1", "t", "a", scratch));

    // The audio path reuses one frame buffer every 20 ms; aliasing it here
    // would send whatever the next frame happens to contain.
    scratch.fill(9);
    expect(Array.from(bytes.subarray(bytes.length - 3))).toEqual([1, 2, 3]);
  });

  it("refuse un champ de plus de 255 octets plutôt que de le tronquer", () => {
    // A truncated topic would deliver audio to a different room.
    expect(() => encodePush("1", "1", "r".repeat(256), "a", new Uint8Array())).toThrow(
      RangeError
    );
  });
});

describe("decodeServerFrame", () => {
  it("lit une diffusion", () => {
    const bytes = new Uint8Array([2, 6, 1, ...new TextEncoder().encode("room:xa"), 7, 8]);
    const frame = decodeServerFrame(bytes.buffer)!;

    expect(frame.kind).toBe(BROADCAST);
    expect(frame.topic).toBe("room:x");
    expect(frame.event).toBe("a");
    expect(Array.from(frame.data)).toEqual([7, 8]);
  });

  it("lit un push serveur, qui ne porte pas de ref", () => {
    const bytes = new Uint8Array([0, 1, 6, 1, ...new TextEncoder().encode("9room:xa"), 5]);
    const frame = decodeServerFrame(bytes.buffer)!;

    expect(frame.kind).toBe(PUSH);
    expect(frame.joinRef).toBe("9");
    expect(frame.ref).toBeNull();
    expect(Array.from(frame.data)).toEqual([5]);
  });

  it("lit une réponse et son statut", () => {
    const bytes = new Uint8Array([1, 1, 2, 6, 5, ...new TextEncoder().encode("912room:xerror")]);
    const frame = decodeServerFrame(bytes.buffer)!;

    expect(frame.kind).toBe(REPLY);
    expect(frame.ref).toBe("12");
    expect(frame.event).toBe("error");
  });

  it("rend null sur une trame tronquée plutôt que de lever", () => {
    // One bad frame must not take down the socket every other channel shares.
    expect(decodeServerFrame(new Uint8Array([]).buffer)).toBeNull();
    expect(decodeServerFrame(new Uint8Array([2, 200, 200, 1]).buffer)).toBeNull();
    expect(decodeServerFrame(new Uint8Array([99, 1, 2]).buffer)).toBeNull();
  });

  it("compte les octets et non les caractères sur un topic accentué", () => {
    // "équipe" is 7 bytes for 6 characters: the case where using string length
    // as a byte length silently shifts every field after it.
    const topic = "room:équipe";
    const t = new TextEncoder().encode(topic);
    const bytes = new Uint8Array([2, t.length, 1, ...t, 97, 1, 2, 3, 4]);

    const frame = decodeServerFrame(bytes.buffer)!;
    expect(frame.topic).toBe(topic);
    expect(frame.event).toBe("a");
    expect(Array.from(frame.data)).toEqual([1, 2, 3, 4]);
  });

  it("ne lit pas un push client, qui a un format différent", () => {
    // Stated as a test because it fooled the author: encodePush produces the
    // client-to-server shape, which has an extra ref field. Feeding it here
    // yields nonsense rather than an error, so nothing must ever do it.
    const frame = decodeServerFrame(encodePush("3", "44", "room:x", "a", new Uint8Array([1])))!;
    expect(frame.topic).not.toBe("room:x");
  });
});

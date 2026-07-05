import { expect, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
	canonicalizeReleaseArtifactBytes,
	hashDir,
} from "../../scripts/verify-release.ts";

const enc = new TextEncoder();

function syntheticMachO(
	uuidByte: number,
	cacheHash: string,
	linkeditByte = uuidByte,
	osoTimestampByte = uuidByte,
	codeSignatureByte = uuidByte,
): Uint8Array {
	const headerSize = 32;
	const segmentCommandSize = 72;
	const uuidCommandSize = 24;
	const symtabCommandSize = 24;
	const codeSignatureCommandSize = 16;
	const path = enc.encode(`/tmp/project/.zig-cache/o/${cacheHash}/zt_zcu.o`);
	const commandSize =
		segmentCommandSize +
		uuidCommandSize +
		symtabCommandSize +
		codeSignatureCommandSize;
	const pathOffset = headerSize + commandSize;
	const symbolTableOffset = pathOffset + path.byteLength;
	const codeSignatureSize = 64;
	const codeSignatureOffset = symbolTableOffset + 16;
	const linkeditSize = 32;
	const linkeditOffset = codeSignatureOffset + codeSignatureSize;
	const out = new Uint8Array(linkeditOffset + linkeditSize);
	const view = new DataView(out.buffer);

	view.setUint32(0, 0xfeedfacf, true); // Mach-O 64-bit, little-endian
	view.setUint32(16, 4, true); // ncmds
	view.setUint32(20, commandSize, true); // sizeofcmds

	view.setUint32(headerSize, 0x19, true); // LC_SEGMENT_64
	view.setUint32(headerSize + 4, segmentCommandSize, true);
	out.set(enc.encode("__LINKEDIT"), headerSize + 8);
	view.setBigUint64(headerSize + 40, BigInt(symbolTableOffset), true);
	view.setBigUint64(
		headerSize + 48,
		BigInt(out.byteLength - symbolTableOffset),
		true,
	);

	const uuidOffset = headerSize + segmentCommandSize;
	view.setUint32(uuidOffset, 0x1b, true); // LC_UUID
	view.setUint32(uuidOffset + 4, uuidCommandSize, true);
	out.fill(uuidByte, uuidOffset + 8, uuidOffset + 24);

	const symtabOffset = uuidOffset + uuidCommandSize;
	view.setUint32(symtabOffset, 0x2, true); // LC_SYMTAB
	view.setUint32(symtabOffset + 4, symtabCommandSize, true);
	view.setUint32(symtabOffset + 8, symbolTableOffset, true);
	view.setUint32(symtabOffset + 12, 1, true); // nsyms
	view.setUint32(symtabOffset + 16, pathOffset, true);
	view.setUint32(symtabOffset + 20, path.byteLength, true);

	const codeSignatureCommandOffset = symtabOffset + symtabCommandSize;
	view.setUint32(codeSignatureCommandOffset, 0x1d, true); // LC_CODE_SIGNATURE
	view.setUint32(
		codeSignatureCommandOffset + 4,
		codeSignatureCommandSize,
		true,
	);
	view.setUint32(codeSignatureCommandOffset + 8, codeSignatureOffset, true);
	view.setUint32(codeSignatureCommandOffset + 12, codeSignatureSize, true);

	out.set(path, pathOffset);
	view.setUint32(symbolTableOffset, 0, true);
	out[symbolTableOffset + 4] = 0x66; // N_OSO
	view.setUint16(symbolTableOffset + 6, 1, true);
	out.fill(osoTimestampByte, symbolTableOffset + 8, symbolTableOffset + 16);
	out.fill(
		codeSignatureByte,
		codeSignatureOffset,
		codeSignatureOffset + codeSignatureSize,
	);
	out.fill(linkeditByte, linkeditOffset, linkeditOffset + linkeditSize);

	return out;
}

function malformedUuidMachO(): Uint8Array {
	const headerSize = 32;
	const uuidCommandSize = 16;
	const sentinelSize = 16;
	const sentinelOffset = headerSize + uuidCommandSize;
	const out = new Uint8Array(sentinelOffset + sentinelSize);
	const view = new DataView(out.buffer);

	view.setUint32(0, 0xfeedfacf, true); // Mach-O 64-bit, little-endian
	view.setUint32(16, 1, true); // ncmds
	view.setUint32(20, uuidCommandSize, true); // sizeofcmds
	view.setUint32(headerSize, 0x1b, true); // LC_UUID
	view.setUint32(headerSize + 4, uuidCommandSize, true);
	out.fill(0xaa, headerSize + 8, sentinelOffset);
	out.fill(0xee, sentinelOffset, sentinelOffset + sentinelSize);

	return out;
}

function malformedAfterUuidMachO(): Uint8Array {
	const headerSize = 32;
	const uuidCommandSize = 24;
	const truncatedCommandSize = 4;
	const sentinelSize = 16;
	const sentinelOffset = headerSize + uuidCommandSize + truncatedCommandSize;
	const out = new Uint8Array(sentinelOffset + sentinelSize);
	const view = new DataView(out.buffer);

	view.setUint32(0, 0xfeedfacf, true); // Mach-O 64-bit, little-endian
	view.setUint32(16, 2, true); // ncmds
	view.setUint32(20, uuidCommandSize + truncatedCommandSize, true);
	view.setUint32(headerSize, 0x1b, true); // LC_UUID
	view.setUint32(headerSize + 4, uuidCommandSize, true);
	out.fill(0xaa, headerSize + 8, headerSize + uuidCommandSize);
	out.fill(0xee, sentinelOffset, sentinelOffset + sentinelSize);

	return out;
}

test("release artifact canonicalization removes Darwin linker/cache noise", () => {
	const a = syntheticMachO(
		0xaa,
		"0123456789abcdef0123456789abcdef",
		0xcc,
		0xee,
		0xee,
	);
	const b = syntheticMachO(
		0xbb,
		"fedcba9876543210fedcba9876543210",
		0xcc,
		0xee,
		0xee,
	);

	expect(canonicalizeReleaseArtifactBytes(a)).toEqual(
		canonicalizeReleaseArtifactBytes(b),
	);
});

test("release artifact canonicalization preserves LINKEDIT drift", () => {
	const a = syntheticMachO(0xaa, "0123456789abcdef0123456789abcdef", 0xcc);
	const b = syntheticMachO(0xaa, "0123456789abcdef0123456789abcdef", 0xdd);

	expect(canonicalizeReleaseArtifactBytes(a)).not.toEqual(
		canonicalizeReleaseArtifactBytes(b),
	);
});

test("release artifact canonicalization removes OSO timestamp drift", () => {
	const a = syntheticMachO(
		0xaa,
		"0123456789abcdef0123456789abcdef",
		0xcc,
		0x11,
		0xee,
	);
	const b = syntheticMachO(
		0xaa,
		"0123456789abcdef0123456789abcdef",
		0xcc,
		0x22,
		0xee,
	);

	expect(canonicalizeReleaseArtifactBytes(a)).toEqual(
		canonicalizeReleaseArtifactBytes(b),
	);
});

test("release artifact canonicalization removes code signature drift", () => {
	const a = syntheticMachO(
		0xaa,
		"0123456789abcdef0123456789abcdef",
		0xcc,
		0xee,
		0x11,
	);
	const b = syntheticMachO(
		0xaa,
		"0123456789abcdef0123456789abcdef",
		0xcc,
		0xee,
		0x22,
	);

	expect(canonicalizeReleaseArtifactBytes(a)).toEqual(
		canonicalizeReleaseArtifactBytes(b),
	);
});

test("release artifact canonicalization ignores malformed short LC_UUID", () => {
	const malformed = malformedUuidMachO();

	expect(canonicalizeReleaseArtifactBytes(malformed)).toEqual(malformed);
});

test("release artifact canonicalization discards partial malformed Mach-O edits", () => {
	const malformed = malformedAfterUuidMachO();

	expect(canonicalizeReleaseArtifactBytes(malformed)).toEqual(malformed);
});

test("release artifact canonicalization leaves non-Mach-O bytes untouched", () => {
	const a = enc.encode("plain artifact a");
	const b = enc.encode("plain artifact b");

	expect(canonicalizeReleaseArtifactBytes(a)).toEqual(a);
	expect(canonicalizeReleaseArtifactBytes(b)).toEqual(b);
});

test("release artifact canonicalization leaves short inputs untouched", () => {
	const short = enc.encode("short");

	expect(canonicalizeReleaseArtifactBytes(short)).toEqual(short);
});

test("hashDir frames canonicalized Mach-O release artifacts", async () => {
	const aDir = await mkdtemp(join(tmpdir(), "z3store-release-a-"));
	const bDir = await mkdtemp(join(tmpdir(), "z3store-release-b-"));
	try {
		await Bun.write(
			join(aDir, "zt"),
			syntheticMachO(0x11, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 0x33),
		);
		await Bun.write(
			join(bDir, "zt"),
			syntheticMachO(0x22, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", 0x33),
		);

		expect(await hashDir(aDir)).toBe(await hashDir(bDir));
	} finally {
		await rm(aDir, { recursive: true, force: true });
		await rm(bDir, { recursive: true, force: true });
	}
});

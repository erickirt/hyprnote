import { describe, expect, test } from "vitest";

import {
  CORE_TRANSCRIPTION_LANGUAGE_CODES,
  getAdditionalSpokenLanguages,
  getBaseLanguageCode,
  parseLocale,
} from "./language";

describe("getAdditionalSpokenLanguages", () => {
  test("removes the main language from stored spoken languages", () => {
    expect(getAdditionalSpokenLanguages("en", ["en", "ko"])).toEqual(["ko"]);
  });

  test("matches regional variants by base language", () => {
    expect(getAdditionalSpokenLanguages("en-US", ["en", "ko-KR"])).toEqual([
      "ko",
    ]);
  });

  test("deduplicates additional languages", () => {
    expect(getAdditionalSpokenLanguages("en", ["ko", "ko-KR", "ja"])).toEqual([
      "ko",
      "ja",
    ]);
  });

  test("ignores malformed stored spoken languages", () => {
    expect(getAdditionalSpokenLanguages("en", ["not a locale", "ko"])).toEqual([
      "ko",
    ]);
  });

  test("preserves the ISO 639-1 code for Filipino", () => {
    expect(getBaseLanguageCode("tl")).toBe("tl");
    expect(getAdditionalSpokenLanguages("en", ["fil"])).toEqual(["tl"]);
  });

  test("uses a valid fallback while the main language is loading", () => {
    expect(parseLocale("")).toEqual({ language: "en" });
  });
});

describe("CORE_TRANSCRIPTION_LANGUAGE_CODES", () => {
  test("uses languages supported by both Deepgram and Soniox", () => {
    expect(CORE_TRANSCRIPTION_LANGUAGE_CODES).toContain("en");
    expect(CORE_TRANSCRIPTION_LANGUAGE_CODES).toContain("zh");
    expect(CORE_TRANSCRIPTION_LANGUAGE_CODES).toContain("sr");

    expect(CORE_TRANSCRIPTION_LANGUAGE_CODES).not.toContain("af");
    expect(CORE_TRANSCRIPTION_LANGUAGE_CODES).not.toContain("az");
    expect(CORE_TRANSCRIPTION_LANGUAGE_CODES).not.toContain("sq");
  });
});

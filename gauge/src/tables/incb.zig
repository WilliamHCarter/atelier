//! Indic Conjunct Break (InCB) property tables — Unicode 16.0.
//! Source: IndicSyllabicCategory.txt + Unicode 15.1 Conjunct-Linking Scripts specification.
//! Hand-curated for the 10 classical South Asian Conjunct-Linking scripts + Meetei Mayek.
//!
//! Used by the grapheme cluster boundary algorithm (UAX #29) rule GB9c:
//!   \p{InCB=Consonant} [\p{InCB=Extend}\p{InCB=Linker}]* \p{InCB=Linker}
//!   [\p{InCB=Extend}\p{InCB=Linker}]* × \p{InCB=Consonant}

pub const Range = struct { first: u21, last: u21 };

/// InCB=Linker: VIRAMA-like characters in Conjunct-Linking scripts.
/// A single Linker in the cluster enables GB9c for the next Consonant.
/// Sorted by codepoint value. Binary-searchable.
pub const linker_table = [_]Range{
    .{ .first = 0x094D, .last = 0x094D }, // DEVANAGARI SIGN VIRAMA
    .{ .first = 0x09CD, .last = 0x09CD }, // BENGALI SIGN VIRAMA
    .{ .first = 0x0A4D, .last = 0x0A4D }, // GURMUKHI SIGN VIRAMA
    .{ .first = 0x0ACD, .last = 0x0ACD }, // GUJARATI SIGN VIRAMA
    .{ .first = 0x0B4D, .last = 0x0B4D }, // ORIYA SIGN VIRAMA
    .{ .first = 0x0BCD, .last = 0x0BCD }, // TAMIL SIGN VIRAMA
    .{ .first = 0x0C4D, .last = 0x0C4D }, // TELUGU SIGN VIRAMA
    .{ .first = 0x0CCD, .last = 0x0CCD }, // KANNADA SIGN VIRAMA
    .{ .first = 0x0D4D, .last = 0x0D4D }, // MALAYALAM SIGN VIRAMA
    .{ .first = 0x0DCA, .last = 0x0DCA }, // SINHALA SIGN AL-LAKUNA
    .{ .first = 0xAAF6, .last = 0xAAF6 }, // MEETEI MAYEK VIRAMA
};

/// InCB=Consonant: Consonant characters in Conjunct-Linking scripts.
/// Codepoints not listed here default to InCB=None (or InCB=Extend via GB9).
/// Sorted by first codepoint. Binary-searchable.
pub const consonant_table = [_]Range{
    // Devanagari
    .{ .first = 0x0915, .last = 0x0939 }, // LETTER KA..LETTER HA
    .{ .first = 0x0958, .last = 0x095F }, // LETTER QA..LETTER YYA
    .{ .first = 0x0978, .last = 0x097F }, // LETTER MARWARI DDA..LETTER BBA
    // Bengali
    .{ .first = 0x0995, .last = 0x09A8 }, // LETTER KA..LETTER NA
    .{ .first = 0x09AA, .last = 0x09B0 }, // LETTER PA..LETTER RA
    .{ .first = 0x09B2, .last = 0x09B2 }, // LETTER LA
    .{ .first = 0x09B6, .last = 0x09B9 }, // LETTER SHA..LETTER HA
    .{ .first = 0x09DC, .last = 0x09DD }, // LETTER RRA..LETTER RHA
    .{ .first = 0x09DF, .last = 0x09DF }, // LETTER YYA
    .{ .first = 0x09F0, .last = 0x09F1 }, // LETTER RA WITH MIDDLE DIAGONAL..LOWER DIAGONAL
    // Gurmukhi
    .{ .first = 0x0A15, .last = 0x0A28 }, // LETTER KA..LETTER NA
    .{ .first = 0x0A2A, .last = 0x0A30 }, // LETTER PA..LETTER RA
    .{ .first = 0x0A32, .last = 0x0A33 }, // LETTER LA..LETTER LLA
    .{ .first = 0x0A35, .last = 0x0A36 }, // LETTER VA..LETTER SHA
    .{ .first = 0x0A38, .last = 0x0A39 }, // LETTER SA..LETTER HA
    .{ .first = 0x0A59, .last = 0x0A5C }, // LETTER KHHA..LETTER RRA
    .{ .first = 0x0A5E, .last = 0x0A5E }, // LETTER FA
    // Gujarati
    .{ .first = 0x0A95, .last = 0x0AA8 }, // LETTER KA..LETTER NA
    .{ .first = 0x0AAA, .last = 0x0AB0 }, // LETTER PA..LETTER RA
    .{ .first = 0x0AB2, .last = 0x0AB3 }, // LETTER LA..LETTER LLA
    .{ .first = 0x0AB5, .last = 0x0AB9 }, // LETTER VA..LETTER HA
    .{ .first = 0x0AF9, .last = 0x0AF9 }, // LETTER ZHA
    // Oriya
    .{ .first = 0x0B15, .last = 0x0B28 }, // LETTER KA..LETTER NA
    .{ .first = 0x0B2A, .last = 0x0B30 }, // LETTER PA..LETTER RA
    .{ .first = 0x0B32, .last = 0x0B33 }, // LETTER LA..LETTER LLA
    .{ .first = 0x0B35, .last = 0x0B39 }, // LETTER VA..LETTER HA
    .{ .first = 0x0B5C, .last = 0x0B5D }, // LETTER RRA..LETTER RHA
    .{ .first = 0x0B5F, .last = 0x0B5F }, // LETTER YYA
    .{ .first = 0x0B71, .last = 0x0B71 }, // LETTER WA
    // Tamil
    .{ .first = 0x0B95, .last = 0x0B95 }, // LETTER KA
    .{ .first = 0x0B99, .last = 0x0B9A }, // LETTER NGA..LETTER CA
    .{ .first = 0x0B9C, .last = 0x0B9C }, // LETTER JA
    .{ .first = 0x0B9E, .last = 0x0B9F }, // LETTER NYA..LETTER TTA
    .{ .first = 0x0BA3, .last = 0x0BA4 }, // LETTER NNA..LETTER TA
    .{ .first = 0x0BA8, .last = 0x0BAA }, // LETTER NA..LETTER PA
    .{ .first = 0x0BAE, .last = 0x0BB9 }, // LETTER MA..LETTER HA
    // Telugu
    .{ .first = 0x0C15, .last = 0x0C28 }, // LETTER KA..LETTER NA
    .{ .first = 0x0C2A, .last = 0x0C39 }, // LETTER PA..LETTER HA
    .{ .first = 0x0C58, .last = 0x0C5A }, // LETTER TSA..LETTER RRRA
    // Kannada
    .{ .first = 0x0C95, .last = 0x0CA8 }, // LETTER KA..LETTER NA
    .{ .first = 0x0CAA, .last = 0x0CB3 }, // LETTER PA..LETTER LLA
    .{ .first = 0x0CB5, .last = 0x0CB9 }, // LETTER VA..LETTER HA
    .{ .first = 0x0CDE, .last = 0x0CDE }, // LETTER FA
    // Malayalam
    .{ .first = 0x0D15, .last = 0x0D3A }, // LETTER KA..LETTER TTTA
    // Sinhala
    .{ .first = 0x0D9A, .last = 0x0DB1 }, // LETTER ALPAPRAANA KAYANNA..DANTAJA NAYANNA
    .{ .first = 0x0DB3, .last = 0x0DBB }, // LETTER SANYAKA DAYANNA..RAYANNA
    .{ .first = 0x0DBD, .last = 0x0DBD }, // LETTER DANTAJA LAYANNA
    .{ .first = 0x0DC0, .last = 0x0DC6 }, // LETTER VAYANNA..LETTER FAYANNA
    // Meetei Mayek
    .{ .first = 0xAAE2, .last = 0xAAEA }, // LETTER CHA..LETTER SSA
    .{ .first = 0xABC0, .last = 0xABCD }, // LETTER KOK..LETTER HUK
    .{ .first = 0xABD0, .last = 0xABD0 }, // LETTER PHAM
    .{ .first = 0xABD2, .last = 0xABDA }, // LETTER GOK..LETTER BHAM
};

## How to generate subset for TTF

- Parse all needed tables.
- Get input text and transform as glyphID
- Add `.notdef` for glyphID's
- Recursive glyph ids checking for complex glyphs.
- Copy required table and update numGlyphs and other need.

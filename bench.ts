/* eslint-disable @typescript-eslint/no-unused-expressions */
import fs from 'fs'
import { bench, group, run } from 'mitata'
import opentype from 'opentype.js'
import path from 'path'
import { createSubsetEngine } from './bindings/javascript/wasm'
import { ttf2woff } from './deps/ttf2woff'

const wasmPath = path.join(__dirname, 'zig-out', 'ttf.wasm')
const ttfPath = path.join(__dirname, 'fonts', 'LXGWBright-Light.ttf')
const fontData = new Uint8Array(fs.readFileSync(ttfPath))
const wasmBinary = fs.readFileSync(wasmPath)

const testText = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789汉字测试段落The quick brown fox jumps over the lazy dog.'
const shortText = 'Hello World'
const longText =
  'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789汉字测试段落The quick brown fox jumps over the lazy dog.这是一个很长的测试文本，包含了中英文混合的内容，用于测试字体子集生成的性能。Lorem ipsum dolor sit amet, consectetur adipiscing elit. 中文测试内容包括常用汉字和标点符号。'

const wasmEngine = createSubsetEngine(wasmBinary)
wasmEngine.loadFont(fontData)
const otFont = opentype.parse(fs.readFileSync(ttfPath).buffer)

function createOpentypeSubset(font: opentype.Font, text: string): ArrayBuffer {
  const originalWarn = console.warn
  console.warn = () => {}
  const glyphs = []
  const notdefGlyph = font.glyphs.get(0)
  glyphs.push(notdefGlyph)

  for (const char of text) {
    const glyphIndex = font.charToGlyphIndex(char)
    if (glyphIndex > 0) {
      const glyph = font.glyphs.get(glyphIndex)
      if (glyph && !glyphs.find((g) => g.index === glyph.index)) {
        glyphs.push(glyph)
      }
    }
  }

  try {
    const subsetFont = new opentype.Font({
      familyName: font.names.fontFamily.en,
      styleName: font.names.fontSubfamily.en,
      unitsPerEm: font.unitsPerEm,
      ascender: font.ascender,
      descender: font.descender,
      glyphs
    })

    return subsetFont.toArrayBuffer()
  } finally {
    console.warn = originalWarn
  }
}

group('get glyph id for codepoint', () => {
  bench('WASM', () => {
    for (const char of testText) {
      const codePoint = char.codePointAt(0)!
      wasmEngine.getGlyphIdForCodepoint(codePoint)
    }
  })
  bench('opentype.js', () => {
    for (const char of testText) {
      const codePoint = char.codePointAt(0)!
      otFont.charToGlyphIndex(String.fromCodePoint(codePoint))
    }
  })
})

group('get glyph name', () => {
  const glyphIds = Array.from({ length: 100 }, (_, i) => i + 1)
  bench('WASM', () => {
    for (const id of glyphIds) {
      wasmEngine.getGlyphName(id)
    }
  })
  bench('opentype.js', () => {
    for (const id of glyphIds) {
      otFont.glyphs.get(id)?.name
    }
  })
})

group('subset generation - short text', () => {
  bench('WASM (instance method)', () => {
    const engine = createSubsetEngine(wasmBinary)
    engine.loadFont(fontData)
    engine.createSubset()
    engine.addTextToSubset(shortText)
    engine.generateSubsetFont()
    engine.destroy()
  })

  bench('opentype.js', () => {
    createOpentypeSubset(otFont, shortText)
  })
})

group('subset generation - long text', () => {
  bench('WASM (instance method)', () => {
    const engine = createSubsetEngine(wasmBinary)
    engine.loadFont(fontData)
    engine.createSubset()
    engine.addTextToSubset(longText)
    engine.generateSubsetFont()
    engine.destroy()
  })

  bench('opentype.js', () => {
    createOpentypeSubset(otFont, longText)
  })
})

group('woff generation', () => {
  bench('WASM', async () => {
    const engine = createSubsetEngine(wasmBinary)
    await engine.ttfToWoff(fontData)
    engine.destroy()
  })
  bench('javascript', () => {
    ttf2woff(fontData)
  })
})

run().catch(console.error)

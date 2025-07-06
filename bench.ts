/* eslint-disable @typescript-eslint/no-unused-expressions */
import fs from 'fs'
import { bench, group, run } from 'mitata'
import opentype from 'opentype.js'
import path from 'path'
import { createSubsetEngine } from './bindings/javascript/wasm'

const wasmPath = path.join(__dirname, 'zig-out', 'ttf.wasm')
const ttfPath = path.join(__dirname, 'fonts', 'LXGWBright-Light.ttf')
const fontData = new Uint8Array(fs.readFileSync(ttfPath))
const wasmBinary = fs.readFileSync(wasmPath)

const testText = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789汉字测试段落The quick brown fox jumps over the lazy dog.'

const wasmEngine = createSubsetEngine(wasmBinary)
wasmEngine.loadFont(fontData)
const otFont = opentype.parse(fs.readFileSync(ttfPath).buffer)

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

run().catch(console.error)

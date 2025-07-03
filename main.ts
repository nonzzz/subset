import fs from 'fs'
import path from 'path'
import { createSubsetEngine } from './bindings/javascript/wasm'

const wasmPath = path.join(__dirname, 'zig-out', 'ttf.wasm')
const ttfPath = path.join(__dirname, 'fonts', 'LXGWBright-Light.ttf')

function main() {
  if (!fs.existsSync(wasmPath)) {
    throw new Error(`WASM file not found at ${wasmPath}`)
  }

  if (!fs.existsSync(ttfPath)) {
    throw new Error(`TTF file not found at ${ttfPath}`)
  }

  const fontData = new Uint8Array(fs.readFileSync(ttfPath))

  const binary = fs.readFileSync(wasmPath)

  const engine = createSubsetEngine(binary)

  const state = engine.loadFont(fontData)

  if (!state) {
    console.error('Failed to load font')
    return
  }
  console.log('✅ Font loaded successfully!')

  const metrics = engine.getFontMetrics()

  if (metrics) {
    console.log('\n📊 Font Metrics:')
    console.log(`  Units per EM: ${metrics.unitsPerEm}`)
    console.log(`  Ascender: ${metrics.ascender}`)
    console.log(`  Descender: ${metrics.descender}`)
    console.log(`  Line Gap: ${metrics.lineGap}`)
    console.log(`  Max Advance Width: ${metrics.advanceWidthMax}`)
    console.log(`  Bounds: (${metrics.xMin}, ${metrics.yMin}) to (${metrics.xMax}, ${metrics.yMax})`)
  }

  console.log(`\n📏 Number of glyphs: ${engine.getNumGlyphs()}`)
  console.log(`🔤 Is monospace: ${engine.isMonospace()}`)

  const familyName = engine.getFontName(1)

  if (familyName) {
    console.log(`📝 Font Family: ${familyName}`)
  }

  const testText = '绪方理奈'

  for (const char of testText) {
    const codePoint = char.codePointAt(0)
    if (codePoint !== undefined) {
      const glyphId = engine.getGlyphIdForCodepoint(codePoint)
      console.log(`Character: '${char}' (U+${codePoint.toString(16).toUpperCase().padStart(4, '0')}) - Glyph ID: ${glyphId}`)
      if (glyphId > 0) {
        const glyphInfo = engine.getGlyphInfo(glyphId)
        if (glyphInfo) {
          console.log(`  Advance Width: ${glyphInfo.advanceWidth}`)
          console.log(`  Left Side Bearing: ${glyphInfo.leftSideBearing}`)
          console.log(`  Has Outline: ${glyphInfo.hasOutline}`)
        }

        const glyphName = engine.getGlyphName(glyphId)
        if (glyphName) {
          console.log(`  Glyph Name: ${glyphName}`)
        }
      }
    }
  }

  engine.destroy()
}

main()

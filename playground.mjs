// import fs from 'fs'
import path from 'path'
import { ttf } from 'ttf.zig'

const TTF_PATH = path.join(process.cwd(), 'fonts', 'LXGWBright-Light.ttf')

async function main() {
  // const state = ttf.loadFont(new Uint8Array(fs.readFileSync(TTF_PATH)))
  const state = await ttf.loadFile(TTF_PATH)
  if (!state) {
    console.error('Failed to load font')
    return
  }
  console.log('✅ Font loaded successfully!')

  const metrics = ttf.getFontMetrics()

  if (metrics) {
    console.log('\n📊 Font Metrics:')
    console.log(`  Units per EM: ${metrics.unitsPerEm}`)
    console.log(`  Ascender: ${metrics.ascender}`)
    console.log(`  Descender: ${metrics.descender}`)
    console.log(`  Line Gap: ${metrics.lineGap}`)
    console.log(`  Max Advance Width: ${metrics.advanceWidthMax}`)
    console.log(`  Bounds: (${metrics.xMin}, ${metrics.yMin}) to (${metrics.xMax}, ${metrics.yMax})`)
  }

  console.log(`\n📏 Number of glyphs: ${ttf.getNumGlyphs()}`)
  console.log(`🔤 Is monospace: ${ttf.isMonospace()}`)

  const familyName = ttf.getFontName(1)

  if (familyName) {
    console.log(`📝 Font Family: ${familyName}`)
  }

  const testText = '绪方理奈'

  for (const char of testText) {
    const codePoint = char.codePointAt(0)
    if (codePoint !== undefined) {
      const glyphId = ttf.getGlyphIdForCodepoint(codePoint)
      console.log(`Character: '${char}' (U+${codePoint.toString(16).toUpperCase().padStart(4, '0')}) - Glyph ID: ${glyphId}`)
      if (glyphId > 0) {
        const glyphInfo = ttf.getGlyphInfo(glyphId)
        if (glyphInfo) {
          console.log(`  Advance Width: ${glyphInfo.advanceWidth}`)
          console.log(`  Left Side Bearing: ${glyphInfo.leftSideBearing}`)
          console.log(`  Has Outline: ${glyphInfo.hasOutline}`)
        }

        const glyphName = ttf.getGlyphName(glyphId)
        if (glyphName) {
          console.log(`  Glyph Name: ${glyphName}`)
        }
      }
    }
  }

  ttf.destroy()
}
main()

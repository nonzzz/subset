import { ttf } from 'ttf.zig'

let intsall = false
let debounceTimer: number | undefined

async function loadData() {
  const response = await fetch('/LXGWBright-Light.ttf')
  const arrayBuffer = await response.arrayBuffer()
  const fontData = new Uint8Array(arrayBuffer)
  const ok = ttf.loadFont(fontData)
  if (!ok) {
    throw new Error('Failed to load font')
  }
  intsall = true
}

const loadButton = document.getElementById('loadButton')
const input = document.querySelector('input')
const display = document.getElementById('display')

if (loadButton) {
  loadButton.addEventListener('click', () => {
    console.log('Load button clicked')
    loadData().catch((err) => console.error(err))
  })
}

const style = `
  .glyph-block {
    background: #f8f9fa;
    border-radius: 8px;
    margin: 8px 0;
    padding: 12px;
    box-shadow: 0 1px 4px #0001;
    font-family: monospace;
  }
  .glyph-block strong {
    color: #1976d2;
  }
  hr {
    border: none;
    border-top: 1px solid #eee;
    margin: 8px 0;
  }
`

const styleTag = document.createElement('style')
styleTag.textContent = style
document.head.appendChild(styleTag)

function renderGlyphs(text: string) {
  let html = ''
  for (const char of text) {
    const codePoint = char.codePointAt(0)
    if (codePoint !== undefined) {
      const glyphId = ttf.getGlyphIdForCodepoint(codePoint)
      html += `<div class="glyph-block"><strong>Char:</strong> '${char}' (U+${
        codePoint.toString(16).toUpperCase().padStart(4, '0')
      })<br><strong>Glyph ID:</strong> ${glyphId}`
      if (glyphId > 0) {
        const glyphInfo = ttf.getGlyphInfo(glyphId)
        if (glyphInfo) {
          html += `<br><strong>Advance Width:</strong> ${glyphInfo.advanceWidth}`
          html += `<br><strong>Left Side Bearing:</strong> ${glyphInfo.leftSideBearing}`
          html += `<br><strong>Has Outline:</strong> ${glyphInfo.hasOutline}`
        }
        const glyphName = ttf.getGlyphName(glyphId)
        if (glyphName) {
          html += `<br><strong>Glyph Name:</strong> ${glyphName}`
        }
      }
      html += '</div>'
    }
  }
  display!.innerHTML = html
}

if (input) {
  input.addEventListener('input', () => {
    if (!intsall) {
      display!.textContent = 'Please load the engine first'
      return
    }
    if (debounceTimer) { clearTimeout(debounceTimer) }
    debounceTimer = window.setTimeout(() => {
      renderGlyphs(input.value)
    }, 500)
  })
}

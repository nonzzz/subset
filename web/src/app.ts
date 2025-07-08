import { ttf } from 'ttf.zig'
import './style.css'

let fontLoaded = false
let debounceTimer: number | undefined

const app = document.getElementById('app')!
app.innerHTML = `
  <label class="custom-upload">
    <input id="font-upload" type="file" accept=".ttf,.otf,.woff,.woff2,application/font-sfnt,application/font-woff" hidden />
    <span id="upload-label">Upload Font File</span>
  </label>
  <span id="file-name"></span>
  <div id="loading" class="loading"></div>
  <div id="font-meta"></div>
  <input id="char-input" type="text" placeholder="Type characters to view glyph info" disabled />
  <div id="glyph-info"></div>
`

const upload = document.getElementById('font-upload') as HTMLInputElement
const fileName = document.getElementById('file-name')!
const loading = document.getElementById('loading')!
const fontMeta = document.getElementById('font-meta')!
const charInput = document.getElementById('char-input') as HTMLInputElement
const glyphInfo = document.getElementById('glyph-info')!

upload.addEventListener('change', () => {
  handleFontUpload().catch((err) => console.error(err))
})

function setLoading(msg: string | null) {
  loading.textContent = msg ?? ''
  loading.style.display = msg ? 'block' : 'none'
}

function renderFontMeta() {
  const nameIds = [
    { id: 0, label: 'Copyright' },
    { id: 1, label: 'Font Family' },
    { id: 2, label: 'Subfamily' },
    { id: 3, label: 'Unique Subfamily ID' },
    { id: 4, label: 'Full Font Name' },
    { id: 5, label: 'Version' },
    { id: 6, label: 'PostScript Name' },
    { id: 7, label: 'Trademark' },
    { id: 8, label: 'Manufacturer' },
    { id: 9, label: 'Designer' },
    { id: 10, label: 'Description' },
    { id: 11, label: 'Vendor URL' },
    { id: 12, label: 'Designer URL' },
    { id: 13, label: 'License' },
    { id: 14, label: 'License URL' },
    { id: 16, label: 'Typographic Family' },
    { id: 17, label: 'Typographic Subfamily' },
    { id: 18, label: 'Compatible Full' },
    { id: 19, label: 'Sample Text' }
  ]
  let nameHtml = ''
  for (const { id, label } of nameIds) {
    const val = ttf.getFontName?.(id)
    if (val) {
      nameHtml += `<strong>${label}:</strong> ${val}<br>`
    }
  }
  const numGlyphs = ttf.getNumGlyphs?.() ?? 0
  const isMono = ttf.isMonospace?.() ? 'Yes' : 'No'
  const metrics = ttf.getFontMetrics?.()
  fontMeta.innerHTML = `
    <div class="meta-block">
      ${nameHtml}
      <strong>Glyphs:</strong> ${numGlyphs}<br>
      <strong>Monospace:</strong> ${isMono}<br>
      ${
    metrics
      ? `
        <strong>Units per EM:</strong> ${metrics.unitsPerEm}<br>
        <strong>Ascender:</strong> ${metrics.ascender}<br>
        <strong>Descender:</strong> ${metrics.descender}<br>
        <strong>Line Gap:</strong> ${metrics.lineGap}<br>
        <strong>Max Advance Width:</strong> ${metrics.advanceWidthMax}<br>
        <strong>Bounds:</strong> (${metrics.xMin}, ${metrics.yMin}) to (${metrics.xMax}, ${metrics.yMax})<br>
      `
      : ''
  }
    </div>
    <hr>
  `
}

function renderGlyphInfo(text: string) {
  if (!fontLoaded) {
    glyphInfo.textContent = 'Please upload a font file first.'
    return
  }
  let html = ''
  for (const char of text) {
    const codePoint = char.codePointAt(0)
    if (codePoint !== undefined) {
      const glyphId = ttf.getGlyphIdForCodepoint(codePoint)
      html += `<div class="glyph-block"><strong>Char:</strong> '${char}' (U+${
        codePoint.toString(16).toUpperCase().padStart(4, '0')
      })<br><strong>Glyph ID:</strong> ${glyphId}`
      if (glyphId > 0) {
        const glyphInfoObj = ttf.getGlyphInfo(glyphId)
        if (glyphInfoObj) {
          html += `<br><strong>Advance Width:</strong> ${glyphInfoObj.advanceWidth}`
          html += `<br><strong>Left Side Bearing:</strong> ${glyphInfoObj.leftSideBearing}`
          html += `<br><strong>Has Outline:</strong> ${glyphInfoObj.hasOutline}`
        }
        const glyphName = ttf.getGlyphName(glyphId)
        if (glyphName) {
          html += `<br><strong>Glyph Name:</strong> ${glyphName}`
        }
      }
      html += '</div>'
    }
  }
  glyphInfo.innerHTML = html
}

async function handleFontUpload() {
  const file = upload.files?.[0]
  fileName.textContent = file?.name ?? ''
  if (!file) { return }
  setLoading('Loading font...')
  try {
    const arrayBuffer = await file.arrayBuffer()
    const fontData = new Uint8Array(arrayBuffer)
    const ok = ttf.loadFont(fontData)
    if (!ok) { throw new Error('Failed to load font') }
    fontLoaded = true
    setLoading(null)
    charInput.disabled = false
    renderFontMeta()
    glyphInfo.innerHTML = ''
  } catch (err) {
    setLoading(null)
    fontMeta.textContent = ''
    glyphInfo.textContent = 'Failed to load font: ' + (err instanceof Error ? err.message : String(err))
    charInput.disabled = true
  }
}

charInput.addEventListener('input', () => {
  if (debounceTimer) { window.clearTimeout(debounceTimer) }
  debounceTimer = window.setTimeout(() => {
    renderGlyphInfo(charInput.value)
  }, 200)
})

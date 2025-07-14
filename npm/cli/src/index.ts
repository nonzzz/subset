#!/usr/bin/env node

import { bold, cyan, dim, green, red, yellow } from 'ansis'
import { readFileSync, statSync, writeFileSync } from 'fs'
import mri from 'mri'
import { extname, resolve } from 'path'
import { globSync } from 'tinyglobby'
import { ttf } from 'ttf.zig'

interface CliOptions {
  content?: string[]
  font?: string
  output?: string
  help?: boolean
  version?: boolean
  verbose?: boolean
  ext?: string[]
}

const SUPPORTED_TEXT_EXTENSIONS = ['.txt', '.html', '.css', '.js', '.ts', '.jsx', '.tsx', '.vue', '.svelte', '.md']

function showHelp() {
  console.log(`
${bold(cyan('ttf-subset'))} - Extract font subsets based on text content

${bold('Usage:')}
  ttf-subset --content <glob> --font <font-file> --output <output-file>

${bold('Options:')}
  ${green('--content, -c')}    Glob pattern(s) for content files to scan
  ${green('--font, -f')}       Path to the font file (TTF/OTF)
  ${green('--output, -o')}     Output path for the subset font
  ${green('--ext')}            Additional file extensions to scan (default: .txt,.html,.css,.js,.ts,.jsx,.tsx,.vue,.svelte,.md)
  ${green('--verbose, -v')}    Enable verbose logging
  ${green('--help, -h')}       Show this help message
  ${green('--version')}        Show version

${bold('Examples:')}
  ${dim('# Extract subset from all text files in src directory')}
  ttf-subset --content "src/**/*" --font font.ttf --output font-subset.ttf

  ${dim('# Multiple content patterns')}
  ttf-subset -c "src/**/*" -c "pages/**/*" -f font.ttf -o subset.ttf

  ${dim('# Include additional file extensions')}
  ttf-subset -c "src/**/*" -f font.ttf -o subset.ttf --ext .php --ext .py

  ${dim('# Verbose output')}
  ttf-subset -c "src/**/*" -f font.ttf -o subset.ttf --verbose
`)
}

function logVerbose(message: string, verbose: boolean) {
  if (verbose) {
    console.log(dim(`[verbose] ${message}`))
  }
}

function extractTextFromFile(filePath: string, verbose: boolean): string {
  try {
    const content = readFileSync(filePath, 'utf-8')
    logVerbose(`Read file: ${filePath} (${content.length} chars)`, verbose)
    return content
  } catch {
    console.warn(yellow(`Warning: Could not read file ${filePath}`))
    return ''
  }
}

function shouldProcessFile(filePath: string, extensions: string[]): boolean {
  const ext = extname(filePath).toLowerCase()
  return extensions.includes(ext)
}

function collectTextFromFiles(patterns: string[], extensions: string[], verbose: boolean): string {
  const allText: string[] = []
  const processedFiles = new Set<string>()

  for (const pattern of patterns) {
    logVerbose(`Scanning pattern: ${pattern}`, verbose)

    try {
      const files = globSync(pattern)
      logVerbose(`Found ${files.length} files for pattern: ${pattern}`, verbose)

      for (const file of files) {
        const resolvedPath = resolve(file)

        if (processedFiles.has(resolvedPath)) {
          continue
        }

        if (!shouldProcessFile(file, extensions)) {
          logVerbose(`Skipping file (unsupported extension): ${file}`, verbose)
          continue
        }

        try {
          const stat = statSync(resolvedPath)
          if (!stat.isFile()) {
            continue
          }

          const text = extractTextFromFile(resolvedPath, verbose)
          if (text.trim()) {
            allText.push(text)
            processedFiles.add(resolvedPath)
          }
        } catch (error) {
          if (error instanceof Error) {
            logVerbose(`Error processing file ${file}: ${error}`, verbose)
          }
        }
      }
    } catch (error) {
      if (error instanceof Error) {
        console.warn(yellow(`Warning: Error processing pattern "${pattern}": ${error}`))
      }
    }
  }

  const combinedText = allText.join('\n')
  console.log(green(`✓ Processed ${processedFiles.size} files`))
  logVerbose(`Total text length: ${combinedText.length} characters`, verbose)

  return combinedText
}

function getUniqueCharacters(text: string): Set<string> {
  return new Set(text)
}

function formatFileSize(bytes: number): string {
  if (bytes < 1024) { return `${bytes} B` }
  if (bytes < 1024 * 1024) { return `${(bytes / 1024).toFixed(1)} KB` }
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

function main() {
  const args = mri<CliOptions>(process.argv.slice(2), {
    alias: {
      c: 'content',
      f: 'font',
      o: 'output',
      h: 'help',
      v: 'verbose'
    },
    default: {
      ext: []
    }
  })

  const options: CliOptions = {
    content: Array.isArray(args.content) ? args.content : args.content ? [args.content] : undefined,
    font: args.font,
    output: args.output,
    help: args.help,
    verbose: args.verbose,
    ext: Array.isArray(args.ext) ? args.ext : args.ext ? [args.ext] : []
  }

  if (options.help) {
    showHelp()
    return
  }

  if (!options.content || options.content.length === 0) {
    console.error(red('Error: --content option is required'))
    console.log('\nUse --help for usage information')
    process.exit(1)
  }

  if (!options.font) {
    console.error(red('Error: --font option is required'))
    console.log('\nUse --help for usage information')
    process.exit(1)
  }

  if (!options.output) {
    console.error(red('Error: --output option is required'))
    console.log('\nUse --help for usage information')
    process.exit(1)
  }

  try {
    const fontPath = resolve(options.font)
    const fontStat = statSync(fontPath)
    if (!fontStat.isFile()) {
      console.error(red(`Error: Font file not found: ${fontPath}`))
      process.exit(1)
    }

    console.log(cyan(`Starting font subset extraction...`))
    console.log(`Font: ${bold(fontPath)} (${formatFileSize(fontStat.size)})`)
    console.log(`Output: ${bold(resolve(options.output))}`)

    const extensions: string[] = [...SUPPORTED_TEXT_EXTENSIONS, ...options.ext || []]
    logVerbose(`Supported extensions: ${extensions.join(', ')}`, options.verbose || false)

    console.log(yellow('Scanning content files...'))
    const allText = collectTextFromFiles(options.content, extensions, options.verbose || false)

    if (!allText.trim()) {
      console.warn(yellow('Warning: No text content found in specified files'))
      return
    }
    const uniqueChars = getUniqueCharacters(allText)
    const filteredChars = Array.from(uniqueChars).filter(
      (c) => c >= ' ' && c !== '\u007f'
    )
    console.log(green(`✓ Found ${uniqueChars.size} unique characters`))

    if (options.verbose) {
      const charPreview = Array.from(uniqueChars).slice(0, 50).join('')
      logVerbose(`Character preview: ${charPreview}${uniqueChars.size > 50 ? '...' : ''}`, true)
    }

    console.log(yellow('Creating font subset...'))
    const fontData = readFileSync(fontPath)
    const textToSubset = filteredChars.join('')

    logVerbose('Loading font with WASM engine...', options.verbose || false)

    if (!ttf.loadFont(fontData)) {
      console.error(red('Error: Failed to load font file'))
      process.exit(1)
    }

    if (!ttf.createSubset()) {
      console.error(red('Error: Failed to create font subset'))
      process.exit(1)
    }
    logVerbose('Adding characters to subset...', options.verbose || false)
    if (!ttf.addTextToSubset(textToSubset)) {
      console.error(red('Error: Failed to add text to subset'))
      process.exit(1)
    }

    logVerbose('Generating subset font...', options.verbose || false)
    const subsetFont = ttf.generateSubsetFont()

    if (!subsetFont) {
      console.error(red('Error: Failed to generate subset font'))
      process.exit(1)
    }

    const outputPath = resolve(options.output)
    writeFileSync(outputPath, subsetFont)

    const originalSize = fontStat.size
    const subsetSize = subsetFont.length
    const reduction = ((1 - subsetSize / originalSize) * 100).toFixed(1)

    console.log(green('✓ Font subset created successfully!'))
    console.log(`Original size: ${bold(formatFileSize(originalSize))}`)
    console.log(`Subset size: ${bold(formatFileSize(subsetSize))}`)
    console.log(`Size reduction: ${bold(green(`${reduction}%`))}`)
    console.log(`Output: ${bold(outputPath)}`)

    ttf.destroy()
  } catch (error) {
    console.error(error)
    process.exit(1)
  }
}

main()

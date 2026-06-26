import { useEffect, useRef } from 'react'
import { Terminal as XTerm } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import { openpty } from 'xterm-pty'
import { startQemu, stopQemu } from '../lib/qemu'
import type { QemuModule } from '../lib/qemu'

const DIM = '\x1b[90m'
const RESET = '\x1b[0m'
const ERR = '\x1b[1;37m'

const MONO = '#a1a1aa'
const MONO_BRIGHT = '#e4e4e7'
const MONO_DIM = '#52525b'
const BG = '#09090b'

export default function Terminal() {

  const containerRef = useRef<HTMLDivElement>(null)
  const termRef = useRef<XTerm | null>(null)

  useEffect(() => {

    const el = containerRef.current
    if (!el || termRef.current) return

    const term = new XTerm({

      theme: {

        background: BG,
        foreground: MONO,
        cursor: MONO_BRIGHT,
        cursorAccent: BG,
        selectionBackground: '#3f3f46',
        selectionForeground: MONO_BRIGHT,
        black: BG,
        red: MONO,
        green: MONO,
        yellow: MONO_BRIGHT,
        blue: MONO,
        magenta: MONO,
        cyan: MONO,
        white: MONO_BRIGHT,
        brightBlack: MONO_DIM,
        brightRed: MONO_BRIGHT,
        brightGreen: MONO_BRIGHT,
        brightYellow: MONO_BRIGHT,
        brightBlue: MONO_BRIGHT,
        brightMagenta: MONO_BRIGHT,
        brightCyan: MONO_BRIGHT,
        brightWhite: '#f4f4f5',

      },

      fontFamily: '"JetBrains Mono", ui-monospace, monospace',
      fontSize: 15,
      lineHeight: 1.5,
      cursorBlink: true,
      cursorStyle: 'block',

    })

    const fit = new FitAddon()

    term.loadAddon(fit)
    term.open(el)
    fit.fit()

    termRef.current = term

    const ro = new ResizeObserver(() => fit.fit())
    ro.observe(el)

    let active = true
    let statusLine = false

    const setStatus = (msg: string) => {

      if (!active) return

      const text = `${DIM}${msg}${RESET}`
      term.write(statusLine ? `\r\x1b[K${text}` : text)
      statusLine = true

    }

    const clearStatus = () => {

      if (!active || !statusLine) return
      term.write('\r\x1b[K')
      statusLine = false

    }

    const { master, slave } = openpty()
    term.loadAddon(master)

    let qemu: QemuModule | null = null

    const onHidden = () => {

      if (document.hidden) term.options.cursorBlink = false
      else term.options.cursorBlink = true

    }
    document.addEventListener('visibilitychange', onHidden)

    startQemu(slave, setStatus).then((mod) => {

      qemu = mod
      if (active) clearStatus()

    }).catch((err: unknown) => {

      console.error('[terminal] QEMU failed:', err)

      if (active) {

        clearStatus()

        const detail = err instanceof Error ? err.message : String(err)
        term.writeln(`${ERR}[web] QEMU failed: ${detail}${RESET}`)

      }

    })

    return () => {

      active = false

      document.removeEventListener('visibilitychange', onHidden)

      stopQemu(qemu).finally(() => {

        ro.disconnect()
        term.dispose()
        termRef.current = null

      })

    }

  }, [])

  return <div ref={containerRef} className="w-full h-full p-3" />

}

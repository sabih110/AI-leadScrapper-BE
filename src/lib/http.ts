import type { ErrorRequestHandler } from 'express'
import { ZodError } from 'zod'

/** Errors with a status and a plain-language message safe to show users. */
export class HttpError extends Error {
  constructor(
    public status: number,
    message: string,
    public code?: string,
  ) {
    super(message)
  }
}

/** The frontend reads `message` from every error body. */
export const errorHandler: ErrorRequestHandler = (err, req, res, _next) => {
  if (err instanceof ZodError) {
    res.status(400).json({ message: err.issues[0]?.message ?? 'Invalid request', code: 'validation_error' })
    return
  }
  if (err instanceof HttpError) {
    res.status(err.status).json({ message: err.message, code: err.code })
    return
  }
  // Malformed JSON body
  if ((err as { type?: string }).type === 'entity.parse.failed') {
    res.status(400).json({ message: 'Invalid JSON body', code: 'bad_json' })
    return
  }
  req.log?.error({ err }, 'unhandled error')
  res.status(500).json({ message: 'Something went wrong on our side. Please try again.', code: 'internal' })
}

/** Minimal Cookie header parser (avoids a dependency for one cookie). */
export function readCookie(header: string | undefined, name: string): string | undefined {
  if (!header) return undefined
  for (const part of header.split(';')) {
    const i = part.indexOf('=')
    if (i > -1 && part.slice(0, i).trim() === name) return decodeURIComponent(part.slice(i + 1).trim())
  }
  return undefined
}

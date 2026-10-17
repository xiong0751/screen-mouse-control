/**
 * Host half of the @local/screen-mouse-control bundle.
 *
 * Registers agent tools that capture the screen, read it (OCR), and drive the
 * mouse through small PowerShell engines (powershell/control.ps1 for capture +
 * mouse, powershell/vision.ps1 for capture + OCR + click) so the agent can look
 * at the screen and operate the computer on Windows.
 */
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { readFile, mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { tmpdir } from 'node:os';

const execFileAsync = promisify(execFile);

const HERE = dirname(fileURLToPath(import.meta.url));
const CONTROL_PS1 = join(HERE, 'powershell', 'control.ps1');
const VISION_PS1 = join(HERE, 'powershell', 'vision.ps1');

export const inject = ['tools', 'attachments'];

// ---------------------------------------------------------------------------
// PowerShell engine
// ---------------------------------------------------------------------------

function findPowerShellCandidates() {
  const sysRoot = process.env.SystemRoot || process.env.WINDIR;
  const candidates = [];
  if (sysRoot) {
    candidates.push(join(sysRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'));
  }
  candidates.push('powershell.exe');
  return candidates;
}

function parseResult(stdout, stderr) {
  const text = String(stdout || '');
  const start = text.indexOf('{');
  const end = text.lastIndexOf('}');
  if (start === -1 || end === -1 || end <= start) {
    const detail = stderr ? ' stderr: ' + String(stderr).slice(0, 500) : '';
    throw new Error('PowerShell produced no JSON result.' + detail);
  }
  let parsed;
  try {
    parsed = JSON.parse(text.slice(start, end + 1));
  } catch {
    throw new Error('Failed to parse PowerShell output: ' + text.slice(0, 500));
  }
  if (parsed && parsed.ok === false) {
    const err = new Error(parsed.error || 'PowerShell action failed');
    err.code = 'PS_ACTION_FAILED';
    throw err;
  }
  return parsed;
}

async function runPowerShell(ps1Path, env, signal) {
  const args = ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ps1Path];
  let lastError;
  for (const ps of findPowerShellCandidates()) {
    try {
      const { stdout, stderr } = await execFileAsync(ps, args, {
        encoding: 'utf8',
        maxBuffer: 128 * 1024 * 1024,
        windowsHide: true,
        timeout: 30000,
        signal,
        env: { ...process.env, ...env },
      });
      return parseResult(stdout, stderr);
    } catch (err) {
      lastError = err;
      if (signal && signal.aborted) throw err;
      if (err && err.code === 'ENOENT') continue; // try next candidate
      throw err;
    }
  }
  throw lastError || new Error('powershell.exe not found on this system');
}

function textBlock(text) {
  return { type: 'text', text };
}

function toInt(value, name, fallback) {
  if (value === undefined || value === null || value === '') return fallback;
  const n = Number(value);
  if (!Number.isFinite(n)) throw new Error(`${name} must be a finite number`);
  return Math.round(n);
}

function textOutput(schema) {
  return {
    schema,
    render(_args, value) {
      return [textBlock(typeof value === 'string' ? value : JSON.stringify(value))];
    },
  };
}

const regionSchema = {
  type: 'object',
  description: 'Optional rectangular region in screen pixels. Omit for the full primary screen.',
  additionalProperties: false,
  required: ['x', 'y', 'width', 'height'],
  properties: {
    x: { type: 'integer', description: 'Left edge, in screen pixels.' },
    y: { type: 'integer', description: 'Top edge, in screen pixels.' },
    width: { type: 'integer', description: 'Region width in pixels.' },
    height: { type: 'integer', description: 'Region height in pixels.' },
  },
};

function applyRegionEnv(args, env) {
  if (args.region) {
    env.SM_REGION = JSON.stringify({
      x: toInt(args.region.x, 'region.x'),
      y: toInt(args.region.y, 'region.y'),
      width: toInt(args.region.width, 'region.width'),
      height: toInt(args.region.height, 'region.height'),
    });
  }
}

// ---------------------------------------------------------------------------
// Tools
// ---------------------------------------------------------------------------

function screenCaptureTool(ctx) {
  return {
    name: 'screen_capture',
    description:
      'Capture the computer screen (or a region of it) and return the image so you can see it. ' +
      'Coordinates are in the same pixel space used by mouse_move / mouse_click, and match the pixels of the returned image.',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {
        region: regionSchema,
        all_screens: {
          type: 'boolean',
          description: 'Capture the full virtual desktop spanning all monitors. Defaults to false (primary screen only).',
          default: false,
        },
        max_dimension: {
          type: 'integer',
          description: 'Resize so the longest side is at most this many pixels (default 1920). Larger is sharper but heavier.',
          default: 1920,
        },
        format: {
          type: 'string',
          enum: ['png', 'jpeg'],
          description: 'Output format. PNG is lossless; JPEG is smaller. Default png.',
          default: 'png',
        },
        save_path: {
          type: 'string',
          description: 'Optional absolute path to also save the file to. Defaults to a temp file.',
        },
      },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: true,
        properties: {
          ok: { type: 'boolean' },
          path: { type: 'string' },
          width: { type: 'integer' },
          height: { type: 'integer' },
          bytes: { type: 'integer' },
          format: { type: 'string' },
        },
      },
      render(_args, value) {
        const blocks = [];
        if (value && value.attachment) {
          blocks.push({ type: 'image', attachment: value.attachment });
        }
        blocks.push(
          textBlock(
            `Screenshot saved to ${value.path} (${value.width}x${value.height}, ${value.bytes} bytes, ${value.format}).`,
          ),
        );
        return blocks;
      },
    },
    async execute(args, exec) {
      const format = args.format === 'jpeg' ? 'jpeg' : 'png';
      const allScreens = !!args.all_screens;
      let maxDim = toInt(args.max_dimension, 'max_dimension', 1920);

      // Respect the deployment's image limits so the attachment is accepted.
      const limits = ctx.attachments.imageLimits;
      if (limits) {
        if (Number.isFinite(limits.maxImageDimension)) maxDim = Math.min(maxDim, limits.maxImageDimension);
        if (Number.isFinite(limits.maxImagePixels)) maxDim = Math.min(maxDim, Math.floor(Math.sqrt(limits.maxImagePixels)));
      }
      maxDim = Math.max(1, maxDim);

      const outDir = join(tmpdir(), 'dsh-screen-mouse');
      await mkdir(outDir, { recursive: true });
      const ext = format === 'jpeg' ? 'jpg' : 'png';
      const outPath = args.save_path || join(outDir, `capture-${Date.now()}.${ext}`);

      const env = {
        SM_ACTION: 'capture',
        SM_OUT: outPath,
        SM_FORMAT: format,
        SM_MAX_DIM: String(maxDim),
        SM_JPEG_QUALITY: '85',
        SM_ALL: allScreens ? '1' : '0',
      };
      applyRegionEnv(args, env);

      const result = await runPowerShell(CONTROL_PS1, env, exec.signal);

      const attach = async (path, mediaType, name) => {
        const bytes = await readFile(path);
        const ref = await ctx.attachments.saveImage({
          data: new Uint8Array(bytes),
          mediaType,
          name,
        });
        return { ref, bytes: bytes.length };
      };

      let attachment;
      let finalPath = result.path || outPath;
      let finalMediaType = format === 'jpeg' ? 'image/jpeg' : 'image/png';
      let finalBytes = result.bytes;

      try {
        const a = await attach(finalPath, finalMediaType, `screenshot-${Date.now()}.${ext}`);
        attachment = a.ref;
        finalBytes = a.bytes;
      } catch (imgErr) {
        // PNG too large for the attachment limit -> retry once as a smaller JPEG.
        if (finalMediaType === 'image/png') {
          const jpegPath = finalPath.replace(/\.png$/i, '.jpg');
          const jpegEnv = { ...env, SM_FORMAT: 'jpeg', SM_OUT: jpegPath, SM_MAX_DIM: String(Math.min(maxDim, 1440)) };
          const jpegResult = await runPowerShell(CONTROL_PS1, jpegEnv, exec.signal);
          const a = await attach(jpegPath, 'image/jpeg', `screenshot-${Date.now()}.jpg`);
          attachment = a.ref;
          finalPath = jpegResult.path || jpegPath;
          finalMediaType = 'image/jpeg';
          finalBytes = a.bytes;
          finalPath = jpegPath;
        } else {
          throw imgErr;
        }
      }

      return {
        ok: true,
        path: finalPath,
        width: result.width,
        height: result.height,
        bytes: finalBytes,
        format: finalMediaType === 'image/jpeg' ? 'jpeg' : 'png',
        attachment,
      };
    },
  };
}

function screenOcrTool() {
  return {
    name: 'screen_ocr',
    description:
      'Capture the screen and OCR it in one step. Returns the recognized text plus every word\'s ' +
      'clickable center (cx, cy) in screen pixel coordinates. Use this instead of screen_capture + a separate OCR pass to read the screen quickly.',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {
        region: regionSchema,
        all_screens: { type: 'boolean', description: 'Read the full virtual desktop. Default false (primary screen).', default: false },
        max_dimension: {
          type: 'integer',
          description: 'Cap the OCR resolution (longest side). Lower is faster; coordinates are still returned in screen pixels. Default 1920.',
          default: 1920,
        },
      },
    },
    output: {
      schema: { type: 'object', additionalProperties: true },
      render(_args, value) {
        const blocks = [];
        if (value && value.text) blocks.push(textBlock(value.text));
        if (value && Array.isArray(value.words) && value.words.length) {
          blocks.push(textBlock(value.words.map((w) => `${w.text}@${w.cx},${w.cy}`).join(' ')));
        }
        return blocks.length ? blocks : [textBlock(JSON.stringify(value))];
      },
    },
    async execute(args, exec) {
      const env = {
        SM_ACTION: 'ocr',
        SM_MAX_DIM: String(toInt(args.max_dimension, 'max_dimension', 1920)),
        SM_ALL: args.all_screens ? '1' : '0',
      };
      applyRegionEnv(args, env);
      return runPowerShell(VISION_PS1, env, exec.signal);
    },
  };
}

function clickTextTool() {
  return {
    name: 'click_text',
    description:
      'Capture the screen, OCR it, find the target text, and click its center — all in one step. ' +
      'Optionally offset the click (e.g. to hit an icon a few pixels above/below some text) and double-click.',
    parameters: {
      type: 'object',
      additionalProperties: false,
      required: ['text'],
      properties: {
        text: { type: 'string', description: 'Text to find and click (case-insensitive substring; may span several words).' },
        offset_x: { type: 'integer', description: 'Click offset in screen pixels from the matched text center. Default 0.', default: 0 },
        offset_y: { type: 'integer', description: 'Click offset in screen pixels from the matched text center. Default 0.', default: 0 },
        button: { type: 'string', enum: ['left', 'right', 'middle'], description: 'Default left.', default: 'left' },
        double: { type: 'boolean', description: 'Double click. Default false.', default: false },
        region: regionSchema,
        max_dimension: { type: 'integer', description: 'OCR resolution cap. Default 1920.', default: 1920 },
      },
    },
    output: textOutput({ type: 'object', additionalProperties: true }),
    async execute(args, exec) {
      const env = {
        SM_ACTION: 'click_text',
        SM_TARGET: String(args.text),
        SM_OFFSET_X: String(toInt(args.offset_x, 'offset_x', 0)),
        SM_OFFSET_Y: String(toInt(args.offset_y, 'offset_y', 0)),
        SM_BUTTON: args.button === 'right' ? 'right' : args.button === 'middle' ? 'middle' : 'left',
        SM_DOUBLE: args.double ? '1' : '0',
        SM_MAX_DIM: String(toInt(args.max_dimension, 'max_dimension', 1920)),
      };
      applyRegionEnv(args, env);
      return runPowerShell(VISION_PS1, env, exec.signal);
    },
  };
}

function computerInfoTool() {
  return {
    name: 'computer_info',
    description: 'Report the screen bounds (primary and virtual) and the current mouse cursor position. Useful for planning mouse actions.',
    parameters: { type: 'object', additionalProperties: false, properties: {} },
    output: textOutput({
      type: 'object',
      additionalProperties: true,
      properties: {
        ok: { type: 'boolean' },
        primary: { type: 'object' },
        virtual: { type: 'object' },
        cursor: { type: 'object' },
      },
    }),
    async execute(_args, exec) {
      return runPowerShell(CONTROL_PS1, { SM_ACTION: 'info' }, exec.signal);
    },
  };
}

function mouseMoveTool() {
  return {
    name: 'mouse_move',
    description:
      'Move the mouse cursor to an absolute screen position (x, y) in the same pixel space as screen_capture.',
    parameters: {
      type: 'object',
      additionalProperties: false,
      required: ['x', 'y'],
      properties: {
        x: { type: 'integer', description: 'Target x in screen pixels.' },
        y: { type: 'integer', description: 'Target y in screen pixels.' },
        duration_ms: { type: 'integer', description: 'Optional smooth-move duration in milliseconds (default 0 = instant).', default: 0 },
      },
    },
    output: textOutput({ type: 'object', additionalProperties: true }),
    async execute(args, exec) {
      const env = {
        SM_ACTION: 'move',
        SM_X: String(toInt(args.x, 'x')),
        SM_Y: String(toInt(args.y, 'y')),
        SM_DURATION_MS: String(toInt(args.duration_ms, 'duration_ms', 0)),
      };
      return runPowerShell(CONTROL_PS1, env, exec.signal);
    },
  };
}

function mouseClickTool() {
  return {
    name: 'mouse_click',
    description:
      'Click the mouse. Click at the current position, or move to (x, y) first. Supports left/right/middle buttons and single or double click.',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {
        button: { type: 'string', enum: ['left', 'right', 'middle'], description: 'Mouse button. Default left.', default: 'left' },
        x: { type: 'integer', description: 'Optional; move here before clicking.' },
        y: { type: 'integer', description: 'Optional; move here before clicking.' },
        double: { type: 'boolean', description: 'Double click instead of single. Default false.', default: false },
        delay_ms: { type: 'integer', description: 'Press/release delay in milliseconds. Default 50.', default: 50 },
      },
    },
    output: textOutput({ type: 'object', additionalProperties: true }),
    async execute(args, exec) {
      const env = {
        SM_ACTION: 'click',
        SM_BUTTON: args.button === 'right' ? 'right' : args.button === 'middle' ? 'middle' : 'left',
        SM_CLICKS: args.double ? '2' : '1',
        SM_DELAY_MS: String(toInt(args.delay_ms, 'delay_ms', 50)),
      };
      if (args.x !== undefined || args.y !== undefined) {
        env.SM_X = String(toInt(args.x, 'x', 0));
        env.SM_Y = String(toInt(args.y, 'y', 0));
      }
      return runPowerShell(CONTROL_PS1, env, exec.signal);
    },
  };
}

function mouseDragTool() {
  return {
    name: 'mouse_drag',
    description: 'Press the mouse button at (x1, y1), drag to (x2, y2), and release. Useful for selecting text, moving windows, and drag-and-drop.',
    parameters: {
      type: 'object',
      additionalProperties: false,
      required: ['x1', 'y1', 'x2', 'y2'],
      properties: {
        x1: { type: 'integer' },
        y1: { type: 'integer' },
        x2: { type: 'integer' },
        y2: { type: 'integer' },
        button: { type: 'string', enum: ['left', 'right', 'middle'], description: 'Default left.', default: 'left' },
        duration_ms: { type: 'integer', description: 'Drag animation duration in milliseconds. Default 200.', default: 200 },
      },
    },
    output: textOutput({ type: 'object', additionalProperties: true }),
    async execute(args, exec) {
      const env = {
        SM_ACTION: 'drag',
        SM_X1: String(toInt(args.x1, 'x1')),
        SM_Y1: String(toInt(args.y1, 'y1')),
        SM_X2: String(toInt(args.x2, 'x2')),
        SM_Y2: String(toInt(args.y2, 'y2')),
        SM_BUTTON: args.button === 'right' ? 'right' : args.button === 'middle' ? 'middle' : 'left',
        SM_DURATION_MS: String(toInt(args.duration_ms, 'duration_ms', 200)),
      };
      return runPowerShell(CONTROL_PS1, env, exec.signal);
    },
  };
}

function mouseScrollTool() {
  return {
    name: 'mouse_scroll',
    description:
      'Scroll the mouse wheel. Positive amount scrolls up, negative scrolls down. Optionally move to (x, y) first so the scroll targets the window under the cursor.',
    parameters: {
      type: 'object',
      additionalProperties: false,
      required: ['amount'],
      properties: {
        amount: { type: 'integer', description: 'Number of wheel clicks; positive = up, negative = down (e.g. 3 or -3).' },
        horizontal: { type: 'boolean', description: 'Scroll horizontally instead of vertically. Default false.', default: false },
        x: { type: 'integer', description: 'Optional; move here before scrolling.' },
        y: { type: 'integer', description: 'Optional; move here before scrolling.' },
      },
    },
    output: textOutput({ type: 'object', additionalProperties: true }),
    async execute(args, exec) {
      const env = {
        SM_ACTION: 'scroll',
        SM_AMOUNT: String(toInt(args.amount, 'amount')),
        SM_HORIZONTAL: args.horizontal ? '1' : '0',
      };
      if (args.x !== undefined || args.y !== undefined) {
        env.SM_X = String(toInt(args.x, 'x', 0));
        env.SM_Y = String(toInt(args.y, 'y', 0));
      }
      return runPowerShell(CONTROL_PS1, env, exec.signal);
    },
  };
}

// ---------------------------------------------------------------------------
// apply
// ---------------------------------------------------------------------------

export function apply(ctx) {
  const disposers = [
    ctx.tools.register(screenCaptureTool(ctx)),
    ctx.tools.register(screenOcrTool()),
    ctx.tools.register(clickTextTool()),
    ctx.tools.register(computerInfoTool()),
    ctx.tools.register(mouseMoveTool()),
    ctx.tools.register(mouseClickTool()),
    ctx.tools.register(mouseDragTool()),
    ctx.tools.register(mouseScrollTool()),
  ];
  return () => {
    for (const dispose of disposers) dispose();
  };
}

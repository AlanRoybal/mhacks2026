// JSON lines in Lambda (CloudWatch Insights can query fields), readable lines locally.

type Fields = Record<string, unknown>;

export interface Logger {
  info(msg: string, fields?: Fields): void;
  warn(msg: string, fields?: Fields): void;
  error(msg: string, fields?: Fields): void;
}

function errorFields(fields?: Fields): Fields | undefined {
  if (!fields) return fields;
  const out: Fields = {};
  for (const [k, v] of Object.entries(fields)) out[k] = v instanceof Error ? { name: v.name, message: v.message, stack: v.stack } : v;
  return out;
}

export function createLogger(json = Boolean(process.env.AWS_LAMBDA_FUNCTION_NAME)): Logger {
  const write = (level: string, msg: string, fields?: Fields) => {
    const f = errorFields(fields);
    if (json) {
      console.log(JSON.stringify({ level, msg, ...f }));
    } else {
      const extra = f && Object.keys(f).length ? ` ${JSON.stringify(f)}` : "";
      (level === "error" ? console.error : console.log)(`[${level}] ${msg}${extra}`);
    }
  };
  return {
    info: (msg, fields) => write("info", msg, fields),
    warn: (msg, fields) => write("warn", msg, fields),
    error: (msg, fields) => write("error", msg, fields),
  };
}

export const silentLogger: Logger = { info: () => {}, warn: () => {}, error: () => {} };

// endpoints.ts — the endpoint spec language shared by the host-side
// bridges and the guest agents.
//
//   unix:/path              Unix socket (listen or connect) — mac/Ubuntu guests,
//                           host agent/docker sockets
//   pipe:openssh-ssh-agent  Windows named pipe (\\.\pipe\name; the short form
//                           is normalized) — Windows guests
//   tcp:host:port           TCP (listen: host+port is the bind address; connect:
//                           host+port is the target) — host side and guest->host
//
// A single spec form works for both roles: the meaning follows from whether
// the endpoint is the --listen or the --forward side.

export type Endpoint =
  | { kind: 'unix'; path: string }
  | { kind: 'pipe'; name: string }
  | { kind: 'tcp'; host: string; port: number };

const PIPE_PREFIX = '\\\\.\\pipe\\';

/** Parses an endpoint spec; throws on unknown scheme or bad values. */
export function parseEndpoint(spec: string): Endpoint {
  const sep = spec.indexOf(':');
  if (sep <= 0) {
    throw new Error(`invalid endpoint '${spec}' (expected unix:|pipe:|tcp:)`);
  }
  const scheme = spec.slice(0, sep);
  const rest = spec.slice(sep + 1);

  switch (scheme) {
    case 'unix': {
      if (!rest) {
        throw new Error(`invalid unix endpoint '${spec}': missing path`);
      }
      return { kind: 'unix', path: rest };
    }
    case 'pipe': {
      if (!rest) {
        throw new Error(`invalid pipe endpoint '${spec}': missing name`);
      }
      const name = rest.startsWith(PIPE_PREFIX) ? rest : `${PIPE_PREFIX}${rest}`;
      return { kind: 'pipe', name };
    }
    case 'tcp': {
      const m = /^([^:]+):(\d+)$/.exec(rest);
      const port = m ? Number(m[2]) : NaN;
      if (!m || !Number.isInteger(port) || port < 1 || port > 65535) {
        throw new Error(`invalid tcp endpoint '${spec}' (expected tcp:host:port, port 1-65535)`);
      }
      return { kind: 'tcp', host: m[1], port };
    }
    default:
      throw new Error(
        `unknown endpoint scheme '${scheme}' in '${spec}' (expected unix:|pipe:|tcp:)`,
      );
  }
}

/** The human-readable form of an endpoint (logs, status lines). */
export function formatEndpoint(endpoint: Endpoint): string {
  switch (endpoint.kind) {
    case 'unix':
      return `unix:${endpoint.path}`;
    case 'pipe':
      return `pipe:${endpoint.name}`;
    case 'tcp':
      return `tcp:${endpoint.host}:${endpoint.port}`;
  }
}

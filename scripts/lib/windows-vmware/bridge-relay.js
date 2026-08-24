// bridge-relay.js -- the sandbox bridge relay (guest side).
//
// Serves a Windows named pipe (argv[2]) and forwards every connection to
// the TCP endpoint argv[3]:argv[4]. Node is in the image, and
// net.createServer().listen('\\.\pipe\...') is a native Windows named-pipe
// server, so no extra binaries are needed. (npiperelay cannot do this: its
// -ep/-s flags are EOF-handling options, and it only CONNECTS to existing
// pipes.) The relay is started twice (once per bridge) by
// start-relays.cmd, with C:\tools\bridge-relay.js as the first argument.
//
// Usage: node.exe bridge-relay.js <pipe> <host> <port>
//
// Rendered by scripts/run-windows-vmware-sandbox.sh into C:\tools; this
// file is the template's static source (no placeholders).
var net = require('net');
var pipe = process.argv[2];
var host = process.argv[3];
var port = Number(process.argv[4]);
net.createServer(function (c) {
  var up = net.connect(port, host, function () {
    c.pipe(up);
    up.pipe(c);
  });
  c.on('error', function () { up.destroy(); });
  up.on('error', function () { c.destroy(); });
}).listen(pipe);

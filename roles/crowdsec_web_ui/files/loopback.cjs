'use strict';
// Preloaded into the CrowdSec Web UI (NODE_OPTIONS=--require=...), managed by Ansible.
// The app listens on all interfaces and has no setting for the address. With host
// networking that would expose it on the network, so every TCP listen on a port
// is bound to 127.0.0.1 instead.
const net = require('node:net');

const listen = net.Server.prototype.listen;

net.Server.prototype.listen = function (...args) {
  const first = args[0];
  if (typeof first === 'number' || (typeof first === 'string' && /^[0-9]+$/.test(first))) {
    // listen(port[, host][, backlog][, callback])
    const second = args[1];
    if (typeof second === 'string' || second === undefined || second === null) {
      args[1] = '127.0.0.1';
    } else {
      args.splice(1, 0, '127.0.0.1');
    }
  } else if (first !== null && typeof first === 'object' && first.port !== undefined) {
    args[0] = { ...first, host: '127.0.0.1' };
  }
  return listen.apply(this, args);
};

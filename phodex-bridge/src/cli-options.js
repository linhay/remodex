// FILE: cli-options.js
// Purpose: Parses the minimal Remodex CLI argument surface.
// Layer: CLI helper
// Exports: parseCliArgs

function parseCliArgs(argv) {
  const args = Array.isArray(argv) ? [...argv] : [];
  const command = args.shift() || "up";
  const options = {
    tryCloudflare: false,
    tryCloudflarePort: 0,
  };
  const positionals = [];

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];

    if (arg === "--") {
      continue;
    }

    if (arg === "--trycloudflare") {
      assertTryCloudflareCommand(command, arg);
      options.tryCloudflare = true;
      continue;
    }

    if (arg === "--trycloudflare-port") {
      assertTryCloudflareCommand(command, arg);
      options.tryCloudflarePort = parsePortNumber(args[index + 1], "--trycloudflare-port");
      index += 1;
      continue;
    }

    if (arg.startsWith("--trycloudflare-port=")) {
      assertTryCloudflareCommand(command, "--trycloudflare-port");
      const [, value] = arg.split("=", 2);
      options.tryCloudflarePort = parsePortNumber(value, "--trycloudflare-port");
      continue;
    }

    if (arg.startsWith("--")) {
      throw new Error(`Unknown option: ${arg}`);
    }

    positionals.push(arg);
  }

  validateTryCloudflareOptions(options);

  return {
    command,
    options,
    positionals,
  };
}

function parsePortNumber(value, flagName) {
  const parsed = Number.parseInt(value, 10);
  if (!Number.isInteger(parsed) || parsed < 0 || parsed > 65_535) {
    throw new Error(`${flagName} expects an integer between 0 and 65535.`);
  }

  return parsed;
}

function assertTryCloudflareCommand(command, flagName) {
  if (command === "up") {
    return;
  }

  throw new Error(`${flagName} is only supported with \`remodex up\`.`);
}

function validateTryCloudflareOptions(options) {
  if (!options.tryCloudflare && options.tryCloudflarePort !== 0) {
    throw new Error("--trycloudflare-port requires --trycloudflare.");
  }
}

module.exports = {
  parseCliArgs,
};

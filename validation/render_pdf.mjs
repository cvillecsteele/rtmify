import fs from "node:fs/promises";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

function parseArgs(argv) {
  const args = { input: null, output: null, data: null };
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (token === "--input") {
      args.input = argv[++i];
    } else if (token === "--output") {
      args.output = argv[++i];
    } else if (token === "--data") {
      args.data = argv[++i];
    } else if (token === "--help" || token === "-h") {
      console.log("node render_pdf.mjs --input <template.html> --output <file.pdf> --data <render-data.json>");
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${token}`);
    }
  }
  if (!args.input || !args.output || !args.data) {
    throw new Error("Missing required arguments: --input, --output, --data");
  }
  return args;
}

function resolvePlaywrightRoot() {
  const validationDir = path.dirname(fileURLToPath(import.meta.url));
  const candidates = [
    path.join(validationDir, "node_modules", "playwright"),
    path.resolve(validationDir, "..", "live", "tests", "node_modules", "playwright"),
  ];
  for (const candidate of candidates) {
    try {
      createRequire(import.meta.url)(path.join(candidate, "package.json"));
      return candidate;
    } catch {}
  }
  throw new Error(
    "Unable to resolve Playwright. Run `npm install` in sys/validation or ensure sys/live/tests/node_modules is present."
  );
}

function renderTemplate(template, data, cssText) {
  let rendered = template.replace("{{PRINT_CSS}}", cssText);
  for (const [key, value] of Object.entries(data)) {
    rendered = rendered.replaceAll(`{{${key}}}`, String(value));
  }
  return rendered;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const validationDir = path.dirname(fileURLToPath(import.meta.url));
  const template = await fs.readFile(args.input, "utf8");
  const cssText = await fs.readFile(path.join(validationDir, "print.css"), "utf8");
  const renderData = JSON.parse(await fs.readFile(args.data, "utf8"));
  const html = renderTemplate(template, renderData, cssText);
  const outputDir = path.dirname(args.output);
  await fs.mkdir(outputDir, { recursive: true });

  const playwrightRoot = resolvePlaywrightRoot();
  const requireFromPlaywright = createRequire(path.join(playwrightRoot, "index.js"));
  const { chromium } = requireFromPlaywright(path.join(playwrightRoot, "index.js"));

  let browser;
  try {
    browser = await chromium.launch({ headless: true });
    const page = await browser.newPage();
    await page.setContent(html, { waitUntil: "load" });
    await page.pdf({
      path: args.output,
      format: "Letter",
      printBackground: true,
      margin: { top: "0.5in", right: "0.5in", bottom: "0.5in", left: "0.5in" },
    });
  } catch (err) {
    throw new Error(`Failed to render PDF: ${err.message}`);
  } finally {
    if (browser) {
      await browser.close();
    }
  }
}

main().catch((err) => {
  console.error(err.message);
  process.exit(1);
});
